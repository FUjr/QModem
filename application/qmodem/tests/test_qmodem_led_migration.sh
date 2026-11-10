#!/bin/bash

set -euo pipefail
shopt -s lastpipe

declare -A DB

uci()
{
	[[ "$1" == -q ]] || return 1
	local op="$2" arg="${3-}" key value config
	case "$op" in
		get)
			[[ -n "${DB[$arg]+x}" ]] || return 1
			printf '%s\n' "${DB[$arg]}"
			;;
		set)
			key="${arg%%=*}"
			value="${arg#*=}"
			DB["$key"]="$value"
			;;
		delete)
			unset 'DB['"$arg"']'
			for key in "${!DB[@]}"; do
				[[ "$key" == "$arg."* ]] && unset 'DB['"$key"']'
			done
			return 0
			;;
		commit) ;;
		show)
			config="$arg"
			for key in "${!DB[@]}"; do
				[[ "$key" == "$config."* ]] || continue
				printf "%s='%s'\n" "$key" "${DB[$key]}"
			done | sort
			;;
		*) return 1 ;;
	esac
}

logger() { :; }

QMODEM_PACKAGE_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
source <(awk 'NR >= 6 && /^board=/ {exit} NR >= 6 {print}' \
	"${QMODEM_PACKAGE_DIR}/files/etc/uci-defaults/99-qmodem-board")

DB=(
	[qmodem.usb0]=modem-slot
	[qmodem.usb0.slot]=2-1
	[qmodem.usb0.led_script]=m02k45
	[qmodem.dev0]=modem-device
	[qmodem.dev0.path]=/sys/bus/usb/devices/2-1/
	[qmodem.dev0.led_script]=m02k45
	[qmodem_led.network_detect]=led
	[qmodem_led.network_detect.enabled]=0
	[qmodem_led.network_detect.script]=network_detect
	[qmodem_led.network_detect.bind]=none
	[qmodem_led.modem_status]=led
	[qmodem_led.modem_status.enabled]=1
	[qmodem_led.modem_status.script]=m02k45
	[qmodem_led.modem_status.bind]=any
	[qmodem_led.internet]=network_detect
	[qmodem_led.internet.enabled]=1
	[qmodem_led.internet.script]=misectel_network_detect
	[qmodem_led.cellular]=modem_status
	[qmodem_led.cellular.enabled]=1
	[qmodem_led.cellular.script]=misectel_modem_status
	[qmodem_led.cellular.bind]=any
)

migrate_led_schema
migrate_misectel_leds misectel,m02k45
migrate_legacy_leds

[[ "${DB[qmodem_led.internet]}" == network_detect ]]
[[ "${DB[qmodem_led.internet.enabled]}" == 0 ]]
[[ "${DB[qmodem_led.internet.script]}" == misectel_network_detect ]]
[[ "${DB[qmodem_led.cellular]}" == modem_status ]]
[[ "${DB[qmodem_led.cellular.script]}" == misectel_modem_status ]]
[[ "${DB[qmodem_led.cellular.bind]}" == any ]]
[[ ! -v 'DB[qmodem_led.network_detect]' ]]
[[ ! -v 'DB[qmodem_led.modem_status]' ]]
[[ ! -v 'DB[qmodem.usb0.led_script]' ]]
[[ ! -v 'DB[qmodem.dev0.led_script]' ]]

for key in "${!DB[@]}"; do
	[[ "$key" != qmodem_led.legacy_* ]]
done

before="$(declare -p DB)"
migrate_led_schema
migrate_misectel_leds misectel,m02k45
migrate_legacy_leds
after="$(declare -p DB)"
[[ "$before" == "$after" ]]

DB=(
	[qmodem.modem0]=modem-device
	[qmodem.modem0.led_script]=m01k43
	[qmodem_led.modem_status]=modem_status
	[qmodem_led.modem_status.enabled]=1
	[qmodem_led.modem_status.script]=misectel_modem_status
	[qmodem_led.modem_status.bind]=any
	[qmodem_led.cellular]=modem_status
	[qmodem_led.cellular.enabled]=0
	[qmodem_led.cellular.script]=misectel_modem_status
	[qmodem_led.cellular.bind]=port
	[qmodem_led.cellular.port]=2-1
)

