#!/bin/sh
set -eu
package_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
mkdir -p "$fixture/device/interface/net/usb0"
ln -s "$fixture/device" "$fixture/usb-slot"
cat > "$fixture/uci" <<'EOF'
#!/bin/sh
[ "$*" = '-q get qmodem.modem0.path' ] || exit 1
printf '%s\n' "$MODEM_TEST_PATH"
EOF
chmod +x "$fixture/uci"
export QMODEM_UCI="$fixture/uci" MODEM_TEST_PATH="$fixture/usb-slot"
resolver="$package_dir/files/usr/share/qmodem/modem_netdev.sh"
expect_failure() {
    if "$@" > "$fixture/rejected-output"; then
        echo 'expected endpoint discovery to fail' >&2
        exit 1
    fi
    [ ! -s "$fixture/rejected-output" ]
}
[ "$("$resolver" modem0)" = usb0 ]
# QMI multiplexing exposes nested net directories below the parent netdev.
mkdir -p "$fixture/device/interface/net/usb0/net/usb0_1"
[ "$("$resolver" modem0)" = usb0_1 ]
mkdir "$fixture/device/interface/net/usb0/net/usb0_2"
expect_failure "$resolver" modem0
rmdir "$fixture/device/interface/net/usb0/net/usb0_2"
# Independent USB interfaces are still ambiguous, even with nested children.
mkdir -p "$fixture/device/other-interface/net/usb2"
expect_failure "$resolver" modem0
rm -rf "$fixture/device/other-interface"
rm -rf "$fixture/device/interface/net/usb0/net"
# No SIM, dial service, or cellular address is present in this fixture.
mkdir "$fixture/device/interface/net/usb1"
expect_failure "$resolver" modem0
rmdir "$fixture/device/interface/net/usb0" "$fixture/device/interface/net/usb1"
expect_failure "$resolver" modem0
mkdir "$fixture/device/interface/net/usb1"
[ "$("$resolver" modem0)" = usb1 ]
expect_failure "$resolver" 'modem0;false'
# PCIe/MHI endpoint depth need not match USB interface depth.
mkdir -p "$fixture/pci/device/mhi/controller/channel/net/wwan0/net/wwan0_1"
MODEM_TEST_PATH="$fixture/pci" "$resolver" modem0 > "$fixture/result"
[ "$(cat "$fixture/result")" = wwan0_1 ]
# Empty mux directories and sysfs backlinks are not usable data endpoints.
rmdir "$fixture/pci/device/mhi/controller/channel/net/wwan0/net/wwan0_1"
MODEM_TEST_PATH="$fixture/pci" expect_failure "$resolver" modem0
rmdir "$fixture/pci/device/mhi/controller/channel/net/wwan0/net"
ln -s "$fixture/pci/device/mhi/controller/channel/net" "$fixture/pci/device/mhi/controller/channel/net/wwan0/net"
MODEM_TEST_PATH="$fixture/pci" expect_failure "$resolver" modem0
# A dangling configured symlink must fail rather than inventing an endpoint.
ln -s "$fixture/missing" "$fixture/dangling"
MODEM_TEST_PATH="$fixture/dangling" expect_failure "$resolver" modem0
echo 'modem endpoint tests passed (pre-dial, nested mux, USB/PCIe, symlink, ambiguity, unplug, replug)'

# Additional generic MHI cases from the remote branch.
export MODEM_TEST_PATH="$fixture/usb-slot"
SCRIPT_DIR="$package_dir/files/usr/share/qmodem"
modem_config=modem0
# Generic raw MHI: the auxiliary software channel is never a data candidate.
rmdir "$fixture/device/interface/net/usb1" "$fixture/device/interface/net"
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
rmdir "$fixture/device/mhi4/mhi4_IP_HW0/net"
# Native WWAN MBIM default link can be parented directly to the controller.
mkdir -p "$fixture/device/mhi4/net/wwan7" "$fixture/device/mhi4/mhi4_IP_HW0_MBIM" "$fixture/drivers/mhi_wwan_mbim"
ln -s "$fixture/device/mhi4/net/wwan7" "$fixture/sys/class/net/wwan7"
ln -s "$fixture/drivers/mhi_wwan_mbim" "$fixture/device/mhi4/mhi4_IP_HW0_MBIM/driver"
[ "$("$resolver" modem0)" = wwan7 ]
[ "$(get_driver)" = mbim ]
echo 'modem endpoint tests passed (USB, nested QMI, generic MHI HW/SW, native MBIM, ambiguity, replug)'
