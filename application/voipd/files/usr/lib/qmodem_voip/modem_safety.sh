#!/bin/sh
QMODEM_VOIP_JOURNAL=${QMODEM_VOIP_JOURNAL:-/var/lib/qmodem_voip/modem-safety.journal}
QMODEM_VOIP_ADAPTER=${QMODEM_VOIP_ADAPTER:-/usr/lib/qmodem_voip/at_daemon_adapter.sh}
QMODEM_VOIP_SUPPORTS=${QMODEM_VOIP_SUPPORTS:-/usr/share/qmodem/modem_supports.json}
[ -r "$QMODEM_VOIP_ADAPTER" ] && . "$QMODEM_VOIP_ADAPTER"

qmodem_voip_fault() { printf '%s\n' "FAULT: $*" >&2; return 1; }
qmodem_voip_at() { qmodem_voip_adapter_at "$1" || qmodem_voip_fault "AT transport failed"; }

qmodem_voip_value()
{
	value=$(qmodem_voip_at "$1") || return 1
	[ -n "$value" ] || { qmodem_voip_fault 'empty AT value'; return 1; }
	case $value in *'\n'*|*'\r'*|*=*) qmodem_voip_fault 'unsafe AT value' ;; *) printf '%s' "$value" ;; esac
}

qmodem_voip_json() { jsonfilter -i "$QMODEM_VOIP_SUPPORTS" -e "$1" 2>/dev/null; }

qmodem_voip_load_capability()
{
	requested_model=$1 requested_firmware=$2 requested_usb_id=$3
	[ -r "$QMODEM_VOIP_SUPPORTS" ] || { qmodem_voip_fault 'modem capability file unavailable'; return 1; }
	[ "$(qmodem_voip_json '@.schema')" = 1 ] || { qmodem_voip_fault 'modem capability schema invalid'; return 1; }
	capability_models=$(qmodem_voip_json '@.modems[*].model') || {
		qmodem_voip_fault 'modem capability JSON malformed'; return 1
	}
	capability_index=0 capability_matches=0
	for capability_model in $capability_models; do
		capability_firmware=$(qmodem_voip_json "@.modems[$capability_index].firmware") || return 1
		capability_usb_id=$(qmodem_voip_json "@.modems[$capability_index].usb_id") || return 1
		if [ "$capability_model" = "$requested_model" ] &&
		   [ "$capability_firmware" = "$requested_firmware" ] &&
		   [ "$capability_usb_id" = "$requested_usb_id" ]; then
			capability_matches=$((capability_matches + 1))
			media_method=$(qmodem_voip_json "@.modems[$capability_index].audio.method") || return 1
			media_adb_unlock=$(qmodem_voip_json "@.modems[$capability_index].adb_unlock") || return 1
			case $media_adb_unlock in
				true|1) media_adb_unlock=1 ;;
				false|0|'') media_adb_unlock=0 ;;
				*) qmodem_voip_fault 'ADB capability invalid'; return 1 ;;
			esac
			media_uac=$(qmodem_voip_json "@.modems[$capability_index].audio.uac") || return 1
			media_qpcmv=$(qmodem_voip_json "@.modems[$capability_index].audio.qpcmv") || return 1
			media_qaudmod=$(qmodem_voip_json "@.modems[$capability_index].audio.qaudmod") || return 1
			case $media_method in
				serial_pcm)
					media_interface=$(qmodem_voip_json "@.modems[$capability_index].audio.interface_number") || return 1
					media_rate=$(qmodem_voip_json "@.modems[$capability_index].audio.sample_rate") || return 1
					media_frame_ms=$(qmodem_voip_json "@.modems[$capability_index].audio.frame_ms") || return 1
					media_qdai=$(qmodem_voip_json "@.modems[$capability_index].audio.qdai") || return 1
					media_qpcmv_cfg=$(qmodem_voip_json "@.modems[$capability_index].audio.qpcmv_cfg") || return 1
					media_gps=$(qmodem_voip_json "@.modems[$capability_index].audio.gps_outport") || return 1
					media_transfer_bytes=$(qmodem_voip_json "@.modems[$capability_index].audio.transfer_bytes") || return 1
					media_transfer_interval=$(qmodem_voip_json "@.modems[$capability_index].audio.transfer_interval_ms") || return 1
					[ "$media_interface:$media_rate:$media_frame_ms:$media_qdai:$media_qpcmv_cfg:$media_qpcmv:$media_qaudmod:$media_transfer_bytes:$media_transfer_interval:$media_gps" = \
					  '01:8000:20:x,0,0,4,0,0,1,1:8000,20:1,0:2:1024:60:none' ] || {
						qmodem_voip_fault 'serial PCM capability invalid'; return 1
					}
					case $media_uac in false|0) ;; *)
						qmodem_voip_fault 'serial PCM UAC capability invalid'; return 1 ;;
					esac
					;;
				uac)
					case $media_uac:$media_qpcmv in true:1,2|1:1,2) ;; *)
						qmodem_voip_fault 'UAC capability invalid'; return 1 ;;
					esac
					media_interface=unused media_rate=unused media_frame_ms=unused
					media_qdai=unused media_qpcmv_cfg=unused media_gps=none
					;;
				pcm_socket)
					case $media_uac in false|0) ;; *)
						qmodem_voip_fault 'PCM socket UAC capability invalid'; return 1 ;;
					esac
					[ "$media_adb_unlock" = 0 ] || {
						qmodem_voip_fault 'PCM socket ADB capability invalid'; return 1
					}
					media_interface=unused media_rate=unused media_frame_ms=unused
					media_qdai=unused media_qpcmv_cfg=unused media_qpcmv=unused
					media_qaudmod=unused media_gps=none
					;;
				*) qmodem_voip_fault 'unknown modem media method'; return 1 ;;
			esac
		fi
		capability_index=$((capability_index + 1))
	done
	[ "$capability_matches" = 1 ] || { qmodem_voip_fault 'exact modem capability unavailable'; return 1; }
}

