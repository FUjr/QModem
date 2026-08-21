#!/bin/sh

misectel_led_init()
{
	local board

	board="$(cat /tmp/sysinfo/board_name 2>/dev/null)"
	case "$board" in
		misectel,m01k21)
			LED_SIGNAL_POOR='lede:blue:4gyellow'
			LED_SIGNAL_GOOD='lede:blue:5gblue'
			LED_SIGNAL_EXCELLENT='lede:blue:5gyellow'
			LED_SIM='lede:blue:4gblue'
			LED_5G='lede:blue:red'
			;;
		misectel,m01k43|misectel,m01k43-usb|misectel,m01k43-usb-p|misectel,m01k43-p)
			LED_4G_POOR='yellow:4g'
			LED_4G_GOOD='blue:4g'
			LED_5G_POOR='yellow:5g'
			LED_5G_GOOD='blue:5g'
			LED_INTERNET_BLUE='blue:wan'
			LED_INTERNET_RED='red:wan'
			;;
		misectel,m02k45)
			LED_4G_POOR='4g:yellow'
			LED_4G_GOOD='4g:blue'
			LED_5G_POOR='5g:yellow'
			LED_5G_GOOD='5g:blue'
			LED_INTERNET_BLUE='sys:blue'
			LED_INTERNET_RED='sys:red'
			;;
		*) return 1 ;;
	esac
}

misectel_3led_signal_level()
{
	local rsrp="$1"

	case "$rsrp" in
		-*) ;;
		*) echo none; return ;;
	esac
	[ "$rsrp" -ge -140 ] 2>/dev/null && [ "$rsrp" -le -30 ] 2>/dev/null || {
		echo none
		return
	}
	if [ "$rsrp" -ge -90 ]; then
		echo excellent
	elif [ "$rsrp" -gt -110 ]; then
		echo good
	else
		echo poor
	fi
}

misectel_rsrp_value()
{
	local cell_info="$1"
	local prefer_nr="$2"

	printf '%s\n' "$cell_info" | jq -r --arg prefer_nr "$prefer_nr" '
		[.modem_info[]?
			| select((.key | tostring | ascii_upcase) == "RSRP")
			| (.value | tostring
				| gsub("[[:space:]]"; "")
				| sub("[dD][bB][mM]$"; "")
				| tonumber?)] as $values
		| if ($values | length) == 0 then empty
		  elif $prefer_nr == "1" then $values[-1]
		  else $values[0]
		  end
		| floor
	' 2>/dev/null
}

led_turn()
{
	local path="/sys/class/leds/$1"
	local value="$2"
	local brightness

	[ -e "$path/brightness" ] || return
	[ ! -e "$path/trigger" ] || echo none > "$path/trigger" 2>/dev/null
	if [ "$value" = 1 ]; then
		brightness="$(cat "$path/max_brightness")"
	else
		brightness=0
	fi
	echo "$brightness" > "$path/brightness"
}

led_heartbeat()
{
	local path="/sys/class/leds/$1"

	[ -e "$path/brightness" ] || return
	echo "$(cat "$path/max_brightness")" > "$path/brightness"
	echo heartbeat > "$path/trigger"
}

led_netdev()
{
	local path="/sys/class/leds/$1"
	local device="$2"

	[ -e "$path/brightness" ] || return
	[ -n "$device" ] && [ -e "/sys/class/net/$device" ] || {
		led_heartbeat "$1"
		return
	}
	echo 1 > "$path/brightness"
	echo netdev > "$path/trigger"
	echo "$device" > "$path/device_name"
	echo 1 > "$path/link"
	echo 1 > "$path/rx"
	echo 1 > "$path/tx"
}

modem_leds_off()
{
	led_turn "$LED_4G_POOR" 0
	led_turn "$LED_4G_GOOD" 0
	led_turn "$LED_5G_POOR" 0
	led_turn "$LED_5G_GOOD" 0
}

internet_leds_off()
{
	led_turn "$LED_INTERNET_BLUE" 0
	led_turn "$LED_INTERNET_RED" 0
}

internet_led_connected()
{
	led_turn "$LED_INTERNET_RED" 0
	led_turn "$LED_INTERNET_BLUE" 1
}

internet_led_disconnected()
{
	led_turn "$LED_INTERNET_BLUE" 0
	led_turn "$LED_INTERNET_RED" 1
}
