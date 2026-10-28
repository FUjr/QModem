#!/bin/sh
qmodem_voip_adapter_device_exists() { [ -c "$1" ]; }

qmodem_voip_adapter_usb_slot()
{
	section=$(qmodem_voip_adapter_section) || return 1
	path=$(uci -q get "qmodem.$section.path") || return 1
	path=${path%/}
	slot=${path##*/}
	case $slot in ''|*[!0-9.-]*) return 1 ;; esac
	[ -d "${QMODEM_VOIP_SYSFS_ROOT:-/sys/bus/usb/devices}/$slot" ] || return 1
	printf '%s\n' "$slot"
}

qmodem_voip_adapter_section()
{
	match=
	for section in $(uci -q show qmodem 2>/dev/null |
		sed -n 's/^qmodem\.\([A-Za-z0-9_]*\)=modem-device$/\1/p'); do
		case $(uci -q get "qmodem.$section.name") in
			rm520n-gl) [ -n "$(uci -q get "qmodem.$section.voice_pcm_port")" ] || continue ;;
			rg500q-ea) ;;
			*) continue ;;
		esac
		[ "$(uci -q get "qmodem.$section.data_interface")" = usb ] || continue
		[ -n "$(uci -q get "qmodem.$section.at_port")" ] || continue
		[ -z "$match" ] || return 1
		match=$section
	done
	[ -n "$match" ] || return 1
	printf '%s\n' "$match"
}

qmodem_voip_adapter_enable_ubus()
{
	section=$(qmodem_voip_adapter_section) || return 1
	[ "$(uci -q get "qmodem.$section.use_ubus" 2>/dev/null)" = 1 ] && return 0
	uci -q set "qmodem.$section.use_ubus=1" || return 1
	uci -q commit qmodem
}

qmodem_voip_adapter_usb_id()
{
	slot=$(qmodem_voip_adapter_usb_slot) || return 1
	root=${QMODEM_VOIP_SYSFS_ROOT:-/sys/bus/usb/devices}
	vendor=$(cat "$root/$slot/idVendor" 2>/dev/null) || return 1
	product=$(cat "$root/$slot/idProduct" 2>/dev/null) || return 1
	case $vendor in ''|*[!0-9a-fA-F]*) return 1 ;; esac
	case $product in ''|*[!0-9a-fA-F]*) return 1 ;; esac
	printf '%s:%s\n' "$vendor" "$product"
}

qmodem_voip_adapter_endpoint()
{
	section=$(qmodem_voip_adapter_section) || return 1
	port=$(uci -q get "qmodem.$section.at_port") || return 1
	case $port in /dev/ttyUSB*|/dev/ttyACM*) ;; *) return 1 ;; esac
	qmodem_voip_adapter_device_exists \
		"${QMODEM_VOIP_DEVICE_ROOT:-/dev}/${port#/dev/}" || return 1
	printf '%s\n' "$port"
}

qmodem_voip_adapter_pcm_endpoint()
{
	section=$(qmodem_voip_adapter_section) || return 1
	port=$(uci -q get "qmodem.$section.voice_pcm_port") || return 1
	case $port in /dev/ttyUSB*|/dev/ttyACM*) ;; *) return 1 ;; esac
	qmodem_voip_adapter_device_exists \
		"${QMODEM_VOIP_DEVICE_ROOT:-/dev}/${port#/dev/}" || return 1
	printf '%s\n' "$port"
}

qmodem_voip_adapter_normalize()
{
	command=$1
	response=$(tr -d '\r' | sed '/^AT/d; /^OK$/d; /^$/d')
	case $command in
		AT+CGMM|AT+CGMR) printf '%s\n' "$response" | sed -n '1p' ;;
		AT+CPIN\?) printf '%s\n' "$response" | sed -n 's/^+CPIN: //p' ;;
		AT+CEREG\?)
			status=$(printf '%s\n' "$response" | sed -n 's/^+CEREG: [0-9]*,//p')
			case $status in 1|5) printf '%s\n' registered ;; *) printf '%s\n' unregistered ;; esac ;;
		AT+C5GREG\?)
			status=$(printf '%s\n' "$response" | sed -n 's/^+C5GREG: [0-9]*,//p')
			case $status in 1|5) printf '%s\n' registered ;; *) printf '%s\n' unregistered ;; esac ;;
		AT+QMBNCFG=\"list\")
			case $response in *CMCC*) printf '%s\n' CMCC ;; *CU*) printf '%s\n' CU ;; *) printf '%s\n' none ;; esac ;;
		AT+QCFG=\"ims\") printf '%s\n' "$response" | sed -n 's/^+QCFG: "ims",\([01]\)\(,.*\)\{0,1\}$/\1/p' ;;
		AT+QCALLCFG=\"voice_disable\") printf '%s\n' "$response" | sed -n 's/^+QCALLCFG: "voice_disable",//p' ;;
		AT+QPCMV\?) printf '%s\n' "$response" | sed -n 's/^+QPCMV: //p' ;;
		AT+QDAI\?) printf '%s\n' "$response" | sed -n 's/^+QDAI: //p' ;;
		AT+QAUDCFG=\"qpcmv_cfg\") printf '%s\n' "$response" | sed -n 's/^+QAUDCFG: "[Qq][Pp][Cc][Mm][Vv]_[Cc][Ff][Gg]",//p' ;;
		AT+QAUDMOD\?) printf '%s\n' "$response" | sed -n 's/^+QAUDMOD: //p' ;;
		AT+QGPSCFG=\"outport\") printf '%s\n' "$response" | sed -n 's/^+QGPSCFG: "outport",//p' ;;
		AT+QCFG=\"usbcfg\") printf '%s\n' "$response" | sed -n 's/^+QCFG: "usbcfg",//p' ;;
		*) printf '%s\n' "$response" ;;
	esac
}

