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
[ "$("$resolver" modem0)" = usb0 ]
# No SIM, dial service, or cellular address is present in this fixture.
mkdir "$fixture/device/interface/net/usb1"
! "$resolver" modem0
rmdir "$fixture/device/interface/net/usb0" "$fixture/device/interface/net/usb1"
! "$resolver" modem0
mkdir "$fixture/device/interface/net/usb1"
[ "$("$resolver" modem0)" = usb1 ]
! "$resolver" 'modem0;false'
echo 'modem endpoint tests passed (pre-dial, symlink, ambiguity, unplug, replug)'
