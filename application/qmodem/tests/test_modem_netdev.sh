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
# Generic raw MHI: the auxiliary software channel is never a data candidate.
rmdir "$fixture/device/interface/net/usb1"
mkdir -p "$fixture/device/mhi4/mhi4_IP_HW0/net/mhi_hwip7"
mkdir -p "$fixture/device/mhi4/mhi4_IP_SW0/net/mhi_swip7"
[ "$("$resolver" modem0)" = mhi_hwip7 ]
# Exercise protocol detection with the real resolver and driver symlinks.
eval "$(awk '$0 == "get_driver()" { capture=1 } capture { print } capture && $0 == "}" { exit }' "$package_dir/files/usr/share/qmodem/generic.sh")"
export QMODEM_SYSFS_ROOT="$fixture/sys"
mkdir -p "$fixture/sys/class/net" "$fixture/drivers/mhi_net"
ln -s "$fixture/device/mhi4/mhi4_IP_HW0/net/mhi_hwip7" "$fixture/sys/class/net/mhi_hwip7"
ln -s "$fixture/device/mhi4/mhi4_IP_HW0" "$fixture/device/mhi4/mhi4_IP_HW0/net/mhi_hwip7/device"
ln -s "$fixture/drivers/mhi_net" "$fixture/device/mhi4/mhi4_IP_HW0/driver"
modem_path="$fixture/device"
[ "$(get_driver)" = qmi ]
# More than one independent hardware endpoint must still fail closed.
mkdir -p "$fixture/device/mhi4/mhi4_IP_HW0/net/mhi_hwip8"
! "$resolver" modem0
rmdir "$fixture/device/mhi4/mhi4_IP_HW0/net/mhi_hwip8"
rm "$fixture/device/mhi4/mhi4_IP_HW0/net/mhi_hwip7/device"
rmdir "$fixture/device/mhi4/mhi4_IP_HW0/net/mhi_hwip7"
# A control-only MBIM port does not create a second data endpoint.
mkdir -p "$fixture/device/mhi4/wwan/wwan9/wwan9mbim0"
! "$resolver" modem0
# Native WWAN MBIM default link can be parented directly to the controller.
mkdir -p "$fixture/device/mhi4/net/wwan7" "$fixture/device/mhi4/mhi4_IP_HW0_MBIM" "$fixture/drivers/mhi_wwan_mbim"
ln -s "$fixture/device/mhi4/net/wwan7" "$fixture/sys/class/net/wwan7"
ln -s "$fixture/drivers/mhi_wwan_mbim" "$fixture/device/mhi4/mhi4_IP_HW0_MBIM/driver"
[ "$("$resolver" modem0)" = wwan7 ]
[ "$(get_driver)" = mbim ]
echo 'modem endpoint tests passed (USB, nested QMI, generic MHI HW/SW, native MBIM, ambiguity, replug)'
