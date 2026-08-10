#!/bin/sh

set -eu

QMODEM_PACKAGE_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
helper="${QMODEM_PACKAGE_DIR}/files/usr/share/qmodem/led_scripts/misectel_led.sh"
board_script="${QMODEM_PACKAGE_DIR}/files/etc/board.d/03_qmodem"

. "$helper"

assert_level()
{
	local expected="$1"
	local rsrp="$2"
	local actual

	actual="$(misectel_3led_signal_level "$rsrp")"
	[ "$actual" = "$expected" ] || {
		echo "RSRP ${rsrp}: expected ${expected}, got ${actual}" >&2
		exit 1
	}
}

assert_level none invalid
assert_level none 0
assert_level none -141
assert_level poor -140
assert_level poor -120
assert_level poor -110
assert_level good -109
assert_level good -100
assert_level good -91
assert_level excellent -90
assert_level excellent -30
assert_level none -29

assert_rsrp()
{
	local expected="$1"
	local prefer_nr="$2"
	local cell_info="$3"
	local actual

	actual="$(misectel_rsrp_value "$cell_info" "$prefer_nr")"
	[ "$actual" = "$expected" ] || {
		echo "RSRP selection: expected ${expected}, got ${actual}" >&2
		exit 1
	}
}

dual_rsrp='{"modem_info":[{"key":"RSRP","value":"-88","extra_info":"LTE"},{"key":"RSRP","value":"-112","extra_info":"NR5G-NSA"}]}'
assert_rsrp -88 0 "$dual_rsrp"
assert_rsrp -112 1 "$dual_rsrp"
assert_rsrp -100 0 '{"modem_info":[{"key":"rsrp","value":" -99.4 dBm "}]}'
assert_rsrp '' 0 '{"modem_info":[{"key":"RSRP","value":"unknown"}]}'

grep -q 'misectel,m01k21)' "$board_script"
grep -q 'script misectel_3led bind any' "$board_script"
for led in \
	'lede:blue:4gyellow' \
	'lede:blue:5gblue' \
	'lede:blue:5gyellow' \
	'lede:blue:4gblue' \
	'lede:blue:red'
do
	grep -q "'$led'" "$helper"
done

echo 'misectel_3led tests passed'
