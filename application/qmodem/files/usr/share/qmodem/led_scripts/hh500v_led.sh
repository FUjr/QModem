#!/bin/sh
#
# hh500v_led.sh
#
# TCL HH500V modem LED driver for QModem.
#
# QModem interface:
#   hh500v_led.sh <qmodem modem section>
#   hh500v_led.sh <qmodem modem section> off
#
# LED layout from HH500V DTS:
#   4G:
#       red:4g   = poor
#       green:4g = good
#       blue:4g  = excellent
#   5G:
#       red:5g   = poor
#       green:5g = good
#       blue:5g  = excellent
#
# Signal thresholds:
#   RSRP >= -90 dBm          -> excellent / blue
#   -110 < RSRP < -90 dBm    -> good / green
#   RSRP <= -110 dBm         -> poor / red
#   no valid RSRP            -> off
#

. /usr/share/qmodem/modem_util.sh 2>/dev/null
. /lib/functions.sh

MODEM_CFG="$1"
ACTION="$2"

ALL_LEDS="red:4g green:4g blue:4g red:5g green:5g blue:5g"
last_leds=""

set_leds() {
	local targets="$1"

	for led in $ALL_LEDS; do
		local path="/sys/class/leds/$led"
		[ -d "$path" ] || continue

		case " $targets " in
			*" $led "*)
				local max=$(cat "$path/max_brightness" 2>/dev/null)
				echo "${max:-1}" > "$path/brightness" 2>/dev/null
				;;
			*)
				echo 0 > "$path/brightness" 2>/dev/null
				;;
		esac
	done
}

get_color() {
	local rsrp="$1"
	rsrp=$(echo "$rsrp" | cut -d'.' -f1)

	if [ -z "$rsrp" ]; then
		echo ""
	elif [ "$rsrp" -ge -90 ] 2>/dev/null; then
		echo "blue"
	elif [ "$rsrp" -gt -110 ] 2>/dev/null; then
		echo "green"
	elif [ "$rsrp" -le -110 ] 2>/dev/null; then
		echo "red"
	else
		echo ""
	fi
}

if [ "$ACTION" = "off" ]; then
	set_leds ""
	exit 0
fi

[ -n "$MODEM_CFG" ] || exit 1

while true; do
	json=$(/usr/share/qmodem/modem_ctrl.sh cell_info "$MODEM_CFG" 2>/dev/null)
	mode=$(echo "$json" | jq -r '.modem_info[] | select(.key == "network_mode") | .value' 2>/dev/null)
	target_leds=""
	case "$mode" in
		*EN-DC*)
			rsrp_4g=$(echo "$json" | jq -r '.modem_info[] | select(.key == "RSRP" and .extra_info == "LTE") | .value' 2>/dev/null)
			rsrp_5g=$(echo "$json" | jq -r '.modem_info[] | select(.key == "RSRP" and .extra_info == "NR") | .value' 2>/dev/null)

			color_4g=$(get_color "$rsrp_4g")
			color_5g=$(get_color "$rsrp_5g")

			[ -n "$color_4g" ] && target_leds="$color_4g:4g"
			[ -n "$color_5g" ] && target_leds="$target_leds $color_5g:5g"
			;;
		*5G*|*NR*)
			rsrp=$(echo "$json" | jq -r '.modem_info[] | select(.key == "RSRP") | .value' 2>/dev/null | tail -n 1)
			color=$(get_color "$rsrp")
			[ -n "$color" ] && target_leds="$color:5g"
			;;
		*4G*|*LTE*)
			rsrp=$(echo "$json" | jq -r '.modem_info[] | select(.key == "RSRP") | .value' 2>/dev/null | head -n 1)
			color=$(get_color "$rsrp")
			[ -n "$color" ] && target_leds="$color:4g"
			;;
		*)
			target_leds=""
			;;
	esac

	if [ "$target_leds" != "$last_leds" ]; then
		set_leds "$target_leds"
		last_leds="$target_leds"
	fi

	sleep 5
done
