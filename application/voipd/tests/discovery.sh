#!/bin/sh
set -eu

APPLICATION_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
ADAPTER=$APPLICATION_ROOT/voipd/files/usr/lib/qmodem_voip/at_daemon_adapter.sh
RULES=$APPLICATION_ROOT/qmodem/files/usr/share/qmodem/modem_port_rule.json
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/sys/2-1.1" "$TMP/dev"
: >"$TMP/dev/ttyUSB1"
: >"$TMP/dev/ttyUSB3"
printf '%s\n' 0 >"$TMP/use_ubus"
: >"$TMP/uci-log"

cat >"$TMP/bin/uci" <<'EOF'
#!/bin/sh
[ "$1" = -q ] && shift
case "$1:$2" in
show:qmodem)
	printf '%s\n' 'qmodem.2_1_1=modem-device'
	[ "${UCI_DUPLICATE:-0}" = 0 ] || printf '%s\n' 'qmodem.3_1_1=modem-device'
	;;
get:qmodem.2_1_1.name) printf '%s\n' rm520n-gl ;;
get:qmodem.3_1_1.name) printf '%s\n' rm520n-gl ;;
get:qmodem.2_1_1.data_interface) printf '%s\n' usb ;;
get:qmodem.3_1_1.data_interface) printf '%s\n' usb ;;
get:qmodem.2_1_1.path) printf '%s\n' /sys/bus/usb/devices/2-1.1/ ;;
get:qmodem.3_1_1.path) printf '%s\n' /sys/bus/usb/devices/3-1.1/ ;;
get:qmodem.2_1_1.at_port) printf '%s\n' /dev/ttyUSB3 ;;
get:qmodem.3_1_1.at_port) printf '%s\n' /dev/ttyUSB7 ;;
get:qmodem.2_1_1.voice_pcm_port) printf '%s\n' /dev/ttyUSB1 ;;
get:qmodem.3_1_1.voice_pcm_port) printf '%s\n' /dev/ttyUSB5 ;;
get:qmodem.2_1_1.use_ubus) cat "$UCI_USE_UBUS_STATE" ;;
set:qmodem.2_1_1.use_ubus=1)
	printf '%s\n' 1 >"$UCI_USE_UBUS_STATE"
	printf '%s\n' 'set qmodem.2_1_1.use_ubus=1' >>"$UCI_TEST_LOG"
	;;
commit:qmodem) printf '%s\n' 'commit qmodem' >>"$UCI_TEST_LOG" ;;
*) exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/uci"

PATH=$TMP/bin:$PATH
QMODEM_VOIP_SYSFS_ROOT=$TMP/sys
QMODEM_VOIP_DEVICE_ROOT=$TMP/dev
UCI_USE_UBUS_STATE=$TMP/use_ubus
UCI_TEST_LOG=$TMP/uci-log
export PATH QMODEM_VOIP_SYSFS_ROOT QMODEM_VOIP_DEVICE_ROOT UCI_USE_UBUS_STATE UCI_TEST_LOG
set -- recover
. "$ADAPTER"
set --
qmodem_voip_adapter_device_exists() { [ -e "$1" ]; }

[ "$(qmodem_voip_adapter_usb_slot)" = 2-1.1 ]
[ "$(qmodem_voip_adapter_endpoint)" = /dev/ttyUSB3 ]
[ "$(qmodem_voip_adapter_pcm_endpoint)" = /dev/ttyUSB1 ]
[ "$(qmodem_voip_adapter_rediscover 2-1.1 | tr '\n' ' ')" = '/dev/ttyUSB3 /dev/ttyUSB1 ' ]
qmodem_voip_adapter_enable_ubus
[ "$(cat "$TMP/use_ubus")" = 1 ]
[ "$(cat "$TMP/uci-log")" = "set qmodem.2_1_1.use_ubus=1
commit qmodem" ]
qmodem_voip_adapter_enable_ubus
[ "$(wc -l <"$TMP/uci-log")" -eq 2 ]
UCI_DUPLICATE=1
export UCI_DUPLICATE
if qmodem_voip_adapter_section >/dev/null 2>&1; then
	printf '%s\n' 'duplicate supported modems were not rejected' >&2
	exit 1
fi

QMODEM_VOIP_MODEM_ID=2_1_1
export QMODEM_VOIP_MODEM_ID
[ "$(qmodem_voip_adapter_section)" = 2_1_1 ]
[ "$(qmodem_voip_adapter_endpoint)" = /dev/ttyUSB3 ]
QMODEM_VOIP_MODEM_ID=3_1_1
[ "$(qmodem_voip_adapter_section)" = 3_1_1 ]
QMODEM_VOIP_MODEM_ID=not_present
if qmodem_voip_adapter_section; then exit 1; fi
unset QMODEM_VOIP_MODEM_ID

qmodem_voip_adapter_endpoint() { printf '%s\n' /dev/ttyUSB3; }
qmodem_voip_adapter_port_open() { return 0; }
json_init() { :; }
json_add_string() { :; }
json_dump() { printf '%s\n' '{}'; }
ubus() { printf '%s\n' '{}'; }
sleep() { :; }
jsonfilter()
{
	case $2 in
		'@.status') printf '%s\n' success ;;
		'@.end_flag_matched') printf '%s\n' "${TEST_END_FLAG:-OK}" ;;
		'@.response') printf '+QPCMV: 1,0\n%s\n' "${TEST_END_FLAG:-OK}" ;;
		*) return 1 ;;
	esac
}
[ "$(qmodem_voip_adapter_at 'AT+QPCMV?')" = 1,0 ]
TEST_END_FLAG=ERROR
export TEST_END_FLAG
if qmodem_voip_adapter_at 'AT+QPCMV?' >/dev/null 2>&1; then
	printf '%s\n' 'AT adapter accepted an ERROR terminal response' >&2
	exit 1
fi
unset TEST_END_FLAG

jq -e '.modem_port_rule.usb["2c7c:0801"] |
    .include == ["1.2", "1.3", "1.4"] and
    .voice_pcm_interface == "1.1"' "$RULES" >/dev/null

printf '%s\n' 'VoIP modem discovery contract passed'
