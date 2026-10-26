#!/bin/sh
# Select a board-declared PCIe backend before automatic modem discovery.
set -eu
slot=${1:-}
driver=${2:-}
id=${3:-}
case "$slot" in ''|*[!0-9a-fA-F:.]*) exit 2;; esac
# Only this tested device/backend pair is supported. Other PCIe devices keep
# their existing drivers, even when the same board accepts another modem.
[ "$driver:$id" = mhi_q:17cb:0308 ] || exit 2
device=/sys/bus/pci/devices/$slot
[ -d "$device" ] || exit 0
[ "$(cat "$device/vendor")" = 0x17cb ] || exit 0
[ "$(cat "$device/device")" = 0x0308 ] || exit 0
[ -d /sys/bus/pci/drivers/mhi_q ] || modprobe pcie_mhi
current=$(basename "$(readlink "$device/driver" 2>/dev/null || true)")
case "$current" in mhi_q|mhi-pci-generic|'') :;; *) exit 1;; esac
# FM160-EAU can fault during vendor MHI runtime resume. Forbid autosuspend
# before binding and keep it forbidden while this backend owns the device.
power=$(cat "$device/power/control")
echo on > "$device/power/control"
[ "$current" != mhi_q ] || exit 0
section=$(printf '%s' "$slot" | tr ':.' '__')
/etc/init.d/qmodem_network hang "$section" || true
override=$(cat "$device/driver_override")
[ "$override" != '(null)' ] || override=''
echo mhi_q > "$device/driver_override"
if [ -n "$current" ]; then
    if ! echo "$slot" > "/sys/bus/pci/drivers/$current/unbind"; then
        printf '%s\n' "$override" > "$device/driver_override"
        echo "$power" > "$device/power/control"
        exit 1
    fi
fi
if ! echo "$slot" > /sys/bus/pci/drivers/mhi_q/bind; then
    # Restore the previous binding if the selected backend cannot bind.
    printf '%s\n' "$override" > "$device/driver_override"
    [ -z "$current" ] || echo "$slot" > "/sys/bus/pci/drivers/$current/bind"
    echo "$power" > "$device/power/control"
    exit 1
fi
echo on > "$device/power/control"
