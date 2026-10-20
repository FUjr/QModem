#!/bin/sh
set -eu
package_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
mkdir -p "$fixture/device/interface/net/wwan0"
ln -s "$fixture/device" "$fixture/usb-slot"
cat > "$fixture/uci" <<'EOF'
#!/bin/sh
[ "$*" = '-q get qmodem.modem0.path' ] || exit 1
printf '%s\n' "$MODEM_TEST_PATH"
EOF
chmod +x "$fixture/uci"
export QMODEM_UCI="$fixture/uci" MODEM_TEST_PATH="$fixture/usb-slot"
resolver="$package_dir/files/usr/share/qmodem/modem_netdev.sh"
[ "$("$resolver" modem0)" = wwan0 ]
# A nested QMI child is the data endpoint, not a second independent NIC.
mkdir -p "$fixture/device/interface/net/wwan0/net/wwan0_1"
[ "$("$resolver" modem0)" = wwan0_1 ]
# Execute the real dial configuration function with only UCI/vendor calls mocked.
eval "$(awk '$0 == "update_config()" { capture=1 } capture { print } capture && $0 == "}" { exit }' "$package_dir/files/usr/share/qmodem/modem_dial.sh")"
config_load() { :; }
config_foreach() { :; }
config_get() {
    value="${4-}"
    [ "$1" != modem_path ] || value="$(readlink -f "$MODEM_TEST_PATH")"
    eval "$1=\$value"
}
get_platform_suggest_pdp_index() { printf '1\n'; }
get_driver() { printf 'qmi\n'; }
update_sim_slot() { sim_slot=1; }
SCRIPT_DIR="$package_dir/files/usr/share/qmodem"
modem_config=modem0
update_config
[ "$modem_netcard" = wwan0_1 ]
[ "$interface_name" = modem0 ]
# Multiple mux children and independent sibling endpoints must remain ambiguous.
mkdir "$fixture/device/interface/net/wwan0/net/wwan0_2"
! "$resolver" modem0
rmdir "$fixture/device/interface/net/wwan0/net/wwan0_2"
mkdir -p "$fixture/device/other/net/usb0"
! "$resolver" modem0
rmdir "$fixture/device/other/net/usb0" "$fixture/device/other/net"
mkdir "$fixture/device/interface/net/usb1"
! "$resolver" modem0
rmdir "$fixture/device/interface/net/usb1"
rmdir "$fixture/device/interface/net/wwan0/net/wwan0_1"
! "$resolver" modem0
rmdir "$fixture/device/interface/net/wwan0/net" "$fixture/device/interface/net/wwan0"
! "$resolver" modem0
mkdir "$fixture/device/interface/net/usb1"
[ "$("$resolver" modem0)" = usb1 ]
! "$resolver" 'modem0;false'
echo 'modem endpoint tests passed (plain, nested QMI, dial config, ambiguity, unplug, replug)'
