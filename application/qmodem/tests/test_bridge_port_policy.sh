#!/bin/sh
# Run with a native UCI CLI (TEST_UCI=/path/to/uci on non-OpenWrt hosts).
set -eu
package_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_UCI="${TEST_UCI:-uci}"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
mkdir -p "$fixture/config" "$fixture/delta" "$fixture/sys/usb0" "$fixture/sys/usb1" "$fixture/sys/lan1" "$fixture/modem" "$fixture/other"
: > "$fixture/config/network"
for port in usb0 usb1 lan1; do printf '1\n' > "$fixture/sys/$port/type"; done
ln -s "$fixture/modem" "$fixture/sys/usb0/device"
ln -s "$fixture/modem" "$fixture/sys/usb1/device"
ln -s "$fixture/other" "$fixture/sys/lan1/device"
uci() { command "$TEST_UCI" -c "$fixture/config" -t "$fixture/delta" "$@"; }
QMODEM_BRIDGE_PORT_SYSFS="$fixture/sys"
. "$package_dir/files/usr/share/qmodem/bridge_port_policy.sh"

# Never flush before both runtime flags have taken effect.
mkdir -p "$fixture/sys/usb0/brport"
printf '1\n' > "$fixture/sys/usb0/brport/learning"
printf '1\n' > "$fixture/sys/usb0/brport/unicast_flood"
: > "$fixture/sys/usb0/brport/flush"
! qmodem_bridge_port_activate usb0
[ ! -s "$fixture/sys/usb0/brport/flush" ]
printf '0\n' > "$fixture/sys/usb0/brport/learning"
printf '0\n' > "$fixture/sys/usb0/brport/unicast_flood"
! qmodem_bridge_port_activate usb0
[ ! -s "$fixture/sys/usb0/brport/flush" ]
printf '1\n' > "$fixture/sys/usb0/brport/unicast_flood"
qmodem_bridge_port_activate usb0
[ "$(cat "$fixture/sys/usb0/brport/flush")" = 1 ]

qmodem_bridge_port_apply modem0 usb0 "$fixture/modem"
[ "$QMODEM_BRIDGE_PORT_CHANGED" = 1 ]
[ "$(uci get network.qmodem_portdev_modem0.learning)" = 0 ]
[ "$(uci get network.qmodem_portdev_modem0.unicast_flood)" = 1 ]
qmodem_bridge_port_apply modem0 usb0 "$fixture/modem"
[ "$QMODEM_BRIDGE_PORT_CHANGED" = 0 ]
! qmodem_bridge_port_apply modem1 usb0 "$fixture/modem"
! qmodem_bridge_port_apply modem0 lan1 "$fixture/modem"
# Re-enumeration under another name removes only the old owned settings.
qmodem_bridge_port_apply modem0 usb1 "$fixture/modem"
[ "$(uci get network.qmodem_portdev_modem0.name)" = usb1 ]
qmodem_bridge_port_restore modem0
! uci -q get network.qmodem_portdev_modem0
! uci -q get network.qmodem_port_modem0
qmodem_bridge_port_restore modem0
[ "$QMODEM_BRIDGE_PORT_CHANGED" = 0 ]
# Preserve the existing, explicitly confirmed external modem Ethernet path.
qmodem_bridge_port_apply modem0 lan1 "$fixture/modem" lan1
[ "$(uci get network.qmodem_portdev_modem0.name)" = lan1 ]
qmodem_bridge_port_restore modem0

# Removing the owned old device renumbers a pre-existing anonymous endpoint.
qmodem_bridge_port_apply modem0 usb0 "$fixture/modem"
section="$(uci add network device)"
uci set "network.$section.name=usb1"
uci set "network.$section.mtu=1420"
uci commit network
qmodem_bridge_port_apply modem0 usb1 "$fixture/modem"
[ "$(uci get network.@device[0].name)" = usb1 ]
[ "$(uci get network.@device[0].learning)" = 0 ]
[ "$(uci get network.@device[0].mtu)" = 1420 ]
qmodem_bridge_port_restore modem0
uci delete network.@device[0]

