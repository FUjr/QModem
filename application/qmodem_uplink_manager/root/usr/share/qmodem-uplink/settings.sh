#!/bin/sh
up_firewall_restore() {
    local key value changed=0
    [ -s "$UP_STATE/firewall.json" ] || return 0
    exec 8>"${QMODEM_UPLINK_CONFIG_LOCK:-/var/lock/qmodem-config.lock}"
    flock -x 8 || return 1
    for key in $(jq -r 'keys[]' "$UP_STATE/firewall.json"); do
        # Do not overwrite a value edited while the manager was stopped/crashed.
        [ "$(uci -q get "$key")" = 0 ] || continue
        value=$(jq -r --arg key "$key" '.[$key] // "__absent__"' "$UP_STATE/firewall.json")
        if [ "$value" = __absent__ ]; then uci -q delete "$key" || :
        else uci -q set "$key=$value" || return 1; fi
        changed=1
    done
    if [ "$changed" = 1 ]; then uci commit firewall || return 1; fi
    flock -u 8
    if [ "$changed" = 1 ]; then "${QMODEM_UPLINK_FIREWALL_SERVICE:-/etc/init.d/firewall}" reload || return 1; fi
    rm -f "$UP_STATE/firewall.json"
}
up_firewall_acquire() {
    local section option key value records changed=0
    [ "$(uci -q get qmodem_mwan.global.enable_mwan)" != 1 ] || return 1
    if [ -x /etc/init.d/mwan3 ] && /etc/init.d/mwan3 running >/dev/null 2>&1; then return 1; fi
    if nft -j list ruleset 2>/dev/null | jq -e 'any(.nftables[]; ((.table.name? // "") | test("^mwan3")))' >/dev/null; then return 1; fi
    section=$(uci -q -X show firewall | sed -n 's/^firewall\.\([^.=]*\)=defaults$/\1/p')
    up_name "$section" || return 1
    mkdir -p "$UP_STATE"; chmod 700 "$UP_STATE"
    exec 8>"${QMODEM_UPLINK_CONFIG_LOCK:-/var/lock/qmodem-config.lock}"
    flock -x 8 || return 1
    records=$(cat "$UP_STATE/firewall.json" 2>/dev/null || echo '{}')
    for option in flow_offloading flow_offloading_hw fullcone; do
        key="firewall.$section.$option"
        value=$(uci -q get "$key" || echo __absent__)
        if ! printf '%s' "$records" | jq -e --arg key "$key" 'has($key)' >/dev/null || [ "$value" != 0 ]; then
            records=$(printf '%s' "$records" | jq --arg key "$key" --arg value "$value" '. + {($key):(if $value=="__absent__" then null else $value end)}')
        fi
        # Save the lease BEFORE changing persistent options, so a crash is recoverable.
        printf '%s\n' "$records" > "$UP_STATE/firewall.json.tmp"
        mv "$UP_STATE/firewall.json.tmp" "$UP_STATE/firewall.json"
        if [ "$value" != 0 ]; then uci set "$key=0" || return 1; changed=1; fi
    done
    if [ "$changed" = 1 ]; then uci commit firewall || return 1; fi
    flock -u 8
    if [ "$changed" = 1 ]; then "${QMODEM_UPLINK_FIREWALL_SERVICE:-/etc/init.d/firewall}" reload || return 1; fi
}
up_rpf_restore() {
    local device value current
    [ -r "$UP_STATE/rp-filter" ] || return 0
    if [ "$(cat "$UP_STATE/boot-id" 2>/dev/null)" != "$(cat /proc/sys/kernel/random/boot_id)" ]; then rm -f "$UP_STATE/rp-filter"; return 0; fi
    while read -r device value; do
        case "$device" in ''|*[!A-Za-z0-9_.:-]*) continue;; esac
        [ -r "/proc/sys/net/ipv4/conf/$device/rp_filter" ] || continue
        current=$(cat "/proc/sys/net/ipv4/conf/$device/rp_filter")
        [ "$current" != 0 ] || echo "$value" > "/proc/sys/net/ipv4/conf/$device/rp_filter"
    done < "$UP_STATE/rp-filter"
    rm -f "$UP_STATE/rp-filter"
}