qmodem_voip_checksum() { sha256sum "$1" | awk '{print $1}'; }

qmodem_voip_write_journal()
{
	dir=$(dirname "$QMODEM_VOIP_JOURNAL"); mkdir -p "$dir" || return 1
	umask 077; tmp=$(mktemp "$dir/.modem-safety.XXXXXX") || return 1
	printf 'schema=2\nslot=%s\nmedia_method=%s\nmedia_adb_unlock=%s\nmedia_qdai=%s\nmedia_qpcmv_cfg=%s\nmedia_qpcmv=%s\nmedia_qaudmod=%s\nims=%s\nvoice_disable=%s\nqpcmv=%s\nqpcmv_cfg=%s\nqdai=%s\nqaudmod=%s\ngps_outport=%s\nusbcfg=%s\nphase=%s\n' \
		"$slot" "$media_method" "${media_adb_unlock:-0}" "$media_qdai" "$media_qpcmv_cfg" "$media_qpcmv" "$media_qaudmod" \
		"$ims" "$voice_disable" "$qpcmv" "$qpcmv_cfg" "$qdai" "$qaudmod" \
		"$gps_outport" "$usbcfg" "$1" >"$tmp" || return 1
	checksum=$(qmodem_voip_checksum "$tmp") || return 1
	printf 'checksum=%s\n' "$checksum" >>"$tmp" || return 1
	sync -f "$tmp" || { rm -f "$tmp"; return 1; }
	mv -f "$tmp" "$QMODEM_VOIP_JOURNAL" || return 1
	sync -f "$dir"
}

