#!/bin/sh
# Real presence helper + scanner state transitions, with isolated UCI/sysfs.
set -eu
repo=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
export QMODEM_HOME="$repo/application/qmodem/files/usr/share/qmodem"
export QMODEM_SYSFS="$fixture/sys" QMODEM_RUN_DIR="$fixture/run"
export QMODEM_TEST_DB="$fixture/config.json" QMODEM_TEST_CALLS="$fixture/calls"
export QMODEM_TEST_FAIL="$fixture/fail"
export QMODEM_UCI="$fixture/bin/uci"
export PATH="$fixture/bin:$PATH"
mkdir -p "$fixture/bin" "$QMODEM_RUN_DIR" "$QMODEM_SYSFS/dev/char" "$QMODEM_SYSFS/class/net" \
    "$QMODEM_SYSFS/devices/usb/1-1/control" "$QMODEM_SYSFS/devices/usb/1-1/data/net/wwan0" \
    "$QMODEM_SYSFS/devices/usb/1-10/control" "$QMODEM_SYSFS/bus/usb/devices"
ln -s "$QMODEM_SYSFS/devices/usb/1-1" "$QMODEM_SYSFS/bus/usb/devices/1-1"
ln -s "$QMODEM_SYSFS/devices/usb/1-1/control" "$QMODEM_SYSFS/dev/char/1:3"
ln -s "$QMODEM_SYSFS/devices/usb/1-1/data/net/wwan0" "$QMODEM_SYSFS/class/net/wwan0"
cat > "$fixture/bin/uci" <<'PY'
#!/usr/bin/env python3
import json, os, sys
p = os.environ['QMODEM_TEST_DB']
d = json.load(open(p))
a = [x for x in sys.argv[1:] if x != '-q']
if a[0] == 'get':
    if a[1] not in d: sys.exit(1)
    print(d[a[1]])
elif a[0] == 'show':
    for k, v in d.items():
        if k.startswith(a[1] + '.'):
            print(k + '=' + (v if k.count('.') == 1 else "'" + v + "'"))
elif a[0] == 'set':
    k, v = a[1].split('=', 1)
    d[k] = v
    json.dump(d, open(p, 'w'))
elif a[0] == 'commit':
    if os.path.exists(os.environ['QMODEM_TEST_FAIL'] + '.commit'): sys.exit(1)
else:
    sys.exit(2)
PY
cat > "$fixture/bin/network-init" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$QMODEM_TEST_CALLS"
[ "$1" != offline ] || [ ! -e "$QMODEM_TEST_FAIL" ]
SH
chmod +x "$fixture/bin/uci" "$fixture/bin/network-init"
ln -s "$QMODEM_HOME/modem_ready.sh" "$fixture/bin/modem-ready"
python3 - <<'PY'
import json, os
s = os.environ['QMODEM_SYSFS']
json.dump({'qmodem.main.block_auto_probe':'1', 'qmodem.main.enable_dial':'1',
    'qmodem.1_1':'modem-device', 'qmodem.1_1.path':s+'/bus/usb/devices/1-1/',
    'qmodem.1_1.at_port':'/dev/null', 'qmodem.1_1.data_interface':'usb',
    'qmodem.1_1.state':'enabled', 'qmodem.1_1.enable_dial':'1', 'qmodem.1_1.apn':'keep-me'},
    open(os.environ['QMODEM_TEST_DB'], 'w'))
PY
ready="$QMODEM_HOME/modem_ready.sh"
# A saved enabled flag is insufficient before confirmation.
! "$ready" check 1_1
"$ready" confirm 1_1
"$ready" check 1_1
# Prefix siblings are not children: 1-10 must never be mistaken for 1-1.
rm "$QMODEM_SYSFS/dev/char/1:3"
ln -s "$QMODEM_SYSFS/devices/usb/1-10/control" "$QMODEM_SYSFS/dev/char/1:3"
! "$ready" check 1_1
! "$ready" confirm 1_1
rm "$QMODEM_SYSFS/dev/char/1:3"
ln -s "$QMODEM_SYSFS/devices/usb/1-1/control" "$QMODEM_SYSFS/dev/char/1:3"
# A new enumeration at the exact same path invalidates the old proof.
mv "$QMODEM_SYSFS/devices/usb/1-1/control" "$QMODEM_SYSFS/devices/usb/1-1/old-control"
mkdir "$QMODEM_SYSFS/devices/usb/1-1/control"
! "$ready" check 1_1
"$ready" confirm 1_1
# Nested QMI data endpoint remains supported.
mkdir -p "$QMODEM_SYSFS/devices/usb/1-1/data/net/wwan0/net/wwan0_1"
ln -s "$QMODEM_SYSFS/devices/usb/1-1/data/net/wwan0/net/wwan0_1" "$QMODEM_SYSFS/class/net/wwan0_1"
! "$ready" check 1_1
"$ready" confirm 1_1
"$ready" check 1_1
rmdir "$QMODEM_SYSFS/devices/usb/1-1/data/net/wwan0/net/wwan0_1" "$QMODEM_SYSFS/devices/usb/1-1/data/net/wwan0/net"
rm "$QMODEM_SYSFS/class/net/wwan0_1"
# PCIe association is explicit and is not inferred from serial/VID/PID.
mkdir -p "$QMODEM_SYSFS/devices/pci/0000:01:00.0/data/net/wwan1"
ln -s "$QMODEM_SYSFS/devices/pci/0000:01:00.0/data/net/wwan1" "$QMODEM_SYSFS/class/net/wwan1"
uci set qmodem.pcie=modem-device
uci set "qmodem.pcie.path=$QMODEM_SYSFS/devices/pci/0000:01:00.0"
uci set qmodem.pcie.at_port=/dev/null
uci set qmodem.pcie.data_interface=pcie
! "$ready" confirm pcie
uci set qmodem.preset=modem-slot
uci set qmodem.preset.type=pcie
uci set qmodem.preset.slot=0000:01:00.0
uci set qmodem.preset.associated_usb=1-1
"$ready" confirm pcie
"$ready" check pcie
uci set qmodem.preset.associated_usb=2-1
# Exercise the real procd admission function. Manual dial shares this gate.
eval "$(awk '$0 == "_dial()" { capture=1 } capture { print } capture && $0 == "}" { exit }' "$repo/application/qmodem/files/etc/init.d/qmodem_network")"
SCRIPT_DIR="$QMODEM_HOME"
procd_open_instance() { printf '%s\n' "$1" >> "$fixture/procd"; }
procd_set_param() { :; }
procd_close_instance() { :; }
logger() { :; }
rm -f "$QMODEM_RUN_DIR/1_1_dir/ready"
! _dial 1_1
[ ! -e "$fixture/procd" ]
"$ready" confirm 1_1
_dial 1_1
[ "$(cat "$fixture/procd")" = modem_1_1 ]
uci set qmodem.1_1.state=disabled
! _dial 1_1
[ "$(wc -l < "$fixture/procd")" -eq 1 ]
uci set qmodem.1_1.state=enabled
# Execute the actual AT boundary and offline dispatch with transports stubbed.
# Only redirect its lock directory into this fixture.
awk '$0 == "at()" { capture=1 } capture { print } capture && $0 == ")" { exit }' \
    "$QMODEM_HOME/modem_util.sh" | sed "s|/var/lock|$fixture/locks|g" > "$fixture/at-function"
