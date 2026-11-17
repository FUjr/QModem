#!/bin/sh
# IPv4 only. 8 reserved mark bits encode 64 persistent member IDs and 255=deny.
# This table never grants firewall access or owns NAT: firewall4 remains authoritative.
up_nft_owned() {
    local table
    table=$(nft -j list table ip qmodem_uplink 2>/dev/null) || return 0
    printf '%s' "$table" | jq -e 'any(.nftables[]; .table.comment? == "qmodem-uplink:v1")' >/dev/null
}
up_nft_cleanup() {
    up_nft_owned || return 1
    nft delete table ip qmodem_uplink 2>/dev/null || :
}
up_ids() {
    # Persist IDs across sorting, reloads and reboots. Retired IDs are reused only
    # when no matching IPv4 conntrack survives (never flush the global CT table).
    local key n used records previous live
    mkdir -p "$UP_STATE"
    previous=$(cat "$UP_STATE/ids.json" 2>/dev/null || echo '{}')
    printf '%s' "$previous" | jq -e 'type=="object" and all(.[]; type=="number" and .>=1 and .<=64 and floor==.) and (([.[]]|unique|length)==length)' >/dev/null || return 1
    # Fail closed if conntrack cannot be inspected; a failed query is not an empty table.
    live=$(conntrack -L -f ipv4 -o extended 2>/dev/null) || return 1
    previous=$(printf '%s' "$previous" | jq -c --argjson members "$members" 'with_entries(select(.key as $id | any($members[]; .id==$id)))')
    records='{}'
    for key in $(printf '%s' "$members" | jq -r '.[].id'); do
        n=$(printf '%s' "$previous" | jq -r --arg key "$key" '.[$key] // 0')
        if [ "$n" -eq 0 ]; then
            n=1
            while [ "$n" -le 64 ]; do
                used=$(printf '%s' "$previous" | jq --argjson n "$n" 'any(.[]; .==$n)')
                if [ "$used" = false ] && [ "$(printf '%s' "$records" | jq --argjson n "$n" 'any(.[]; .==$n)')" = false ]; then
                    # A daemon restart can leave NAT state from a deleted member.
                    if ! conntrack -L -f ipv4 --mark "$((n<<16))/0x00ff0000" -o extended 2>/dev/null | grep -q .; then break; fi
                fi
                n=$((n+1))
            done
            [ "$n" -le 64 ] || return 1
        fi
        records=$(printf '%s' "$records" | jq --arg key "$key" --argjson n "$n" '. + {($key):$n}')
    done
    printf '%s\n' "$records" > "$UP_STATE/ids.json.tmp"
    mv "$UP_STATE/ids.json.tmp" "$UP_STATE/ids.json"
    members=$(printf '%s' "$members" | jq -c --argjson ids "$records" 'map(. + {mark_id:$ids[.id]})')
}
up_rule() {
    local s=$1 enabled src dest proto sport dport target mark
    config_get enabled "$s" enabled 1
    [ "$enabled" = 1 ] || return 0
    config_get src "$s" src
    config_get dest "$s" dest
    config_get proto "$s" proto all
    config_get sport "$s" src_port
    config_get dport "$s" dest_port
    config_get target "$s" target
    mark=$(printf '%s' "$members" | jq -r --arg id "$target" '.[] | select(.id==$id) | .mark_id')
    [ -n "$mark" ] || return 1
    expr='ct mark & 0x00ff0000 == 0'
    if [ -n "$src" ]; then up_cidr "$src" || return 1; expr="$expr ip saddr $src"; fi
    if [ -n "$dest" ]; then up_cidr "$dest" || return 1; expr="$expr ip daddr $dest"; fi
    case "$proto" in all) [ -z "$sport$dport" ] || return 1;; tcp|udp) expr="$expr meta l4proto $proto";; icmp) [ -z "$sport$dport" ] || return 1; expr="$expr ip protocol icmp";; *) return 1;; esac
    for port in "$sport" "$dport"; do [ -z "$port" ] || { up_uint "$port" 1 65535 || return 1; }; done
    [ -z "$sport" ] || expr="$expr $proto sport $sport"
    [ -z "$dport" ] || expr="$expr $proto dport $dport"
    printf '%s ct mark set (ct mark & 0xff00ffff) | %s\n' "$expr" "$((mark<<16))" >> "$RUN/rules.tmp"
}
up_uint() { case "$1" in ''|*[!0-9]*|0[0-9]*) return 1;; esac; [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }
up_cidr() {
    local addr=${1%/*} mask=${1#*/}
    up_ipv4 "$addr" || return 1
    [ "$addr" = "$mask" ] || up_uint "$mask" 0 32
}
up_config() {
    local signature
    signature=$(uci -q export qmodem_uplink | sha256sum | cut -d' ' -f1)
    [ "$signature" != "${config_generation:-}" ] || return 0
    UP_INTERVAL=$(up_num interval 10 1 300) || return 1
    UP_TIMEOUT=$(up_num timeout 2 1 10) || return 1
    UP_FAIL=$(up_num fail_threshold 3 1 30) || return 1
    UP_RECOVER=$(up_num recover_threshold 3 1 30) || return 1
    UP_STABLE=$(up_num stable_seconds 60 0 3600) || return 1
    UP_TARGETS=$(uci -q get qmodem_uplink.main.targets)
    [ -n "$UP_TARGETS" ] || return 1
    set -- $UP_TARGETS
    [ "$#" -le 4 ] || return 1
    for target in $UP_TARGETS; do up_ipv4 "$target" || return 1; done
    UP_MODE=$(uci -q get qmodem_uplink.main.mode || echo failover)
    case "$UP_MODE" in balance|failover) :;; *) return 1;; esac
    members='[]'; config_error=0
    config_load qmodem_uplink
    config_foreach up_member member
    [ "$config_error" = 0 ] || return 1
    members=$(printf '%s' "$members" | jq -c 'sort_by(.priority,.id)')
    [ "$(printf '%s' "$members" | jq 'length<=64 and (length==(unique_by(.id)|length))')" = true ] || return 1
    up_ids || return 1
    : > "$RUN/rules.tmp"
    config_foreach up_rule_checked rule
    [ "$config_error" = 0 ] || return 1
    mv "$RUN/rules.tmp" "$RUN/rules"
    printf '%s' "$members" | jq -c '.[]' > "$RUN/members"
    config_generation=$signature
}
up_rule_checked() { up_rule "$1" || config_error=1; }
up_nft_publish() {
    local row id dev address gateway table pref weight start end total map selected all_devices lan_devices bypass
    up_nft_owned || return 1
    all_devices=$(printf '%s' "$result" | jq -c '[.[].device | select(length>0)] | unique')
    lan_devices=$(ip -j -4 route show table main | jq -c --argjson wan "$all_devices" '[.[] | select(.dst!="default" and .dev!=null and .dev!="lo") | .dev | select(. as $d | $wan|index($d)|not)] | unique')
    bypass=$(ip -j -4 route show table main | jq -r --argjson wan "$all_devices" '[.[] | select(.dst!="default" and .dev!=null and .dev!="lo") | select(.dev as $d | $wan|index($d)|not) | .dst] | unique | join(", ")')
    selected=$(printf '%s' "$result" | jq -c --arg mode "$UP_MODE" '[.[] | select(.health.healthy and .enabled)] | if length==0 then [] elif $mode=="failover" then .[:1] else .[0].priority as $p | map(select(.priority==$p)) end')
    total=0; map=''
    for row in $(printf '%s' "$selected" | jq -c '.[]'); do
        id=$(printf '%s' "$row" | jq -r .mark_id); weight=$(printf '%s' "$row" | jq -r .weight)
        start=$total; total=$((total+weight)); end=$((total-1))
        [ -z "$map" ] || map="$map, "
        if [ "$start" = "$end" ]; then map="$map$start : jump mark_$id"; else map="$map$start-$end : jump mark_$id"; fi
    done
    {
        echo 'add table ip qmodem_uplink { comment "qmodem-uplink:v1"; }'
        echo 'flush table ip qmodem_uplink'
        echo 'add chain ip qmodem_uplink classify'
        echo 'add chain ip qmodem_uplink restore'
        restore_map=''; n=1
        while [ "$n" -le 65 ]; do
            id=$n; [ "$n" != 65 ] || id=255
            echo "add chain ip qmodem_uplink mark_$id"
            echo "add rule ip qmodem_uplink mark_$id ct mark set (ct mark & 0xff00ffff) | $((id<<16)) meta mark set (meta mark & 0xff00ffff) | $((id<<16)) return"
            [ -z "$restore_map" ] || restore_map="$restore_map, "
            restore_map="$restore_map$((id<<16)) : goto mark_$id"
            n=$((n+1))
        done
        echo "add rule ip qmodem_uplink restore ct mark & 0x00ff0000 vmap { $restore_map }"
        echo 'add chain ip qmodem_uplink pre { type filter hook prerouting priority -90; policy accept; }'
        echo 'add chain ip qmodem_uplink out { type route hook output priority -90; policy accept; }'
        for row in $(printf '%s' "$result" | jq -c '.[] | select(.device!="")'); do
            id=$(printf '%s' "$row" | jq -r .mark_id); dev=$(printf '%s' "$row" | jq -r .device)
            echo "add rule ip qmodem_uplink pre iifname \"$dev\" ct direction original ct mark & 0x00ff0000 == 0 ct mark set (ct mark & 0xff00ffff) | $((id<<16))"
        done
        echo 'add rule ip qmodem_uplink pre fib daddr type local return'
        echo 'add rule ip qmodem_uplink out fib daddr type local return'
        if [ -n "$bypass" ]; then
            echo "add rule ip qmodem_uplink pre ip daddr { $bypass } meta mark set meta mark & 0xff00ffff return"
            echo "add rule ip qmodem_uplink out ip daddr { $bypass } meta mark set meta mark & 0xff00ffff return"
        fi
        echo 'add rule ip qmodem_uplink pre ct mark & 0x00ff0000 != 0 jump restore'
        echo 'add rule ip qmodem_uplink pre ct mark & 0x00ff0000 != 0 return'
        echo 'add rule ip qmodem_uplink out ct mark & 0x00ff0000 != 0 jump restore'
        echo 'add rule ip qmodem_uplink out ct mark & 0x00ff0000 != 0 return'
        for dev in $(printf '%s' "$lan_devices" | jq -r '.[]'); do
            echo "add rule ip qmodem_uplink pre iifname \"$dev\" jump classify"
        done
        while IFS= read -r row; do echo "add rule ip qmodem_uplink classify $row"; done < "$RUN/rules"
        if [ "$total" -gt 0 ]; then echo "add rule ip qmodem_uplink classify ct mark & 0x00ff0000 == 0 numgen random mod $total vmap { $map }"
        else echo 'add rule ip qmodem_uplink classify ct mark & 0x00ff0000 == 0 ct mark set (ct mark & 0xff00ffff) | 0x00ff0000'; fi
        echo 'add rule ip qmodem_uplink classify jump restore'
    } > "$RUN/policy.nft.tmp"
    nft -c -f "$RUN/policy.nft.tmp" || return 1
    # Prepare all member routes before exposing new selection. Down/disabled
    # members retain a terminal default so strict rules never fall back elsewhere.
    for row in $(printf '%s' "$result" | jq -c '.[]'); do
        id=$(printf '%s' "$row" | jq -r .mark_id); table=$((31200+id-1)); pref=$((31000+id-1))
        ip -4 route replace unreachable default table "$table" metric 32767 proto "$UP_PROTO" || return 1
        dev=$(printf '%s' "$row" | jq -r .device)
        if [ "$(printf '%s' "$row" | jq '.health.healthy')" = true ]; then
            address=$(printf '%s' "$row" | jq -r .address); gateway=$(printf '%s' "$row" | jq -r .gateway)
            up_route_default "$table" "$dev" "$address" "$gateway" || return 1
        else ip -4 route del default table "$table" metric 1 proto "$UP_PROTO" 2>/dev/null || :; fi
        if ! ip -4 rule show pref "$pref" | grep -q .; then
            ip -4 rule add pref "$pref" fwmark "$((id<<16))/$UP_MASK" lookup "$table" protocol "$UP_PROTO" || return 1
        fi
    done
    # A changed PDP/address invalidates only that member's NAT state.
    sessions=$(cat "$UP_STATE/sessions.json" 2>/dev/null || echo '{}')
    for row in $(printf '%s' "$result" | jq -c '.[] | select(.health.healthy)'); do
        id=$(printf '%s' "$row" | jq -r .mark_id)
        identity=$(printf '%s' "$row" | jq -c '[.device,.address,(.generation // ""),(.ifindex // "")]')
        previous=$(printf '%s' "$sessions" | jq -r --arg id "$id" '.[$id] // empty')
        if [ -n "$previous" ] && [ "$previous" != "$identity" ]; then
            conntrack -D -f ipv4 --mark "$((id<<16))/$UP_MASK" >/dev/null 2>&1 || :
        fi
        sessions=$(printf '%s' "$sessions" | jq --arg id "$id" --arg identity "$identity" '. + {($id):$identity}')
    done
    nft -f "$RUN/policy.nft.tmp" || return 1
    mkdir -p "$UP_STATE"
    printf '%s\n' "$sessions" > "$UP_STATE/sessions.json.tmp"
    mv "$UP_STATE/sessions.json.tmp" "$UP_STATE/sessions.json"
    mv "$RUN/policy.nft.tmp" "$RUN/policy.nft"
    active_members=$(printf '%s' "$selected" | jq -c '[.[].id]')
    result=$(printf '%s' "$result" | jq -c --argjson active "$active_members" 'map(. + {selected:(.id as $id | $active|index($id)!=null),effective_weight:(if (.id as $id | $active|index($id)!=null) then .weight else 0 end)})')
    applied_generation=$config_generation
}
