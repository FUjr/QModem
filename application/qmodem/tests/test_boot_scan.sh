#!/bin/sh
# Run the actual init functions with host-safe procd/UCI/client substitutes.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
sed -e '/^\. \$IPKG_INSTROOT\/lib\/functions.sh$/d' \
    -e 's@/usr/bin/modem_scanc@modem_scanc@g' \
    "$ROOT/files/etc/init.d/qmodem_init" > "$TMP/init.sh"
. "$TMP/init.sh"
config_load() { :; }
config_foreach() { :; }
_start_scand() { :; }
config_get() {
    value=$4
    case "$3" in
        enable_usb_scan) value=${USB_SETTING:-$4} ;;
        enable_pcie_scan) value=0 ;;
        block_auto_probe) value=${BLOCK_SETTING:-0} ;;
        scan_delay) value=${DELAY_SETTING:-$4} ;;
    esac
    eval "$1=\$value"
}
modem_scanc() {
    if [ "$1" = status ]; then
        n=$(cat "$TMP/attempts")
        echo $((n + 1)) > "$TMP/attempts"
        [ "$n" -ge 2 ]
    else
        echo "$*" >> "$TMP/scans"
    fi
}
sleep() { :; }
logger() { echo "$*" >> "$TMP/log"; }
reset() { echo 0 > "$TMP/attempts"; : > "$TMP/scans"; }
reset
start_service
wait
[ "$(cat "$TMP/scans")" = 'scan usb 0' ]
[ "$(cat "$TMP/attempts")" = 3 ]
reset
USB_SETTING=0 start_service
wait
[ ! -s "$TMP/scans" ]
reset
BLOCK_SETTING=1 start_service
wait
[ ! -s "$TMP/scans" ]
reset
DELAY_SETTING=7 start_service
wait
[ "$(cat "$TMP/scans")" = 'scan usb 7' ]
reset
DELAY_SETTING=invalid start_service
wait
[ "$(cat "$TMP/scans")" = 'scan usb 0' ]
# No daemon ever becomes ready: bounded failure, no recursive service start.
reset
modem_scanc() { echo x >> "$TMP/scans"; return 2; }
_queue_boot_scan usb
wait
[ "$(wc -l < "$TMP/scans")" -eq 30 ]
[ -s "$TMP/log" ]
echo 'PASS: default USB scan, explicit off, probe block, readiness retry, delay and bounded failure'