qmodem_voip_read_journal()
{
	[ -f "$QMODEM_VOIP_JOURNAL" ] || return 1
	checksum=$(awk -F= '$1 == "checksum" { count++; value=$2 } END { if (count != 1 || value == "") exit 1; print value }' "$QMODEM_VOIP_JOURNAL") || {
		qmodem_voip_fault 'journal checksum field invalid'; return 2
	}
	body=$(mktemp "${QMODEM_VOIP_JOURNAL}.verify.XXXXXX") || return 1
	qmodem_voip_journal_error() { rm -f "$body"; qmodem_voip_fault "$1"; return 2; }
	sed '/^checksum=/d' "$QMODEM_VOIP_JOURNAL" >"$body" || qmodem_voip_journal_error 'journal body read failed' || return 2
	actual=$(qmodem_voip_checksum "$body") || qmodem_voip_journal_error 'journal checksum failed' || return 2
	[ -n "$checksum" ] && [ "$checksum" = "$actual" ] || qmodem_voip_journal_error 'journal checksum invalid' || return 2
	seen_schema= seen_slot= seen_media_method= seen_media_adb_unlock= seen_media_qdai= seen_media_qpcmv_cfg= seen_media_qaudmod=
	seen_media_qpcmv= seen_ims= seen_voice_disable= seen_qpcmv= seen_qpcmv_cfg=
	seen_qdai= seen_qaudmod= seen_gps_outport= seen_usbcfg= seen_phase=
	# Schema-2 journals created before persistent ADB support are migrated enabled.
	media_qaudmod=2 media_adb_unlock=1
	cr=$(printf '\r')
	while IFS='=' read -r key value extra; do
		[ -n "$key" ] && [ -z "$extra" ] || qmodem_voip_journal_error 'journal field syntax invalid' || return 2
		case $value in *"$cr"*|*=*)
			qmodem_voip_journal_error 'journal value delimiter corruption' || return 2 ;;
		esac
			case $key in
				schema) [ -z "$seen_schema" ] || qmodem_voip_journal_error 'journal field duplicate' || return 2; schema=$value; seen_schema=1 ;;
				slot) [ -z "$seen_slot" ] || qmodem_voip_journal_error 'journal field duplicate' || return 2; slot=$value; seen_slot=1 ;;
				media_method) [ -z "$seen_media_method" ] || qmodem_voip_journal_error 'journal field duplicate' || return 2; media_method=$value; seen_media_method=1 ;;
				media_adb_unlock) [ -z "$seen_media_adb_unlock" ] || qmodem_voip_journal_error 'journal field duplicate' || return 2; case $value in 0|1) ;; *) qmodem_voip_journal_error 'journal ADB field invalid' || return 2 ;; esac; media_adb_unlock=$value; seen_media_adb_unlock=1 ;;
				media_qdai) [ -z "$seen_media_qdai" ] || qmodem_voip_journal_error 'journal field duplicate' || return 2; media_qdai=$value; seen_media_qdai=1 ;;
				media_qpcmv_cfg) [ -z "$seen_media_qpcmv_cfg" ] || qmodem_voip_journal_error 'journal field duplicate' || return 2; media_qpcmv_cfg=$value; seen_media_qpcmv_cfg=1 ;;
				media_qpcmv) [ -z "$seen_media_qpcmv" ] || qmodem_voip_journal_error 'journal field duplicate' || return 2; media_qpcmv=$value; seen_media_qpcmv=1 ;;
				media_qaudmod) [ -z "$seen_media_qaudmod" ] || qmodem_voip_journal_error 'journal field duplicate' || return 2; media_qaudmod=$value; seen_media_qaudmod=1 ;;
				ims) [ -z "$seen_ims" ] || qmodem_voip_journal_error 'journal field duplicate' || return 2; ims=$value; seen_ims=1 ;;
				voice_disable) [ -z "$seen_voice_disable" ] || qmodem_voip_journal_error 'journal field duplicate' || return 2; voice_disable=$value; seen_voice_disable=1 ;;
				qpcmv) [ -z "$seen_qpcmv" ] || qmodem_voip_journal_error 'journal field duplicate' || return 2; qpcmv=$value; seen_qpcmv=1 ;;
				qpcmv_cfg) [ -z "$seen_qpcmv_cfg" ] || qmodem_voip_journal_error 'journal field duplicate' || return 2; qpcmv_cfg=$value; seen_qpcmv_cfg=1 ;;
				qdai) [ -z "$seen_qdai" ] || qmodem_voip_journal_error 'journal field duplicate' || return 2; qdai=$value; seen_qdai=1 ;;
			qaudmod) [ -z "$seen_qaudmod" ] || qmodem_voip_journal_error 'journal field duplicate' || return 2; qaudmod=$value; seen_qaudmod=1 ;;
			gps_outport) [ -z "$seen_gps_outport" ] || qmodem_voip_journal_error 'journal field duplicate' || return 2; gps_outport=$value; seen_gps_outport=1 ;;
			usbcfg) [ -z "$seen_usbcfg" ] || qmodem_voip_journal_error 'journal field duplicate' || return 2; usbcfg=$value; seen_usbcfg=1 ;;
			phase) [ -z "$seen_phase" ] || qmodem_voip_journal_error 'journal field duplicate' || return 2; phase=$value; seen_phase=1 ;;
			*) qmodem_voip_journal_error 'journal field unknown' || return 2 ;;
		esac
	done <"$body"
	rm -f "$body"
	[ "$seen_schema$seen_slot$seen_media_method$seen_media_qdai$seen_media_qpcmv_cfg$seen_media_qpcmv$seen_ims$seen_voice_disable$seen_qpcmv$seen_qpcmv_cfg$seen_qdai$seen_qaudmod$seen_gps_outport$seen_usbcfg$seen_phase" = 111111111111111 ] || {
		qmodem_voip_fault 'journal field missing'; return 2
	}
	[ "$schema" = 2 ] || { qmodem_voip_fault 'journal schema unsupported'; return 2; }
	case $media_method in serial_pcm|uac|pcm_socket) ;; *) qmodem_voip_fault 'journal media method invalid'; return 2 ;; esac
}

