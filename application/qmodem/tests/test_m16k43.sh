#!/bin/sh
set -eu
pkg="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
sed '/^\. /d' "$pkg/files/etc/board.d/03_qmodem" > "$tmp/board.sh"
board_config_update() { :; }
board_config_flush() { :; }
board_name() { echo "$test_board"; }
ucidef_set_qmodem_main() { echo "main $*"; }
ucidef_add_qmodem_slot() { echo "slot $*"; }
ucidef_add_qmodem_modem_status() { echo "led $*"; }
for test_board in misectel,m16k43 misectel,m16k43-usb; do
 output="$(. "$tmp/board.sh")"
 echo "$output" | grep -q 'gpio 5gpower gpio_up 0 gpio_down 1'
 echo "$output" | grep -q 'script misectel_3led bind any'
 if [ "$test_board" = misectel,m16k43-usb ]; then
  echo "$output" | grep -q 'enable_pcie_scan 0 try_preset_pcie 0'
  ! echo "$output" | grep -q 'slot pcie0'
 else
  echo "$output" | grep -q 'slot pcie0 type pcie slot 0000:01:00.0 associated_usb 2-1'
 fi
done
. "$pkg/files/usr/share/qmodem/led_scripts/misectel_led.sh"
LED_SIGNAL_POOR=rf1
LED_SIGNAL_GOOD=rf2
LED_SIGNAL_EXCELLENT=rf3
LED_SIGNAL_MAX=rf4
led_turn() { echo "$1=$2"; }
[ "$(misectel_3led_update_signal_leds max | tr '\n' ' ')" = 'rf4=1 rf1=1 rf2=1 rf3=1 ' ]
[ "$(misectel_3led_update_signal_leds poor | tr '\n' ' ')" = 'rf4=0 rf1=1 rf2=0 rf3=0 ' ]
echo 'M16K43 transport, power and cumulative RF tests passed'
