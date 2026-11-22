#!/bin/sh
# RM520N-GL native audio only. No ADB, injected libraries or service restarts.
# Called under the safety command's exclusive lock; never source device data.
rm520n_get() { awk -F= -v k="$1" '$1 == k { print substr($0, length(k)+2) }' "$QMODEM_VOIP_JOURNAL"; }
rm520n_error() { printf 'FAULT: RM520N-GL %s\n' "$1" >&2; return 1; }
rm520n_at() { qmodem_voip_adapter_at "$1"; }
rm520n_value() { qmodem_voip_value "$1"; }

rm520n_identity()
{
	n_slot=$(qmodem_voip_adapter_usb_slot) || return 1
	[ "$(qmodem_voip_adapter_usb_id)" = 2c7c:0801 ] || return 1
	[ "$(rm520n_value 'AT+CGMM')" = RM520N-GL ] || return 1
	n_firmware=$(rm520n_value 'AT+QGMR') || return 1
	# Share the authority with the C profile; the complete revision matters.
	n_supported=$(qmodem_voip_json '@.modems[@.model="RM520N-GL"].firmware') || return 1
	[ "$n_firmware" = "$n_supported" ] || rm520n_error 'unverified firmware'
}

rm520n_idle()
{
	# Match the call reducer: mode 1 records are cellular data contexts, not
	# voice calls. Reject malformed/unknown records and every voice state.
	# An AT timeout is never treated as idle.
	n_calls=$(rm520n_at 'AT+CLCC') || return 1
	printf '%s\n' "$n_calls" | awk -F, '
	/^[[:space:]]*$/ { next }
	/^\+CLCC: [0-9]+,[01],[0-9]+,1,[01](,|$)/ { next }
	{ exit 1 }
	' || rm520n_error 'call in progress or unknown CLCC; audio change deferred'
}

rm520n_read()
{
	[ -f "$QMODEM_VOIP_JOURNAL" ] || return 1
	# Enforce the complete schema, single fields, bounded values and checksum.
	awk -F= '
	BEGIN { split("schema slot firmware audio_policy media_method phase fallback_reason attempts baseline_ims baseline_voice baseline_qpcmv baseline_qaudmod baseline_usbcfg baseline_qdai baseline_qpcmv_cfg baseline_gps checksum", a, " "); for (i in a) allowed[a[i]]=1 }
	NF != 2 || !allowed[$1] || seen[$1]++ || length($2)>128 || $2 ~ /[^A-Za-z0-9_.,x-]/ { exit 1 }
	END { for (k in allowed) if (seen[k]!=1) exit 1 }
	' "$QMODEM_VOIP_JOURNAL" || return 1
	n_sum=$(sed '/^checksum=/d' "$QMODEM_VOIP_JOURNAL" | sha256sum | awk '{print $1}')
	[ "$n_sum" = "$(rm520n_get checksum)" ] || return 1
	[ "$(rm520n_get schema)" = 3 ] || return 1
	[ "$(rm520n_get slot)" = "$n_slot" ] && [ "$(rm520n_get firmware)" = "$n_firmware" ] || return 1
	n_policy=$(rm520n_get audio_policy)
	n_method=$(rm520n_get media_method)
	n_phase=$(rm520n_get phase)
	n_reason=$(rm520n_get fallback_reason)
	n_attempts=$(rm520n_get attempts)
	case $n_policy in auto|uac|serial_pcm) ;; *) return 1 ;; esac
	case $n_method in uac|serial_pcm) ;; *) return 1 ;; esac
	case $n_phase in captured|configuring|reboot|enabled|failed|restoring|restored) ;; *) return 1 ;; esac
	case $n_attempts in 0|1|2|3) ;; *) return 1 ;; esac
	n_ims=$(rm520n_get baseline_ims); n_voice=$(rm520n_get baseline_voice)
	n_qpcmv=$(rm520n_get baseline_qpcmv); n_qaudmod=$(rm520n_get baseline_qaudmod)
	n_usbcfg=$(rm520n_get baseline_usbcfg); n_qdai=$(rm520n_get baseline_qdai)
	n_pcmcfg=$(rm520n_get baseline_qpcmv_cfg); n_gps=$(rm520n_get baseline_gps)
	case $n_ims in 0|1) ;; *) return 1 ;; esac
	case $n_voice in 0|1|2) ;; *) return 1 ;; esac
	case $n_qpcmv in 0|0,0|0,2|1,0|1,2) ;; *) return 1 ;; esac
	case $n_qaudmod in 0|1|2|3) ;; *) return 1 ;; esac
	rm520n_usb_tuple "$n_usbcfg" 0 >/dev/null || return 1
	case $n_qdai in ''|*[!0-9x,]*) return 1 ;; esac
	case $n_pcmcfg in ''|*[!0-9,]*) return 1 ;; esac
	case $n_gps in none|usbnmea|uartnmea) ;; *) return 1 ;; esac
}