qmodem_voip_probe()
{
	model=$(qmodem_voip_value 'AT+CGMM') || return 1
	firmware=$(qmodem_voip_value 'AT+CGMR') || return 1
	slot=$(qmodem_voip_adapter_usb_slot) || return 1
	usb_id=$(qmodem_voip_adapter_usb_id) || return 1
	qmodem_voip_load_capability "$model" "$firmware" "$usb_id" || return 1
	[ "$(qmodem_voip_value 'AT+CPIN?')" = READY ] || return 1
	lte_status=$(qmodem_voip_value 'AT+CEREG?') || return 1
	nr_status=$(qmodem_voip_value 'AT+C5GREG?') || return 1
	case $lte_status:$nr_status in registered:*|*:registered) ;; *) return 1 ;; esac
	if [ "$media_method" != pcm_socket ]; then
		case $(qmodem_voip_value 'AT+QMBNCFG="list"') in CMCC|CU) ;; *) return 1 ;; esac
		case $(qmodem_voip_value 'AT+QCFG="ims"') in 0|1) ;; *) return 1 ;; esac
	fi
	qmodem_voip_adapter_rediscover "$slot" >/dev/null || return 1
	printf 'SUPPORTED slot=%s\n' "$slot"
}

qmodem_voip_capture_baseline()
{
	ims=$(qmodem_voip_value 'AT+QCFG="ims"') || return 1
	voice_disable=$(qmodem_voip_value 'AT+QCALLCFG="voice_disable"') || return 1
	qpcmv=$(qmodem_voip_value 'AT+QPCMV?') || return 1
	if [ "$media_method" = serial_pcm ]; then
		qpcmv_cfg=$(qmodem_voip_value 'AT+QAUDCFG="qpcmv_cfg"') || return 1
		qdai=$(qmodem_voip_value 'AT+QDAI?') || return 1
	else
		qpcmv_cfg=unused qdai=unused
	fi
	qaudmod=$(qmodem_voip_value 'AT+QAUDMOD?') || return 1
	gps_outport=$(qmodem_voip_value 'AT+QGPSCFG="outport"') || return 1
	usbcfg=$(qmodem_voip_value 'AT+QCFG="usbcfg"') || return 1
}

qmodem_voip_usbcfg_audio()
{
	requested_uac=$1
	requested_usbcfg=${2:-$usbcfg}
	printf '%s\n' "$requested_usbcfg" | awk -F, -v uac="$requested_uac" -v adb="${media_adb_unlock:-0}" \
		'BEGIN { OFS = "," } NF == 9 && ($9 == 0 || $9 == 1) && (adb == 0 || adb == 1) { $9 = uac; if (adb == 1) $8 = 1; print; found = 1 } END { if (!found) exit 1 }'
}

qmodem_voip_apply_media_forwarding()
{
	remaining=${1:-15}
	while [ "$remaining" -gt 0 ]; do
		if [ "$media_method" != serial_pcm ] || {
		   qmodem_voip_at "AT+QAUDMOD=$media_qaudmod" >/dev/null &&
		   qmodem_voip_at "AT+QAUDCFG=\"qpcmv_cfg\",$media_qpcmv_cfg" >/dev/null; }; then
			qmodem_voip_at "AT+QPCMV=$media_qpcmv" >/dev/null && return 0
		fi
		sleep 1
		remaining=$((remaining - 1))
	done
	return 1
}

qmodem_voip_reboot_and_wait()
{
	requested_slot=$1
	requested_uac=$2
	# CFUN may disconnect the AT port before its OK response is delivered.
	# USB disappearance and re-enumeration are the authoritative result.
	qmodem_voip_at 'AT+CFUN=1,1' >/dev/null 2>&1 || :
	qmodem_voip_adapter_wait_reenumeration "$requested_slot" "$requested_uac" 60
}