# Merge an anonymous user device and restore its exact explicit settings.
section="$(uci add network device)"
uci set "network.$section.name=usb0"
uci set "network.$section.learning=1"
uci set "network.$section.unicast_flood=0"
uci set "network.$section.mtu=1400"
uci commit network
section='@device[0]'
cp "$fixture/config/network" "$fixture/original"
qmodem_bridge_port_apply modem0 usb0 "$fixture/modem"
[ "$(uci get "network.$section.learning")" = 0 ]
[ "$(uci get "network.$section.unicast_flood")" = 1 ]
[ "$(uci get "network.$section.mtu")" = 1400 ]
qmodem_bridge_port_restore modem0
uci commit network
cmp "$fixture/original" "$fixture/config/network"

# The undo record must follow an anonymous section when its index changes.
qmodem_bridge_port_apply modem0 usb0 "$fixture/modem"
uci set network.unrelated=device
uci set network.unrelated.name=lan1
uci reorder network.unrelated=0
qmodem_bridge_port_restore modem0
[ "$(uci get network.@device[1].learning)" = 1 ]
[ "$(uci get network.@device[1].unicast_flood)" = 0 ]
uci delete network.unrelated

# Unspecified values stay unspecified; user changes made while active survive.
uci delete "network.$section.learning"
uci delete "network.$section.unicast_flood"
qmodem_bridge_port_apply modem0 usb0 "$fixture/modem"
uci set "network.$section.unicast_flood=0"
qmodem_bridge_port_restore modem0
! uci -q get "network.$section.learning"
[ "$(uci get "network.$section.unicast_flood")" = 0 ]

# Duplicate device names and raw-IP must fail before staging any changes.
uci set network.duplicate=device
uci set network.duplicate.name=usb0
uci changes network > "$fixture/before"
! qmodem_bridge_port_apply modem0 usb0 "$fixture/modem"
uci changes network > "$fixture/after"
cmp "$fixture/before" "$fixture/after"
uci delete network.duplicate
printf '65534\n' > "$fixture/sys/usb0/type"
! qmodem_bridge_port_apply modem0 usb0 "$fixture/modem"
printf '1\n' > "$fixture/sys/usb0/type"
mkdir "$fixture/sys/usb0/qmi"
printf 'Y\n' > "$fixture/sys/usb0/qmi/raw_ip"
! qmodem_bridge_port_apply modem0 usb0 "$fixture/modem"
rm "$fixture/sys/usb0/qmi/raw_ip"
uci set network.qmodem_port_modem0=interface
uci changes network > "$fixture/before"
! qmodem_bridge_port_apply modem0 usb0 "$fixture/modem"
uci changes network > "$fixture/after"
cmp "$fixture/before" "$fixture/after"
uci delete network.qmodem_port_modem0

# Exercise the independent dialer's actual bridge creator with real UCI.
dial_script="$package_dir/files/usr/share/qmodem/modem_dial.sh"
eval "$(awk '/^ensure_bridge_device\(\)$/ { capture=1 } capture { print } capture && /^}$/ { exit }' "$dial_script")"
get_bridge_device_section() { echo qmodem_bridge_modem0; }
resolve_bridge_device_name() { echo btest; }
append() { eval "$1=\"\${$1}\${$1:+ }\$2\""; }
m_debug() { :; }
modem_config=modem0
modem_path="$fixture/modem"
bridge_ports_selected=lan1
bridge_network_dirty=0
ensure_bridge_device usb0 || { echo 'independent bridge setup failed' >&2; exit 1; }
[ "$bridge_network_dirty" = 1 ]
[ "$(uci get network.qmodem_bridge_modem0.ports)" = 'lan1 usb0' ]
[ "$(uci get network.@device[0].learning)" = 0 ]
qmodem_bridge_port_restore modem0
echo 'bridge port policy tests passed (ownership, rename, merge, restore, duplicate, raw-IP)'