rm520n_write()
{
	n_phase=$1
	mkdir -p "$(dirname "$QMODEM_VOIP_JOURNAL")" || return 1
	umask 077
	n_tmp=$(mktemp "${QMODEM_VOIP_JOURNAL}.XXXXXX") || return 1
	{
		printf 'schema=3\nslot=%s\nfirmware=%s\naudio_policy=%s\nmedia_method=%s\nphase=%s\nfallback_reason=%s\nattempts=%s\n' \
			"$n_slot" "$n_firmware" "$n_policy" "$n_method" "$n_phase" "$n_reason" "$n_attempts"
		printf 'baseline_ims=%s\nbaseline_voice=%s\nbaseline_qpcmv=%s\nbaseline_qaudmod=%s\nbaseline_usbcfg=%s\nbaseline_qdai=%s\nbaseline_qpcmv_cfg=%s\nbaseline_gps=%s\n' \
			"$n_ims" "$n_voice" "$n_qpcmv" "$n_qaudmod" "$n_usbcfg" "$n_qdai" "$n_pcmcfg" "$n_gps"
	} > "$n_tmp" || { rm -f "$n_tmp"; return 1; }
	n_sum=$(sha256sum "$n_tmp" | awk '{print $1}') || { rm -f "$n_tmp"; return 1; }
	printf 'checksum=%s\n' "$n_sum" >> "$n_tmp" && mv "$n_tmp" "$QMODEM_VOIP_JOURNAL"
}

rm520n_usb_tuple()
{
	# Keep every bit except UAC, including the existing ADB preference.
	printf '%s\n' "$1" | awk -F, -v audio="$2" 'BEGIN { OFS="," }
	NF==9 && tolower($1)=="0x2c7c" && tolower($2)=="0x0801" {
	 for(i=3;i<=9;i++) if($i!="0" && $i!="1") exit 1;
	 $9=audio; print; ok=1
	} END {if(!ok) exit 1}'
}

rm520n_capture()
{
	n_ims=$(rm520n_value 'AT+QCFG="ims"') || return 1
	n_voice=$(rm520n_value 'AT+QCALLCFG="voice_disable"') || return 1
	n_qpcmv=$(rm520n_value 'AT+QPCMV?') || return 1
	n_qaudmod=$(rm520n_value 'AT+QAUDMOD?') || return 1
	n_usbcfg=$(rm520n_value 'AT+QCFG="usbcfg"') || return 1
	n_qdai=$(rm520n_value 'AT+QDAI?') || return 1
	n_pcmcfg=$(rm520n_value 'AT+QAUDCFG="qpcmv_cfg"') || return 1
	n_gps=$(rm520n_value 'AT+QGPSCFG="outport"' | tr -d '"') || return 1
	n_attempts=0 n_reason=none
	rm520n_write captured && rm520n_read
}

rm520n_wait_usb()
{
	# Wait for an AT endpoint after reboot, independent of whether UAC appears.
	# Missing audio is a selection failure, not an excuse for repeated reboot.
	qmodem_voip_adapter_wait_reenumeration "$n_slot" any 120
}