qmodem_voip_restore()
{
	qmodem_voip_read_journal || return $?
	if [ "$media_method" = pcm_socket ]; then
		rm -f "$QMODEM_VOIP_JOURNAL"
		return 0
	fi
	qmodem_voip_adapter_rediscover "$slot" >/dev/null || return 1
	qmodem_voip_at "AT+QCFG=\"ims\",$ims" >/dev/null || return 1
	qmodem_voip_at "AT+QCALLCFG=\"voice_disable\",$voice_disable" >/dev/null || return 1
	qmodem_voip_at "AT+QPCMV=$qpcmv" >/dev/null || return 1
	if [ "$media_method" = serial_pcm ]; then
		qmodem_voip_at "AT+QAUDCFG=\"qpcmv_cfg\",$qpcmv_cfg" >/dev/null || return 1
		qmodem_voip_at "AT+QDAI=$qdai" >/dev/null || return 1
	fi
	qmodem_voip_at "AT+QAUDMOD=$qaudmod" >/dev/null || return 1
	qmodem_voip_at "AT+QGPSCFG=\"outport\",$gps_outport" >/dev/null || return 1
	baseline_uac=$(printf '%s\n' "$usbcfg" | awk -F, 'NF == 9 { print $9 }') || return 1
	case $baseline_uac in 0|1) ;; *) return 1 ;; esac
	restore_usbcfg=$(qmodem_voip_usbcfg_audio "$baseline_uac" "$usbcfg") || return 1
	qmodem_voip_at "AT+QCFG=\"usbcfg\",$restore_usbcfg" >/dev/null || return 1
	qmodem_voip_reboot_and_wait "$slot" "$baseline_uac" || return 1
	rm -f "$QMODEM_VOIP_JOURNAL"
}

qmodem_voip_enable()
{
	if [ -f "$QMODEM_VOIP_JOURNAL" ]; then
		qmodem_voip_read_journal || return $?
		[ "$phase" = enabled ] || {
			qmodem_voip_fault 'incomplete modem safety transaction requires recovery'
			return 1
		}
		qmodem_voip_adapter_enable_ubus || {
			qmodem_voip_fault 'failed to enable the shared AT transport'
			return 1
		}
		qmodem_voip_recover
		return $?
	fi
	qmodem_voip_probe >/dev/null || { qmodem_voip_fault 'unsupported experimental modem prerequisites'; return 1; }
	qmodem_voip_adapter_enable_ubus || {
		qmodem_voip_fault 'failed to enable the shared AT transport'
		return 1
	}
	if [ "$media_method" = pcm_socket ]; then
		ims=unused voice_disable=unused qpcmv=unused qpcmv_cfg=unused qdai=unused
		qaudmod=unused gps_outport=unused usbcfg=unused
		qmodem_voip_write_journal enabled
		return $?
	fi
	qmodem_voip_capture_baseline || return 1
	case $media_uac in false|0) requested_uac=0 ;; true|1) requested_uac=1 ;; *) return 1 ;; esac
	audio_usbcfg=$(qmodem_voip_usbcfg_audio "$requested_uac") || { qmodem_voip_fault 'baseline USB tuple is not audio-toggleable'; return 1; }
	qmodem_voip_write_journal captured || return 1
	qmodem_voip_at 'AT+QCFG="ims",1' >/dev/null && qmodem_voip_write_journal ims || { qmodem_voip_restore; return 1; }
	qmodem_voip_at 'AT+QCALLCFG="voice_disable",2' >/dev/null && qmodem_voip_write_journal voice || { qmodem_voip_restore; return 1; }
	qmodem_voip_adapter_rediscover "$slot" >/dev/null || { qmodem_voip_restore; return 1; }
	qmodem_voip_at "AT+QAUDMOD=$media_qaudmod" >/dev/null && qmodem_voip_write_journal audio || { qmodem_voip_restore; return 1; }
	qmodem_voip_at "AT+QGPSCFG=\"outport\",\"$media_gps\"" >/dev/null && qmodem_voip_write_journal gps || { qmodem_voip_restore; return 1; }
	qmodem_voip_at "AT+QCFG=\"usbcfg\",$audio_usbcfg" >/dev/null && qmodem_voip_write_journal usb || { qmodem_voip_restore; return 1; }
	if [ "$media_method" = serial_pcm ]; then
		qmodem_voip_at "AT+QDAI=$media_qdai" >/dev/null && qmodem_voip_write_journal qdai || { qmodem_voip_restore; return 1; }
	fi
	qmodem_voip_write_journal reboot || { qmodem_voip_restore; return 1; }
	qmodem_voip_reboot_and_wait "$slot" "$requested_uac" || { qmodem_voip_restore; return 1; }
	qmodem_voip_adapter_rediscover "$slot" >/dev/null || { qmodem_voip_restore; return 1; }
	qmodem_voip_apply_media_forwarding 15 && qmodem_voip_write_journal forwarding || { qmodem_voip_restore; return 1; }
	qmodem_voip_write_journal enabled || { qmodem_voip_restore; return 1; }
}

