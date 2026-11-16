#!/bin/sh
set -eu
PACKAGE_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
for board in misectel,m01k43-usb misectel,m01k43-usb-p misectel,m01k43 misectel,m02k45; do
    board_json="$(
        . "$PACKAGE_DIR/tests/lib/jshn_stub.sh"
        . "$PACKAGE_DIR/files/lib/functions/qmodem-defaults.sh"
        json_select_object() { json_select "$1"; }
        board_name() { echo "$board"; }
        board_config_update() { json_init; }
        board_config_flush() { json_dump; }
        eval "$(sed '/^\. /d' "$PACKAGE_DIR/files/etc/board.d/03_qmodem")"
    )"
    if [ "$board" = misectel,m01k43-usb-p ] || [ "$board" = misectel,m01k43-usb ]; then
        usb_port=2-1
        [ "$board" != misectel,m01k43-usb-p ] || usb_port=2-1.1
        printf '%s\n' "$board_json" | jq -e --arg port "$usb_port" '.qmodem |
            (.slots | keys) == ["usb0"] and
            .slots.usb0.type == "usb" and .slots.usb0.slot == $port and
            .slots.usb0.scan_priority == "usb" and
            .main.enable_pcie_scan == "0" and .main.try_preset_pcie == "0"' >/dev/null
    else
        printf '%s\n' "$board_json" | jq -e '.qmodem.slots |
            has("pcie0") and .usb0.scan_priority == "pcie"' >/dev/null
    fi
done
echo 'USB-P factory topology and unchanged PCIe board defaults passed'