rm520n_set_usb()
{
	n_target=$1
	n_current=$(rm520n_value 'AT+QCFG="usbcfg"') || return 1
	[ "$n_target" != "$n_current" ] || return 0
	[ "$n_attempts" -lt 2 ] || return 1
	n_attempts=$((n_attempts+1))
	rm520n_write reboot || return 1
	rm520n_idle || return 1
	if rm520n_at "AT+QCFG=\"usbcfg\",$n_target" >/dev/null; then :; else
		n_usb_result=$?
		# This firmware checks QADBKEY authorization even when ADB was already
		# enabled. Preserve that preference; authorize over AT, never via ADB.
		if [ "$n_usb_result" = 2 ] && [ "$(printf '%s' "$n_target" | cut -d, -f8)" = 1 ]; then
			qmodem_voip_adapter_authorize_usb || return 1
			if rm520n_at "AT+QCFG=\"usbcfg\",$n_target" >/dev/null; then :; else return $?; fi
		else
			return "$n_usb_result"
		fi
	fi
	rm520n_at 'AT+CFUN=1,1' >/dev/null 2>&1 || :
	rm520n_wait_usb || return 1
	[ "$(rm520n_value 'AT+QCFG="usbcfg"')" = "$n_target" ] || return 1
}

rm520n_configure()
{
	rm520n_idle || return 1
	rm520n_write configuring || return 1
	rm520n_at 'AT+QPCMV=0' >/dev/null || return 1
	rm520n_at 'AT+QCFG="ims",1' >/dev/null || return 1
	rm520n_at 'AT+QCALLCFG="voice_disable",2' >/dev/null || return 1
	n_qaud=$(qmodem_voip_json '@.modems[@.model="RM520N-GL"].audio.qaudmod') || return 1
	case $n_qaud in 0|1|2) ;; *) return 1 ;; esac
	rm520n_at "AT+QAUDMOD=$n_qaud" >/dev/null || return 1
	if [ "$n_method" = uac ]; then
		n_audio=1 n_forward=1,2
	else
		n_audio=0 n_forward=1,0
		rm520n_at 'AT+QGPSCFG="outport","none"' >/dev/null || return 1
		n_pcm_target=$(qmodem_voip_json '@.modems[@.model="RM520N-GL"].audio.qpcmv_cfg') || return 1
		n_dai_target=$(qmodem_voip_json '@.modems[@.model="RM520N-GL"].audio.qdai') || return 1
		case $n_pcm_target:$n_dai_target in *[!0-9x,:]*|'') return 1 ;; esac
		# QDAI applies on reboot; force at most one when only QDAI changed.
		n_dai_current=$(rm520n_value 'AT+QDAI?') || return 1
		rm520n_at "AT+QDAI=$n_dai_target" >/dev/null || return 1
		rm520n_at "AT+QAUDCFG=\"qpcmv_cfg\",$n_pcm_target" >/dev/null || return 1
	fi
	n_usb_target=$(rm520n_usb_tuple "$n_usbcfg" "$n_audio") || return 1
	n_before=$(rm520n_value 'AT+QCFG="usbcfg"') || return 1
	rm520n_set_usb "$n_usb_target" || return $?
	if [ "$n_method" = serial_pcm ] && [ "$n_before" = "$n_usb_target" ] && [ "$n_dai_current" != "$n_dai_target" ]; then
		[ "$n_attempts" -lt 2 ] || return 1
		n_attempts=$((n_attempts+1)); rm520n_write reboot || return 1
		rm520n_at 'AT+CFUN=1,1' >/dev/null 2>&1 || :
		rm520n_wait_usb || return 1
	fi
	if [ "$n_method" = uac ]; then
		n_wait=15 n_found=0
		while [ "$n_wait" -gt 0 ]; do
			for n_card in "${QMODEM_VOIP_SYSFS_ROOT:-/sys/bus/usb/devices}/$n_slot/$n_slot":*/sound/card*; do
				[ ! -d "$n_card" ] || n_found=1
			done
			[ "$n_found" = 0 ] || break
			sleep 1; n_wait=$((n_wait-1))
		done
		if [ "$n_found" = 0 ]; then
			# Only a still-identifiable responsive modem may fall back.
			rm520n_identity || return 1
			return 2
		fi
	fi
	# AT may return before the modem's native voice service after USB reboot.
	# Give that service a bounded startup window; transport loss stays fatal.
	n_forward_tries=0
	while :; do
		if rm520n_at "AT+QPCMV=$n_forward" >/dev/null; then break; else n_result=$?; fi
		[ "$n_result" = 2 ] || return 1
		n_forward_tries=$((n_forward_tries+1))
		[ "$n_forward_tries" -lt 15 ] || return 2
		sleep 2
	done
	[ "$(rm520n_value 'AT+QPCMV?')" = "$n_forward" ] || return 1
	rm520n_write enabled && rm520n_verify
}

