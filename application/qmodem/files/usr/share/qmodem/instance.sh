#!/bin/sh
# Shared instance/config ownership primitives. Never hold config lock over AT IO.
qmodem_valid_instance() {
    case "$1" in ''|*[!A-Za-z0-9_]*) return 1;; esac
    [ "$(uci -q get "qmodem.$1")" = modem-device ]
}
qmodem_config_lock() {
    mkdir -p "${QMODEM_LOCK_DIR:-/var/lock}"
    exec 8>"${QMODEM_LOCK_DIR:-/var/lock}/qmodem-config.lock"
    flock -x 8
}
qmodem_config_unlock() { flock -u 8; exec 8>&-; }
qmodem_interface_owned() {
    local owner
    case "$1" in ''|*[!A-Za-z0-9_]*) return 1;; esac
    owner=$(uci -q get "network.$1.modem_config")
    [ "$owner" = "$modem_config" ] || ! uci -q get "network.$1" >/dev/null
}
qmodem_port_owned() {
    local candidate="$2" ports p
    qmodem_valid_instance "$1" || return 1
    ports="$(uci -q get "qmodem.$1.ports") $(uci -q get "qmodem.$1.valid_at_ports") $(uci -q get "qmodem.$1.at_port")"
    for p in $ports; do [ "$candidate" = "$p" ] && return 0; done
    return 1
}
qmodem_wan_zone() {
    local zones
    zones=$(uci -q show firewall | sed -n "s/^firewall\.\(.*\)\.name='wan'$/\1/p")
    set -- $zones
    [ "$#" = 1 ] || return 1
    printf '%s\n' "$1"
}
