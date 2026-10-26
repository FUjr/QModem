#!/bin/sh
# Stage endpoint-specific netifd settings. The bridge owner commits/reloads
# network, so policy and its undo record participate in the same transaction.

qmodem_bridge_port_uci()
{
    "${QMODEM_BRIDGE_PORT_UCI:-uci}" "$@"
}

qmodem_bridge_port_sections()
{
    local network="${QMODEM_BRIDGE_PORT_NETWORK:-network}" type="$1"
    qmodem_bridge_port_uci -q show "$network" | while IFS='=' read -r key value; do
        [ "$value" = "$type" ] || continue
        printf '%s\n' "${key#"$network."}"
    done
}

qmodem_bridge_port_restore()
{
    local instance="$1" network="${QMODEM_BRIDGE_PORT_NETWORK:-network}"
    local state="qmodem_port_${instance}" section='' port option expected previous extra candidate count=0
    QMODEM_BRIDGE_PORT_CHANGED=0
    case "$instance" in ''|*[!A-Za-z0-9_]*) return 1;; esac
    [ "$(qmodem_bridge_port_uci -q get "$network.$state")" = qmodem-bridge-port-policy ] || return 0
    port="$(qmodem_bridge_port_uci -q get "$network.$state.port")" || return 1
    [ -n "$port" ] || return 1
    # Anonymous @device indexes change when another device is inserted/deleted.
    # The marker follows the actual section through commits and reordering.
    for candidate in $(qmodem_bridge_port_sections device); do
        [ "$(qmodem_bridge_port_uci -q get "$network.$candidate.qmodem_port_owner")" = "$instance" ] || continue
        [ "$(qmodem_bridge_port_uci -q get "$network.$candidate.name")" = "$port" ] || continue
        section="$candidate"
        count=$((count + 1))
    done
    [ "$count" -le 1 ] || return 1
    if [ -n "$section" ]; then
        for option in learning unicast_flood; do
            expected=0
            [ "$option" != unicast_flood ] || expected=1
            # Preserve an intervening user change instead of overwriting it.
            [ "$(qmodem_bridge_port_uci -q get "$network.$section.$option")" = "$expected" ] || continue
            previous="$(qmodem_bridge_port_uci -q get "$network.$state.previous_$option" || :)"
            if [ -n "$previous" ]; then
                qmodem_bridge_port_uci set "$network.$section.$option=$previous" || return 1
            else
                qmodem_bridge_port_uci -q delete "$network.$section.$option" || return 1
            fi
        done
        qmodem_bridge_port_uci -q delete "$network.$section.qmodem_port_owner" || return 1
        if [ "$(qmodem_bridge_port_uci -q get "$network.$state.created")" = 1 ]; then
            extra="$(qmodem_bridge_port_uci -q show "$network.$section" | while IFS='=' read -r key value; do
                case "$key" in "$network.$section"|"$network.$section.name") :;; *) printf '%s\n' "$key";; esac
            done)"
            [ -n "$extra" ] || qmodem_bridge_port_uci -q delete "$network.$section" || return 1
        fi
    fi
    qmodem_bridge_port_uci -q delete "$network.$state" || return 1
    QMODEM_BRIDGE_PORT_CHANGED=1
}