rm520n_select()
{
	if rm520n_configure; then return 0; else n_result=$?; fi
	if [ "$n_result" = 2 ] && [ "$n_policy:$n_method" = auto:uac ]; then
		n_method=serial_pcm n_reason=uac_unsupported
		rm520n_configure && return 0
	fi
	rm520n_restore || :
	rm520n_write failed
	return 1
}

rm520n_restore()
{
	rm520n_idle || return 1
	if [ "$n_attempts" = 3 ]; then
		# A completed rollback may be acknowledged, never replayed repeatedly.
		[ "$(rm520n_value 'AT+QCFG="usbcfg"')" = "$n_usbcfg" ] &&
		[ "$(rm520n_value 'AT+QPCMV?')" = "$n_qpcmv" ] &&
		[ "$(rm520n_value 'AT+QDAI?')" = "$n_qdai" ] &&
		[ "$(rm520n_value 'AT+QAUDMOD?')" = "$n_qaudmod" ] &&
		[ "$(rm520n_value 'AT+QCFG="ims"')" = "$n_ims" ] &&
		[ "$(rm520n_value 'AT+QCALLCFG="voice_disable"')" = "$n_voice" ]
		return $?
	fi
	# A durable failed/restoring phase prevents a retry/restart loop.
	rm520n_write restoring || return 1
	rm520n_at 'AT+QPCMV=0' >/dev/null || return 1
	rm520n_at "AT+QCFG=\"ims\",$n_ims" >/dev/null || return 1
	rm520n_at "AT+QCALLCFG=\"voice_disable\",$n_voice" >/dev/null || return 1
	rm520n_at "AT+QAUDMOD=$n_qaudmod" >/dev/null || return 1
	rm520n_at "AT+QGPSCFG=\"outport\",\"$n_gps\"" >/dev/null || return 1
	rm520n_at "AT+QDAI=$n_qdai" >/dev/null || return 1
	rm520n_at "AT+QAUDCFG=\"qpcmv_cfg\",$n_pcmcfg" >/dev/null || return 1
	# One final restoration reboot is allowed, and persisted before any reset.
	[ "$n_attempts" -lt 3 ] || return 1
	n_attempts=3; rm520n_write restoring || return 1
	rm520n_at "AT+QCFG=\"usbcfg\",$n_usbcfg" >/dev/null || return 1
	rm520n_at 'AT+CFUN=1,1' >/dev/null 2>&1 || :
	rm520n_wait_usb || return 1
	rm520n_at "AT+QPCMV=$n_qpcmv" >/dev/null || return 1
	rm520n_write restored
}

rm520n_fallback()
{
	[ "$n_phase" = enabled ] && [ "$n_policy" = auto ] && [ "$n_method" = uac ] || return 1
	rm520n_idle || return 1
	n_method=serial_pcm n_reason=uac_unavailable
	if rm520n_configure; then return 0; fi
	rm520n_restore || :
	rm520n_write failed
	return 1
}

