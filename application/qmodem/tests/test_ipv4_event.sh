#!/bin/sh
set -eu
package=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT INT TERM
mkdir -p "$fixture/bin" "$fixture/config" "$fixture/delta" "$fixture/run/slot_a_dir" "$fixture/device/net/testmodem0"
export TEST_UCI=${TEST_UCI:-uci} TEST_CONFIG="$fixture/config" TEST_DELTA="$fixture/delta"
cat > "$fixture/bin/uci" <<'SCRIPT'
#!/bin/sh
exec "$TEST_UCI" -c "$TEST_CONFIG" -t "$TEST_DELTA" "$@"
SCRIPT
chmod +x "$fixture/bin/uci"
export PATH="$fixture/bin:$PATH"
printf "config modem-device 'slot_a'\n option path '%s'\n" "$fixture/device" > "$fixture/config/qmodem"
cat > "$fixture/config/network" <<'CFG'
config interface 'cell0'
 option modem_config 'slot_a'
 option proto 'qmodem_runtime'
config interface 'other'
 option modem_config 'slot_b'
 option proto 'qmodem_runtime'
CFG
: > "$fixture/functions"
cat > "$fixture/proto" <<'SCRIPT'
proto_init_update() { echo "link:$*" >> "$EVENT_LOG"; }
proto_add_ipv4_address() { echo "address:$*" >> "$EVENT_LOG"; }
proto_add_ipv4_route() { echo "route:$*" >> "$EVENT_LOG"; }
proto_add_dns_server() { echo "dns:$*" >> "$EVENT_LOG"; }
proto_send_update() { echo "notify:$*" >> "$EVENT_LOG"; }
SCRIPT
export QMODEM_LIB_FUNCTIONS="$fixture/functions" QMODEM_NETIFD_PROTO="$fixture/proto" QMODEM_HOME="$package/files/usr/share/qmodem" QMODEM_RUN="$fixture/run"
export EVENT_LOG="$fixture/events" QMODEM_INSTANCE=slot_a QMODEM_INTERFACE=cell0 QMODEM_GENERATION=current
printf '%s\n' current > "$QMODEM_RUN/slot_a_dir/generation"
helper="$package/files/usr/libexec/qmodem-ipv4-event"
printf '%s\n' cell0 > "$QMODEM_RUN/slot_a_dir/netifd-enabled"
"$helper" up testmodem0 10.0.0.2 255.255.255.0 10.0.0.1 223.5.5.5 119.29.29.29 0
grep -q 'notify:cell0' "$EVENT_LOG"
grep -q 'address:10.0.0.2 255.255.255.0' "$EVENT_LOG"
[ "$(jq -r .generation "$QMODEM_RUN/slot_a_dir/ipv4.json")" = current ]
before=$(cat "$EVENT_LOG")
QMODEM_INTERFACE=other "$helper" up testmodem0 10.0.0.2 255.255.255.0 10.0.0.1 0.0.0.0 0.0.0.0 0 && exit 1
QMODEM_GENERATION=stale "$helper" down testmodem0 10.0.0.2 255.255.255.0 10.0.0.1 0.0.0.0 0.0.0.0 0 && exit 1
[ "$(cat "$EVENT_LOG")" = "$before" ]
"$helper" replay slot_a cell0
printf '%s\n' next > "$QMODEM_RUN/slot_a_dir/generation"
! "$helper" replay slot_a cell0
printf '%s\n' current > "$QMODEM_RUN/slot_a_dir/generation"
"$helper" down testmodem0 10.0.0.2 255.255.255.0 10.0.0.1 0.0.0.0 0.0.0.0 0
grep -q 'link:testmodem0 0' "$EVENT_LOG"
before=$(cat "$EVENT_LOG")
rm "$QMODEM_RUN/slot_a_dir/netifd-enabled"
"$helper" up testmodem0 10.0.0.3 255.255.255.0 10.0.0.1 0.0.0.0 0.0.0.0 0
[ "$(cat "$EVENT_LOG")" = "$before" ]
[ "$(jq -r .address "$QMODEM_RUN/slot_a_dir/ipv4.json")" = 10.0.0.3 ]
printf '%s\n' cell0 > "$QMODEM_RUN/slot_a_dir/netifd-enabled"
"$helper" replay slot_a cell0
grep -q 'address:10.0.0.3' "$EVENT_LOG"
. "$QMODEM_HOME/instance.sh"
modem_config=slot_a
qmodem_interface_owned cell0
! qmodem_interface_owned other
! qmodem_valid_instance 'slot_a;echo unsafe'
cat > "$fixture/config/firewall" <<'CFG'
config zone
 option name 'lan'
config zone
 option name 'guest'
config zone
 option name 'wan'
CFG
[ "$(qmodem_wan_zone)" = '@zone[2]' ]
# Configuration helpers must succeed when use_ubus is disabled, and reject
# another instance's override/SMS port before any AT operation.
eval "$(sed -n '/^get_modem_config() {/,/^}/p; /^get_at_port_config() {/,/^}/p' "$package/files/usr/libexec/rpcd/qmodem")"
uci set qmodem.slot_a.use_ubus=0
get_modem_config slot_a || exit 1
get_at_port_config slot_a 0 || exit 1
uci set qmodem.slot_a.at_port=/dev/test0
uci set qmodem.slot_a.override_at_port=/dev/other
! get_modem_config slot_a
uci delete qmodem.slot_a.override_at_port
uci set qmodem.slot_a.sms_at_port=/dev/other
! get_modem_config slot_a
! get_at_port_config slot_a 1
echo 'PASS: normalized netifd events, replay, stale-generation rejection, explicit ownership, firewall zone lookup'
