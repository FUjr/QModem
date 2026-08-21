#!/bin/sh

. /usr/share/qmodem/modem_util.sh
. /usr/share/qmodem/led_scripts/misectel_led.sh
. /lib/functions.sh

MODEM_CFG="$1"
ON_OFF="$2"
last_is_nr=0

update_cfg()
{
	config_load qmodem
	config_get AT_PORT "$MODEM_CFG" at_port
	config_get USE_UBUS "$MODEM_CFG" use_ubus
	use_ubus_flag=
	[ "$USE_UBUS" != 1 ] || use_ubus_flag=-u
}

sim_inserted()
{
	[ -n "$AT_PORT" ] && at "$AT_PORT" 'AT+CPIN?' | grep -q 'CPIN: READY'
}

get_mode()
{
	local cell_info="$1"
	local network_mode rat_code

	network_mode="$(printf '%s\n' "$cell_info" | jq -r '.modem_info[]? | select(.key == "network_mode") | .value' | head -n 1)"
	case "$network_mode" in
		*EN-DC*|*NR5G*|*NR*|*5G*) echo 1; return ;;
		*LTE*|*4G*|*WCDMA*|*3G*) echo 0; return ;;
	esac

	rat_code="$(at "$AT_PORT" 'AT+COPS?' | grep '+COPS:' | awk -F, '{print $4}' | tr -d '"')"
	case "$rat_code" in
		''|*[!0-9]*) echo "$last_is_nr" ;;
		*) [ "$rat_code" -le 7 ] && echo 0 || echo 1 ;;
	esac
}

all_leds_off()
{
	led_turn "$LED_SIGNAL_POOR" 0
	led_turn "$LED_SIGNAL_GOOD" 0
	led_turn "$LED_SIGNAL_EXCELLENT" 0
	led_turn "$LED_SIM" 0
	led_turn "$LED_5G" 0
}

update_leds()
{
	local cell_info is_nr rsrp signal_level

	if ! sim_inserted; then
		all_leds_off
		last_is_nr=0
		return
	fi

	led_turn "$LED_SIM" 1
	cell_info="$(/usr/share/qmodem/modem_ctrl.sh cell_info "$MODEM_CFG")"
	is_nr="$(get_mode "$cell_info")"
	last_is_nr="$is_nr"
	led_turn "$LED_5G" "$is_nr"

	rsrp="$(misectel_rsrp_value "$cell_info" "$is_nr")"
	signal_level="$(misectel_3led_signal_level "$rsrp")"
	led_turn "$LED_SIGNAL_POOR" 0
	led_turn "$LED_SIGNAL_GOOD" 0
	led_turn "$LED_SIGNAL_EXCELLENT" 0
	case "$signal_level" in
		poor) led_turn "$LED_SIGNAL_POOR" 1 ;;
		good) led_turn "$LED_SIGNAL_GOOD" 1 ;;
		excellent) led_turn "$LED_SIGNAL_EXCELLENT" 1 ;;
	esac
}

misectel_led_init || exit 1
update_cfg
if [ "$ON_OFF" = off ]; then
	all_leds_off
	exit 0
fi

while true; do
	update_cfg
	update_leds
	sleep 5
done