configure_m01k21_leds misectel,m01k21

[[ ! -v 'DB[qmodem.modem0.led_script]' ]]
[[ ! -v 'DB[qmodem_led.modem_status]' ]]
[[ "${DB[qmodem_led.cellular]}" == modem_status ]]
[[ "${DB[qmodem_led.cellular.enabled]}" == 1 ]]
[[ "${DB[qmodem_led.cellular.script]}" == misectel_3led ]]
[[ "${DB[qmodem_led.cellular.bind]}" == any ]]
[[ ! -v 'DB[qmodem_led.cellular.port]' ]]

before="$(declare -p DB)"
configure_m01k21_leds misectel,m01k21
after="$(declare -p DB)"
[[ "$before" == "$after" ]]

# USB-P upgrades must stop routing USB probes through a nonexistent PCIe slot.
for usb_port in 2-1 2-1.1 2-1.3; do
	DB=(
		[qmodem.main]=main
		[qmodem.main.enable_pcie_scan]=1
		[qmodem.main.try_preset_pcie]=1
		[qmodem.usb0]=modem-slot
		[qmodem.usb0.slot]="$usb_port"
		[qmodem.usb0.scan_priority]=pcie
		[qmodem.usb0.alias]=custom_wwan
		[qmodem.pcie0]=modem-slot
		[qmodem.pcie0.type]=pcie
		[qmodem.pcie0.associated_usb]=2-1.1
		[qmodem.modem0]=modem-device
		[qmodem.modem0.at_port]=/dev/ttyUSB5
	)
	before="$(declare -p DB)"
	fix_m01k43_usb_p misectel,m01k43
	[[ "$before" == "$(declare -p DB)" ]]
	fix_m01k43_usb_p misectel,m01k43-usb-p
	[[ ! -v 'DB[qmodem.pcie0]' ]]
	[[ ! -v 'DB[qmodem.pcie0.associated_usb]' ]]
	[[ "${DB[qmodem.usb0.scan_priority]}" == usb ]]
	[[ "${DB[qmodem.main.enable_pcie_scan]}" == 0 ]]
	[[ "${DB[qmodem.main.try_preset_pcie]}" == 0 ]]
	[[ "${DB[qmodem.usb0.alias]}" == custom_wwan ]]
	[[ "${DB[qmodem.modem0.at_port]}" == /dev/ttyUSB5 ]]
	expected_port="$usb_port"
	[[ "$usb_port" != 2-1 ]] || expected_port=2-1.1
	[[ "${DB[qmodem.usb0.slot]}" == "$expected_port" ]]
	before="$(declare -p DB)"
	fix_m01k43_usb_p misectel,m01k43-usb-p
	[[ "$before" == "$(declare -p DB)" ]]
done

for board in misectel,m01k43-usb-p misectel,m01k43 misectel,m02k45; do
	board_json="$(
		. "$QMODEM_PACKAGE_DIR/tests/lib/jshn_stub.sh"
		. "$QMODEM_PACKAGE_DIR/files/lib/functions/qmodem-defaults.sh"
		json_select_object() { json_select "$1"; }
		board_name() { echo "$board"; }
		board_config_update() { json_init; }
		board_config_flush() { json_dump; }
		eval "$(sed '/^\. /d' "$QMODEM_PACKAGE_DIR/files/etc/board.d/03_qmodem")"
	)"
	if [[ "$board" == misectel,m01k43-usb-p ]]; then
		jq -e '.qmodem | (.slots | keys) == ["usb0"] and
			.slots.usb0.slot == "2-1.1" and .slots.usb0.scan_priority == "usb" and
			.main.enable_pcie_scan == "0" and .main.try_preset_pcie == "0"' \
			<<< "$board_json" >/dev/null
	else
		jq -e '.qmodem.slots | has("pcie0") and .usb0.scan_priority == "pcie"' \
			<<< "$board_json" >/dev/null
	fi
done

echo 'qmodem LED and USB-P board migration tests passed'
