#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
QMODEM_VOIP_JOURNAL=$tmp/journal
QMODEM_VOIP_ADAPTER=$tmp/no-adapter
QMODEM_VOIP_SYSFS_ROOT=$tmp/sys
export QMODEM_VOIP_JOURNAL QMODEM_VOIP_SYSFS_ROOT
. "$root/files/usr/lib/qmodem_voip/modem_safety.sh"
. "$root/files/usr/lib/qmodem_voip/rm520n_native.sh"
qmodem_voip_adapter_usb_slot() { echo 2-1; }
qmodem_voip_adapter_usb_id() { echo 2c7c:0801; }
qmodem_voip_adapter_enable_ubus() { :; }
qmodem_voip_adapter_wait_reenumeration() { echo reboot >> "$tmp/events"; }
sleep() { :; }
qmodem_voip_adapter_authorize_usb() { authorized=1; echo authorize >> "$tmp/events"; }
uci() { cat "$tmp/policy"; }
qmodem_voip_json()
{
 case $1 in
 *firmware) echo RM520NGLAAR03A03M4G_01.201.01.201 ;;
 *qaudmod) echo 2 ;;
 *qpcmv_cfg) echo 8000,20 ;;
 *qdai) echo x,0,0,4,0,0,1,1 ;;
 *) return 1 ;;
 esac
}
qmodem_voip_adapter_at()
{
 printf '%s\n' "$1" >> "$tmp/at"
 case $1 in
 'AT+CGMM') echo RM520N-GL ;;
 'AT+QGMR') cat "$tmp/firmware" ;;
 'AT+CLCC') cat "$tmp/calls" ;;
 'AT+QCFG="ims"') echo 1 ;;
 'AT+QCALLCFG="voice_disable"') echo 2 ;;
 'AT+QAUDMOD?') echo 2 ;;
 'AT+QPCMV?') cat "$tmp/qpcmv" ;;
 'AT+QDAI?') cat "$tmp/qdai" ;;
 'AT+QAUDCFG="qpcmv_cfg"') echo 8000,20 ;;
 'AT+QGPSCFG="outport"') echo none ;;
 'AT+QCFG="usbcfg"') cat "$tmp/usbcfg" ;;
 AT+QCFG=\"usbcfg\",*)
   case ${reject_usb:-0}:${authorized:-0} in 1:0|2:*) return 2 ;; 3:*) return 1 ;; esac
   printf '%s\n' "${1#AT+QCFG=\"usbcfg\",}" > "$tmp/usbcfg" ;;
 AT+QDAI=*) printf '%s\n' "${1#AT+QDAI=}" > "$tmp/qdai" ;;
 AT+QPCMV=1,2)
   case ${reject_uac:-0} in 1) return 2 ;; 2) return 1 ;; esac
   echo 1,2 > "$tmp/qpcmv" ;;
 AT+QPCMV=*) printf '%s\n' "${1#AT+QPCMV=}" > "$tmp/qpcmv" ;;
 *) : ;;
 esac
}
reset_fixture()
{
 rm -f "$QMODEM_VOIP_JOURNAL" "$QMODEM_VOIP_JOURNAL.previous"
 rm -rf "$tmp/sys"
 mkdir -p "$tmp/sys/2-1/2-1:1.6/sound/card3"
 echo auto > "$tmp/policy"
 echo RM520NGLAAR03A03M4G_01.201.01.201 > "$tmp/firmware"
 echo 0,0 > "$tmp/qpcmv"
 echo x,0,0,4,0,0,1,1 > "$tmp/qdai"
 echo 0x2c7c,0x0801,1,1,1,1,1,1,0 > "$tmp/usbcfg"
 : > "$tmp/calls"; : > "$tmp/at"; : > "$tmp/events"
 reject_uac=0 reject_usb=0 authorized=0
}
assert_no_writes()
{
 if grep -E '^AT\+(CFUN=|QPCMV=|QCFG=.*,[01]$|QDAI=|QAUDMOD=)' "$tmp/at"; then
   echo 'unexpected modem mutation' >&2; exit 1
 fi
}
reset_fixture
echo '+CLCC: 1,1,0,1,0,"",128' > "$tmp/calls"
rm520n_dispatch enable
[ "$(rm520n_get media_method)" = uac ]
[ "$(rm520n_get phase)" = enabled ]
[ "$(cat "$tmp/qpcmv")" = 1,2 ]
# UAC absent is allowed to fall back once, while preserving ADB and data bits.
rm520n_dispatch fallback
[ "$(rm520n_get media_method)" = serial_pcm ]
[ "$(rm520n_get fallback_reason)" = uac_unavailable ]
[ "$(cat "$tmp/usbcfg")" = 0x2c7c,0x0801,1,1,1,1,1,1,0 ]
: > "$tmp/at"
rm520n_dispatch enable
assert_no_writes
# Readback must detect native PCM configuration drift.
echo x,0,0,0,0,0,1,1 > "$tmp/qdai"
if rm520n_dispatch verify; then exit 1; fi
echo x,0,0,4,0,0,1,1 > "$tmp/qdai"
if rm520n_dispatch fallback; then exit 1; fi
# A call blocks reprobe, fallback and restoring configuration.
echo '+CLCC: 1,1,0,0,0' > "$tmp/calls"
: > "$tmp/at"
if rm520n_dispatch reprobe; then exit 1; fi
assert_no_writes
reset_fixture
rm -rf "$tmp/sys"
rm520n_dispatch enable
[ "$(rm520n_get media_method)" = serial_pcm ]
[ "$(rm520n_get fallback_reason)" = uac_unsupported ]
reset_fixture
reject_uac=1
rm520n_dispatch enable
[ "$(rm520n_get media_method)" = serial_pcm ]
# An existing ADB bit can require fresh AT authorization after a reflash.
reset_fixture
reject_usb=1
rm520n_dispatch enable
[ "$(rm520n_get media_method)" = uac ]
[ "$(grep -c authorize "$tmp/events")" = 1 ]
# A genuine USB rejection survives authorization and selects native PCM.
reset_fixture
reject_usb=2
rm520n_dispatch enable
[ "$(rm520n_get media_method)" = serial_pcm ]
[ "$(rm520n_get fallback_reason)" = uac_unsupported ]
# A USB transport timeout is never classified as unsupported UAC.
reset_fixture
reject_usb=3
if rm520n_dispatch enable; then exit 1; fi
[ "$(rm520n_get phase)" = failed ]
[ "$(rm520n_get media_method)" = uac ]
# Timeout is not equivalent to the modem rejecting UAC.
reset_fixture
reject_uac=2
if rm520n_dispatch enable; then exit 1; fi
[ "$(rm520n_get media_method)" = uac ]
[ "$(rm520n_get phase)" = failed ]
: > "$tmp/at"
if rm520n_dispatch enable; then exit 1; fi
assert_no_writes
reset_fixture
echo uac > "$tmp/policy"
rm -rf "$tmp/sys"
if rm520n_dispatch enable; then exit 1; fi
[ "$(rm520n_get media_method)" = uac ]
[ "$(rm520n_get attempts)" = 3 ]
: > "$tmp/at"
if rm520n_dispatch enable; then exit 1; fi
assert_no_writes
# Bad firmware and corrupted journals never replay settings.
reset_fixture
echo RM520NGLAAR03A03M4G_01.200 > "$tmp/firmware"
if rm520n_dispatch enable; then exit 1; fi
assert_no_writes
reset_fixture
rm520n_dispatch enable
printf 'media_method=serial_pcm\n' >> "$QMODEM_VOIP_JOURNAL"
: > "$tmp/at"
if rm520n_dispatch enable; then exit 1; fi
assert_no_writes
# Host audio failure records a terminal state without a modem reset. A daemon
# restart cannot reset the attempt budget; explicit reprobe is required.
reset_fixture
rm520n_dispatch enable
budget=$(rm520n_get attempts)
: > "$tmp/at"
rm520n_dispatch fail
[ "$(rm520n_get phase)" = failed ]
[ "$(rm520n_get fallback_reason)" = media_not_ready ]
[ "$(rm520n_get attempts)" = "$budget" ]
if rm520n_dispatch enable; then exit 1; fi
assert_no_writes
rm520n_dispatch reprobe
[ "$(rm520n_get phase)" = enabled ]
# Reprobe uses the newly selected policy, not the journal's old one.
echo serial_pcm > "$tmp/policy"
rm520n_dispatch reprobe
[ "$(rm520n_get audio_policy)" = serial_pcm ]
[ "$(rm520n_get media_method)" = serial_pcm ]
# Firmware changes quarantine the old transaction, not its old USB/audio values.
reset_fixture
printf 'schema=2\nslot=2-1\nmedia_method=serial_pcm\n' > "$QMODEM_VOIP_JOURNAL"
rm520n_dispatch enable
[ -f "$QMODEM_VOIP_JOURNAL.previous" ]
[ "$(rm520n_get schema)" = 3 ]
echo 'PASS: RM520 native UAC selection, bounded fallback, call guard, firmware and journal safety'
