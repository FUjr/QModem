#!/bin/sh
# Reserved IPv4 policy namespace. Rules/routes are tagged with protocol 201.
UP_PROTO=201
UP_BUSINESS=31099
UP_FIRST=31100
UP_LAST=31264
UP_MASK=0x00ff0000
UP_FLOW_FIRST=31200
up_name() { case "$1" in ''|*[!A-Za-z0-9_]*) return 1;; esac; }
up_ipv4() { printf '%s\n' "$1" | awk -F. 'NF!=4 {exit 1} {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || $i>255) exit 1}'; }
up_check_namespace() {
    local value mask
    # Rules from another manager using our mark bits would make CT pinning unsafe.
    for value in $(ip -4 rule show | sed -n '/proto 201/!s/.*fwmark \([^ ]*\).*/\1/p'); do
        mask=${value#*/}; [ "$mask" != "$value" ] || mask=0xffffffff
        case "$mask" in *[!0-9a-fA-Fx]*) return 1;; esac
        [ "$((mask & UP_MASK))" = 0 ] || return 1
    done
    ip -j -N -4 rule show | jq -e 'all(.[]; if (((.priority>=1 and .priority<=64) or (.priority>=31000 and .priority<=31064) or .priority==31100 or .priority==31101)) then ((.protocol|tostring)=="201") else true end)' >/dev/null || return 1
    ip -j -N -4 route show table all | jq -e 'all(.[]; if ((.table|type)=="number" and .table>=31099 and .table<=31264) then ((.protocol|tostring)=="201") else true end)' >/dev/null

}
up_cleanup_routes() {
    local p t
    # Never flush an entire table or delete an untagged rule.
    for p in $(ip -j -N -4 rule show | jq -r '.[] | select(((.priority>=1 and .priority<=64) or (.priority>=31000 and .priority<=31064) or .priority==31100 or .priority==31101) and (.protocol|tostring)=="201") | .priority'); do
        ip -4 rule del pref "$p" protocol "$UP_PROTO" || return 1
    done
    t=$UP_BUSINESS
    while [ "$t" -le "$UP_LAST" ]; do ip -4 route flush table "$t" proto "$UP_PROTO" 2>/dev/null || :; t=$((t+1)); done
    return 0
}
up_policy_init() {
    up_check_namespace || return 1
    ip -4 route replace unreachable default table "$UP_BUSINESS" metric 32767 proto "$UP_PROTO" || return 1
    ip -4 route replace unreachable default table 31264 metric 32767 proto "$UP_PROTO" || return 1
    ip -4 rule show pref 31064 | grep -q . || ip -4 rule add pref 31064 fwmark 0x00ff0000/0x00ff0000 lookup 31264 protocol "$UP_PROTO" || return 1
    ip -4 rule show pref 31100 | grep -q . || ip -4 rule add pref 31100 lookup main suppress_prefixlength 0 protocol "$UP_PROTO" || return 1
    ip -4 rule show pref 31101 | grep -q . || ip -4 rule add pref 31101 lookup "$UP_BUSINESS" protocol "$UP_PROTO"
}
up_route_default() {
    local table=$1 device=$2 address=$3 gateway=$4
    if [ -n "$gateway" ] && [ "$gateway" != 0.0.0.0 ]; then
        ip -4 route replace default via "$gateway" dev "$device" onlink src "$address" table "$table" metric 1 proto "$UP_PROTO"
    else
        ip -4 route replace default dev "$device" src "$address" table "$table" metric 1 proto "$UP_PROTO"
    fi
}
up_probe_route() {
    local idx=$1 device=$2 address=$3 gateway=$4 table pref
    table=$((UP_FIRST+idx)); pref=$((1+idx))
    ip -4 rule del pref "$pref" protocol "$UP_PROTO" 2>/dev/null || :
    ip -4 route flush table "$table" proto "$UP_PROTO" 2>/dev/null || :
    ip -4 route replace unreachable default table "$table" metric 32767 proto "$UP_PROTO" || return 1
    up_route_default "$table" "$device" "$address" "$gateway" || return 1
    ip -4 rule add pref "$pref" oif "$device" lookup "$table" protocol "$UP_PROTO"
}
up_probe() {
    local target
    for target in $UP_TARGETS; do
        ping -4 -n -c 1 -W "$UP_TIMEOUT" -w "$UP_TIMEOUT" -I "$1" "$target" >/dev/null 2>&1 && return 0
    done
    return 1
}
# Inputs/outputs are JSON; hysteresis counts rounds, stability uses monotonic time.
up_health() {
    jq -cn --argjson old "$1" --argjson ok "$2" --argjson available "$3" --argjson now "$4" \
        --argjson fail "$UP_FAIL" --argjson recover "$UP_RECOVER" --argjson stable "$UP_STABLE" '
        ($old // {healthy:false,seen:false,good:0,bad:0,since:0}) as $s |
        if $available|not then $s + {healthy:false,good:0,bad:0,since:0}
        elif $ok then
            ($s.good + 1) as $g | (if $s.good==0 then $now else $s.since end) as $since |
            $s + {good:$g,bad:0,since:$since,seen:true,
                healthy:($s.healthy or ($s.seen|not) or ($g >= $recover and ($now-$since) >= $stable))}
        else $s + {good:0,bad:($s.bad+1),since:0,healthy:($s.healthy and ($s.bad+1)<$fail)} end'
}