qmodem_voip_disable() { [ -f "$QMODEM_VOIP_JOURNAL" ] && qmodem_voip_restore || [ ! -f "$QMODEM_VOIP_JOURNAL" ]; }
qmodem_voip_verify()
{
	[ -f "$QMODEM_VOIP_JOURNAL" ] || return 1
	qmodem_voip_read_journal || return $?
	[ "$phase" = enabled ] || return 1
	qmodem_voip_adapter_rediscover "$slot" >/dev/null || return 1
	[ "$media_method" != pcm_socket ] || return 0
	[ "$(qmodem_voip_value 'AT+QCFG="ims"')" = 1 ] || return 1
	[ "$(qmodem_voip_value 'AT+QCALLCFG="voice_disable"')" = 2 ] || return 1
	[ "$(qmodem_voip_value 'AT+QPCMV?')" = "$media_qpcmv" ] || return 1
	[ "$(qmodem_voip_value 'AT+QAUDMOD?')" = "$media_qaudmod" ] || return 1
	if [ "$media_method" = serial_pcm ]; then
		target_usbcfg=$(qmodem_voip_usbcfg_audio 0 "$usbcfg") || return 1
		[ "$(qmodem_voip_value 'AT+QCFG="usbcfg"')" = "$target_usbcfg" ] || return 1
		[ "$(qmodem_voip_value 'AT+QDAI?')" = "$media_qdai" ] || return 1
		[ "$(qmodem_voip_value 'AT+QAUDCFG="qpcmv_cfg"')" = "$media_qpcmv_cfg" ] || return 1
	fi
}
qmodem_voip_arm()
{
	current_qpcmv=
	[ -f "$QMODEM_VOIP_JOURNAL" ] || return 1
	qmodem_voip_read_journal || return $?
	[ "$phase" = enabled ] || return 1
	qmodem_voip_adapter_rediscover "$slot" >/dev/null || return 1
	[ "$media_method" != pcm_socket ] || return 0
	if [ "$media_method" = serial_pcm ]; then
		# QDAI is reboot-applied. During a call, only accept its persisted baseline.
		[ "$(qmodem_voip_value 'AT+QDAI?')" = "$media_qdai" ] || return 1
	fi
	# The voice server opens the stream when the call becomes active. Replaying
	# QAUDMOD/QAUDCFG here tears that stream down and can leave QPCMV capture
	# running without forwarding any RX PCM. Only repair a genuinely drifted
	# QPCMV state; an already-correct value is intentionally a no-op.
	current_qpcmv=$(qmodem_voip_value 'AT+QPCMV?') || return 1
	[ "$current_qpcmv" = "$media_qpcmv" ] && return 0
	qmodem_voip_apply_media_forwarding 3
}
qmodem_voip_recover()
{
	[ -f "$QMODEM_VOIP_JOURNAL" ] || return 0
	qmodem_voip_read_journal || return $?
	if [ "$phase" = enabled ]; then
		qmodem_voip_adapter_rediscover "$slot" >/dev/null || return 1
		[ "$media_method" != pcm_socket ] || return 0
		if [ "$media_method" = serial_pcm ]; then
			current_usbcfg=$(qmodem_voip_value 'AT+QCFG="usbcfg"') || return 1
			current_qdai=$(qmodem_voip_value 'AT+QDAI?') || return 1
			target_usbcfg=$(qmodem_voip_usbcfg_audio 0 "$usbcfg") || return 1
			if [ "$current_usbcfg" != "$target_usbcfg" ] || [ "$current_qdai" != "$media_qdai" ]; then
				qmodem_voip_at "AT+QCFG=\"usbcfg\",$target_usbcfg" >/dev/null || return 1
				qmodem_voip_at "AT+QDAI=$media_qdai" >/dev/null || return 1
				qmodem_voip_reboot_and_wait "$slot" 0 || return 1
					qmodem_voip_adapter_rediscover "$slot" >/dev/null || return 1
				fi
			qmodem_voip_at 'AT+QPCMV=0' >/dev/null || return 1
			fi
			qmodem_voip_apply_media_forwarding 15
		return $?
	fi
	qmodem_voip_restore
}
