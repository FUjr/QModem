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
