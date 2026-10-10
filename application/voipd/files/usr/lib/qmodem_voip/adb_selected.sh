#!/bin/sh
# Resolve the ADB target from the selected modem's physical USB slot every time.
# Never fall back to the first attached Android device.
set -eu
. /usr/lib/qmodem_voip/at_daemon_adapter.sh
slot=$(qmodem_voip_adapter_usb_slot) || exit 1
serial=$(/usr/bin/adb devices -l | awk -v target="usb:$slot" '$2 == "device" { for (i=3;i<=NF;i++) if ($i == target) { count++; serial=$1 } } END { if (count == 1) print serial; else exit 1 }') || exit 1
[ -n "$serial" ] || exit 1
exec /usr/bin/adb -s "$serial" "$@"