qmodem_bridge_port_apply()
{
    local instance="$1" port="$2" modem_path="$3"
    local network="${QMODEM_BRIDGE_PORT_NETWORK:-network}" sysfs="${QMODEM_BRIDGE_PORT_SYSFS:-/sys/class/net}"
    local state="qmodem_port_${instance}" section='' candidate count=0 created=0 option previous device_path old_port changed=0 state_type
    QMODEM_BRIDGE_PORT_CHANGED=0
    case "$instance" in ''|*[!A-Za-z0-9_]*) return 1;; esac
    case "$port" in ''|*[!A-Za-z0-9_.:-]*|lo|br-*|bqm*) return 1;; esac
    [ "$(cat "$sysfs/$port/type" 2>/dev/null)" = 1 ] || return 1
    [ "$(cat "$sysfs/$port/qmi/raw_ip" 2>/dev/null)" != Y ] || return 1
    modem_path="$(readlink -f "$modem_path")" || return 1
    device_path="$(readlink -f "$sysfs/$port/device")" || return 1
    [ -d "$modem_path" ] && [ "$modem_path" != / ] && [ -d "$device_path" ] || return 1
    case "$device_path" in
        "$modem_path"|"$modem_path"/*) :;;
        *)
            # Some existing dialer setups use a separately wired modem
            # Ethernet port, confirmed by vendor AT queries. Only that
            # explicit endpoint may bypass USB/PCIe ancestry validation.
            [ "$port" = "${4:-}" ] || return 1
            ;;
    esac
    state_type="$(qmodem_bridge_port_uci -q get "$network.$state" || :)"
    case "$state_type" in ''|qmodem-bridge-port-policy) :;; *) return 1;; esac
    # Find the existing device first; duplicate names have ambiguous netifd
    # precedence and must not be silently changed.
    for candidate in $(qmodem_bridge_port_sections device); do
        [ "$(qmodem_bridge_port_uci -q get "$network.$candidate.name")" = "$port" ] || continue
        section="$candidate"
        count=$((count + 1))
    done
    [ "$count" -le 1 ] || return 1
    for candidate in $(qmodem_bridge_port_sections qmodem-bridge-port-policy); do
        [ "$candidate" = "$state" ] && continue
        [ "$(qmodem_bridge_port_uci -q get "$network.$candidate.port")" != "$port" ] || return 1
    done
    old_port="$(qmodem_bridge_port_uci -q get "$network.$state.port" || :)"
    if [ -n "$old_port" ] && [ "$old_port" != "$port" ]; then
        qmodem_bridge_port_restore "$instance" || return 1
        changed="$QMODEM_BRIDGE_PORT_CHANGED"
        # Restoring the old endpoint may delete a device and renumber anonymous
        # sections. Resolve the new endpoint again before changing its options.
        section=''
        for candidate in $(qmodem_bridge_port_sections device); do
            [ "$(qmodem_bridge_port_uci -q get "$network.$candidate.name")" = "$port" ] || continue
            section="$candidate"
        done
    fi
    if [ "$(qmodem_bridge_port_uci -q get "$network.$state")" != qmodem-bridge-port-policy ]; then
        if [ -z "$section" ]; then
            section="qmodem_portdev_${instance}"
            [ -z "$(qmodem_bridge_port_uci -q get "$network.$section")" ] || return 1
            qmodem_bridge_port_uci set "$network.$section=device" || return 1
            qmodem_bridge_port_uci set "$network.$section.name=$port" || return 1
            created=1
        else
            [ -z "$(qmodem_bridge_port_uci -q get "$network.$section.qmodem_port_owner")" ] || return 1
        fi
        qmodem_bridge_port_uci set "$network.$state=qmodem-bridge-port-policy" || return 1
        qmodem_bridge_port_uci set "$network.$state.port=$port" || return 1
        qmodem_bridge_port_uci set "$network.$state.created=$created" || return 1
        qmodem_bridge_port_uci set "$network.$section.qmodem_port_owner=$instance" || return 1
        for option in learning unicast_flood; do
            previous="$(qmodem_bridge_port_uci -q get "$network.$section.$option" || :)"
            [ -z "$previous" ] || qmodem_bridge_port_uci set "$network.$state.previous_$option=$previous" || return 1
        done
        changed=1
    else
        [ "$(qmodem_bridge_port_uci -q get "$network.$section.qmodem_port_owner")" = "$instance" ] || return 1
    fi
    for option in learning unicast_flood; do
        previous=0
        [ "$option" != unicast_flood ] || previous=1
        [ "$(qmodem_bridge_port_uci -q get "$network.$section.$option")" != "$previous" ] || continue
        qmodem_bridge_port_uci set "$network.$section.$option=$previous" || return 1
        changed=1
    done
    QMODEM_BRIDGE_PORT_CHANGED="$changed"
}

qmodem_bridge_port_ready()
{
    local sysfs="${QMODEM_BRIDGE_PORT_SYSFS:-/sys/class/net}"
    [ "$(cat "$sysfs/$1/brport/learning" 2>/dev/null)" = 0 ] &&
        [ "$(cat "$sysfs/$1/brport/unicast_flood" 2>/dev/null)" = 1 ]
}

qmodem_bridge_port_activate()
{
    local sysfs="${QMODEM_BRIDGE_PORT_SYSFS:-/sys/class/net}"
    qmodem_bridge_port_ready "$1" || return 1
    # Disabling learning does not remove earlier wrong entries. Kernel port
    # flush removes this port's dynamic FDB entries, retaining static/local
    # entries and every other bridge member's learned addresses.
    printf '1\n' > "$sysfs/$1/brport/flush"
}