cat > "$fixture/test-at" <<'SH'
#!/bin/bash
set -e
source "$1/at-function"
SCRIPT_DIR="$QMODEM_HOME"
modem_config=1_1
QMODEM_REQUIRE_READY=1
qmodem_testcase_collect_enabled() { return 1; }
# Use a distinct name to avoid transport argument shadowing.
transport_calls="$1/transport"
tom_modem() { echo transport >> "$transport_calls"; }
"$SCRIPT_DIR/modem_ready.sh" confirm 1_1
at /dev/null ATI
[ "$(wc -l < "$transport_calls")" -eq 1 ]
rm "$QMODEM_RUN_DIR/1_1_dir/ready"
! at /dev/null ATI
[ "$(wc -l < "$transport_calls")" -eq 1 ]
"$SCRIPT_DIR/modem_ready.sh" confirm 1_1
! at /dev/zero ATI
[ "$(wc -l < "$transport_calls")" -eq 1 ]
SH
bash "$fixture/test-at" "$fixture"
awk '$0 == "update_config()" { capture=1 } capture { print } capture && $0 == "}" { exit }' \
    "$QMODEM_HOME/modem_dial.sh" > "$fixture/update-config"
awk '$0 == "QMODEM_REQUIRE_READY=1" { capture=1 } capture { print }' \
    "$QMODEM_HOME/modem_dial.sh" > "$fixture/dispatch"
cat > "$fixture/test-offline" <<'SH'
#!/bin/bash
source "$1/update-config"
SCRIPT_DIR="$QMODEM_HOME"
modem_config=1_1
config_load() { :; }
config_foreach() { :; }
config_get() { local value="${4:-}"; printf -v "$1" '%s' "$value"; }
get_platform_suggest_pdp_index() { echo 1; }
get_driver() { echo ncm; }
update_sim_slot() { echo unexpected-at >> "$QMODEM_TEST_CALLS"; }
wwan_hang() { echo stop-child >> "$QMODEM_TEST_CALLS"; return 1; }
flush_if() { echo flush-host >> "$QMODEM_TEST_CALLS"; }
set -- "$1" offline
source "$1/dispatch"
SH
if bash "$fixture/test-offline" "$fixture"; then
    echo 'offline cleanup must report a failed child stop' >&2
    exit 1
fi
! grep -q '^unexpected-at$' "$QMODEM_TEST_CALLS"
grep -q '^stop-child$' "$QMODEM_TEST_CALLS"
grep -q '^flush-host$' "$QMODEM_TEST_CALLS"
# Exercise the actual scanner lifecycle, not a copy of its state machine.
${CC:-cc} ${CFLAGS:-} -D_GNU_SOURCE -std=c99 -pthread \
    "-DQMODEM_RUN_DIR=\"$QMODEM_RUN_DIR\"" \
    "-DQMODEM_CONFIG_LOCK=\"$fixture/config.lock\"" \
    '-DQMODEM_READY_HELPER="modem-ready"' '-DQMODEM_NETWORK_INIT="network-init"' \
    "$repo/application/modem_scan/tests/test_presence.c" ${LDFLAGS:--ljson-c} -o "$fixture/test-presence"
"$fixture/test-presence"
[ "$(uci -q get qmodem.1_1.apn)" = keep-me ]
grep -q '^offline 1_1$' "$QMODEM_TEST_CALLS"
grep -q '^reload$' "$QMODEM_TEST_CALLS"
echo 'PASS: boot gate, tty reuse, same-slot re-enumeration, nested QMI, explicit PCIe association and scanner lifecycle'