qmodem_voip_adapter_port_open()
{
	target_port=$1
	daemon_ports=$(ubus call at-daemon list) || return 1
	json_load "$daemon_ports" 2>/dev/null || return 1
	json_select ports || return 1
	json_get_keys daemon_port_keys
	for daemon_port_key in $daemon_port_keys; do
		json_select "$daemon_port_key" || return 1
		json_get_var daemon_port port
		json_get_var daemon_port_open is_open
		json_select ..
		[ "$daemon_port" = "$target_port" ] || continue
		[ "$daemon_port_open" = 1 ] && return 0
		return 1
	done
	return 1
}

qmodem_voip_adapter_at()
{
	command=$1
	port=$(qmodem_voip_adapter_endpoint) || return 1
	command -v json_init >/dev/null 2>&1 || . /usr/share/libubox/jshn.sh || return 1
	if ! qmodem_voip_adapter_port_open "$port"; then
		json_init
		json_add_string at_port "$port"
		json_add_int baudrate 115200
		json_add_int databits 8
		json_add_int parity 0
		json_add_int stopbits 1
		json_add_int timeout 3
		ubus call at-daemon open "$(json_dump)" >/dev/null 2>&1 || :
	fi
	json_init
	json_add_string at_port "$port"
	json_add_string at_cmd "$command"
	payload=$(json_dump)
	attempt=0
	while [ "$attempt" -lt 3 ]; do
		result=$(ubus call at-daemon sendat "$payload") || result=
		status=$(printf '%s\n' "$result" | jsonfilter -e '@.status')
		end_flag=$(printf '%s\n' "$result" | jsonfilter -e '@.end_flag_matched')
		response=$(printf '%s\n' "$result" | jsonfilter -e '@.response')
		if [ "$status" = success ] && [ "$end_flag" = OK ] && [ -n "$response" ]; then
			printf '%s\n' "$response" | qmodem_voip_adapter_normalize "$command"
			return $?
		fi
		attempt=$((attempt + 1))
		sleep 1
	done
	return 1
}

qmodem_voip_adapter_rediscover()
{
	requested_slot=$1
	slot=$(qmodem_voip_adapter_usb_slot) || return 1
	[ "$slot" = "$requested_slot" ] || return 1
	qmodem_voip_adapter_endpoint || return 1
	section=$(qmodem_voip_adapter_section) || return 1
	[ -n "$(uci -q get "qmodem.$section.voice_pcm_port")" ] || return 0
	qmodem_voip_adapter_pcm_endpoint
}

qmodem_voip_adapter_wait_reenumeration()
{
	slot=$1
	want_audio=$2
	remaining=${3:-30}
	root=${QMODEM_VOIP_SYSFS_ROOT:-/sys/bus/usb/devices}
	proc=${QMODEM_VOIP_PROC_ASOUND_ROOT:-/proc/asound}
	saw_absent=0
	while [ "$remaining" -gt 0 ]; do
		endpoint=$(qmodem_voip_adapter_endpoint 2>/dev/null) || endpoint=
		pcm_endpoint=$(qmodem_voip_adapter_pcm_endpoint 2>/dev/null) || pcm_endpoint=
		[ -d "$root/$slot" ] && [ -n "$endpoint" ] || saw_absent=1
		has_audio=0
		for card in "$root/$slot"/"$slot":*/sound/card*; do
			[ -d "$card" ] && has_audio=1 && break
		done
		if [ "$saw_absent" = 1 ] && [ -n "$endpoint" ] && [ "$has_audio" = "$want_audio" ]; then
			[ "$want_audio" = 0 ] && [ -n "$pcm_endpoint" ] && return 0
			grep -q 'playback.*capture' "$proc/pcm" 2>/dev/null && return 0
		fi
		sleep 1
		remaining=$((remaining - 1))
	done
	return 1
}

if [ "${0##*/}" = at_daemon_adapter.sh ]; then
	case ${1:-} in
	at)
		[ "$#" -eq 2 ] || exit 64
		qmodem_voip_adapter_at "$2"
		;;
	endpoint)
		[ "$#" -eq 1 ] || exit 64
		qmodem_voip_adapter_endpoint
		;;
	*)
		exit 64
		;;
	esac
fi