rm520n_dispatch()
{
	n_action=$1
	rm520n_identity || return 1
	[ "$n_action" != probe ] || { printf 'SUPPORTED slot=%s\n' "$n_slot"; return 0; }
	if [ -f "$QMODEM_VOIP_JOURNAL" ]; then
		# Cross-firmware and legacy journals are never replayed. Only enable may
		# quarantine them and capture the actual new firmware's configuration.
		if ! rm520n_read; then
			[ "$n_action" = enable ] && rm520n_idle || return 1
			[ "$(rm520n_get schema)" = 2 ] || {
				[ "$(rm520n_get firmware)" != "$n_firmware" ] || return 1
			}
			mv "$QMODEM_VOIP_JOURNAL" "${QMODEM_VOIP_JOURNAL}.previous" || return 1
		fi
	fi
	case $n_action in
		enable|reprobe|disable) ;;
		*) [ -f "$QMODEM_VOIP_JOURNAL" ] || return 1 ;;
	esac
	case $n_action in
	enable)
		if [ -f "$QMODEM_VOIP_JOURNAL" ]; then
			[ "$n_phase" = enabled ] || return 1
			n_requested=$(uci -q get qmodem_voip.main.audio_policy 2>/dev/null) || n_requested=auto
			case $n_requested in auto|uac|serial_pcm) ;; *) return 1 ;; esac
			if [ "$n_requested" != "$n_policy" ]; then
				rm520n_idle || return 1
				n_policy=$n_requested n_attempts=0 n_reason=none
				n_method=uac; [ "$n_policy" != serial_pcm ] || n_method=serial_pcm
				rm520n_select
				return $?
			fi
			rm520n_verify || { rm520n_idle && rm520n_select; }
			return $?
		fi
		n_policy=$(uci -q get qmodem_voip.main.audio_policy 2>/dev/null) || n_policy=auto
		case $n_policy in auto|uac) n_method=uac ;; serial_pcm) n_method=serial_pcm ;; *) return 1 ;; esac
		rm520n_idle && qmodem_voip_adapter_enable_ubus && rm520n_capture || return 1
		rm520n_select ;;
	reprobe)
		rm520n_idle || return 1
		[ -f "$QMODEM_VOIP_JOURNAL" ] || return 0
		n_requested=$(uci -q get qmodem_voip.main.audio_policy 2>/dev/null) || n_requested=auto
		case $n_requested in auto|uac|serial_pcm) n_policy=$n_requested ;; *) return 1 ;; esac
		# Explicit user request resets the durable selection budget.
		n_attempts=0 n_reason=none
		n_method=uac; [ "$n_policy" != serial_pcm ] || n_method=serial_pcm
		rm520n_select ;;
	fallback) rm520n_fallback ;;
	fail)
		# Host audio open/I/O failure is not proof that UAC is unsupported.
		# Retain the baseline and budget; no USB reset on a busy sound device.
		n_reason=media_not_ready
		rm520n_write failed ;;
	verify) rm520n_verify ;;
	arm)
		[ "$n_phase" = enabled ] || return 1
		# Never reconfigure an active call; QPCMV must already match.
		[ "$(rm520n_value 'AT+QPCMV?')" = "$(rm520n_forward)" ] ;;
	recover)
		[ "$n_phase" = enabled ] || return 1
		rm520n_verify || { rm520n_idle && rm520n_select; } ;;
	disable)
		[ -f "$QMODEM_VOIP_JOURNAL" ] || return 0
		rm520n_restore && rm -f "$QMODEM_VOIP_JOURNAL" ;;
	*) return 64 ;;
	esac
}

rm520n_forward() { if [ "$n_method" = uac ]; then echo 1,2; else echo 1,0; fi; }
rm520n_verify()
{
	[ "$n_phase" = enabled ] || return 1
	[ "$(rm520n_value 'AT+QCFG="ims"')" = 1 ] &&
	[ "$(rm520n_value 'AT+QCALLCFG="voice_disable"')" = 2 ] &&
	[ "$(rm520n_value 'AT+QAUDMOD?')" = "$(qmodem_voip_json '@.modems[@.model="RM520N-GL"].audio.qaudmod')" ] &&
	[ "$(rm520n_value 'AT+QPCMV?')" = "$(rm520n_forward)" ] || return 1
	n_audio=0; [ "$n_method" != uac ] || n_audio=1
	[ "$(rm520n_value 'AT+QCFG="usbcfg"')" = "$(rm520n_usb_tuple "$n_usbcfg" "$n_audio")" ] || return 1
	if [ "$n_method" = serial_pcm ]; then
		[ "$(rm520n_value 'AT+QDAI?')" = "$(qmodem_voip_json '@.modems[@.model="RM520N-GL"].audio.qdai')" ] &&
		[ "$(rm520n_value 'AT+QAUDCFG="qpcmv_cfg"')" = "$(qmodem_voip_json '@.modems[@.model="RM520N-GL"].audio.qpcmv_cfg')" ] || return 1
	fi
}
