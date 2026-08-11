#!/bin/sh
# pcie_modem_wait.sh — Poll for PCIe modem readiness before QModem scan
# Called from qmodem_init boot() to replace blind sleep for PCIe modems.
# USB modems are handled by hotplug (20-modem-net) and do not need this.
#
# Usage: pcie_modem_wait.sh [max_wait_seconds]
#
# Exit codes:
#   0 — At least one PCIe modem network device detected
#   1 — Timeout, no PCIe modem found (not an error if none installed)

MAX_WAIT=${1:-90}
POLL_INTERVAL=2
TAG="modem_pciew"

# PCIe net device prefixes recognized by modem_scan.sh scan_pcie()
PCIE_NET_PREFIXES="rmnet wwan"

_has_pcie_modem_hardware() {
    # Check if any PCI device has a class that could be a modem.
    # MHI-based Qualcomm modems use class 0xff0000 (vendor-specific)
    # MediaTek t7xx modems use wwan subsystem
    # Also check for known modem vendor IDs on PCI bus
    for dev in /sys/bus/pci/devices/*; do
        [ -e "$dev/vendor" ] || continue
        vendor=$(cat "$dev/vendor" 2>/dev/null)
        case "$vendor" in
            0x17cb) return 0 ;; # Qualcomm
            0x1eac) return 0 ;; # Quectel
            0x105b) return 0 ;; # Foxconn (HP rebrand)
            0x03f0) return 0 ;; # HP
            0x14c3) return 0 ;; # MediaTek
        esac
    done
    return 1
}

_has_pcie_netdev() {
    for prefix in $PCIE_NET_PREFIXES; do
        for netdev in /sys/class/net/${prefix}*; do
            [ -e "$netdev" ] || continue
            netdev_path=$(readlink -f "$netdev/device/" 2>/dev/null)
            [ -n "$netdev_path" ] || continue
            echo "$netdev_path" | grep -q "pci" && return 0
        done
    done
    return 1
}

# Phase 0: Check if any PCIe modem hardware exists at all.
# If not, exit immediately — nothing to wait for.
if ! _has_pcie_modem_hardware; then
    logger -t "$TAG" "No PCIe modem hardware detected, skipping wait"
    exit 1
fi

logger -t "$TAG" "PCIe modem hardware found, waiting for driver init (max ${MAX_WAIT}s)"

# Phase 1: Wait for a PCIe-backed network device to appear.
# This signals MHI (or t7xx) mission mode completion.
elapsed=0
while [ "$elapsed" -lt "$MAX_WAIT" ]; do
    if _has_pcie_netdev; then
        logger -t "$TAG" "PCIe modem network device appeared after ${elapsed}s"
        exit 0
    fi
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
done

logger -t "$TAG" "Timeout after ${MAX_WAIT}s waiting for PCIe modem network device"
exit 1