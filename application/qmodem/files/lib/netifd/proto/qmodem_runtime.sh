#!/bin/sh
[ -n "$INCLUDE_ONLY" ] || { . /lib/functions.sh; . ../netifd-proto.sh; init_proto "$@"; }
proto_qmodem_runtime_init_config() { proto_config_add_string modem_config; available=1; no_device=0; no_proto_task=1; }
proto_qmodem_runtime_setup() {
    local interface="$1" instance
    instance=$(uci -q get "network.$interface.modem_config")
    . /usr/share/qmodem/instance.sh
    qmodem_valid_instance "$instance" || return 1
    local base="/var/run/qmodem/${instance}_dir"
    mkdir -p "$base"
    ( exec 9>"$base/event.lock"; flock -x 9
      printf '%s\n' "$interface" > "$base/netifd-enabled" )
    /usr/libexec/qmodem-ipv4-event replay "$instance" "$interface"
    # The existing procd dial worker is the only PDP owner. Events complete setup.
}
proto_qmodem_runtime_teardown() {
    local interface="$1" instance base
    instance=$(uci -q get "network.$interface.modem_config")
    . /usr/share/qmodem/instance.sh
    if qmodem_valid_instance "$instance"; then
        base="/var/run/qmodem/${instance}_dir"
        mkdir -p "$base"
        ( exec 9>"$base/event.lock"; flock -x 9
          [ "$(cat "$base/netifd-enabled" 2>/dev/null)" != "$interface" ] || rm -f "$base/netifd-enabled" )
    fi
    proto_init_update "*" 0
    proto_send_update "$interface"
}
[ -n "$INCLUDE_ONLY" ] || add_protocol qmodem_runtime
