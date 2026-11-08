#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export QMODEM_SIP_RUN_DIR="$tmp/run" QMODEM_SIP_VALIDATE=/bin/true
. "$root/files/etc/init.d/qmodem_sipd"
config_get()
{
 case "$2.$3" in
 a.group|b.group) value=first ;;
 c.group) value=second ;;
 a.direction|b.direction|c.direction) value=outbound ;;
 first.modem_id) value=m1 ;;
 second.modem_id) value=m2 ;;
 *.sms_enabled) value=${test_sms:-0} ;;
 *.voip_enabled) value=${test_voice:-0} ;;
 *.interface) value=wan ;;
 a.listen_port) value=5061 ;;
 b.listen_port) value=5062 ;;
 c.listen_port) value=5063 ;;
 a.rtp_start) value=40000 ;;
 b.rtp_start) value=40004 ;;
 c.rtp_start) value=40008 ;;
 *.server) value=sip.example.com ;;
 *.port) value=5061 ;;
 *.username) value=example ;;
 *.password) value=abcdefghijklmnop ;;
 *.realm) value=gateway ;;
 *.register_interval) value=300 ;;
 *) value=${4:-} ;;
 esac
 eval "$1=\$value"
}
uci() { [ "$2" = get ] && printf '%s\n' modem-device; }
interface_address() { printf '%s\n' 192.0.2.1; }
logger() { :; }
procd_open_instance() { printf '%s\n' "$1" >>"$tmp/instances"; }
procd_close_instance() { :; }
procd_set_param() { printf '%s\n' "$*" >>"$tmp/args"; }
for matrix in '0 0 0' '1 0 1' '0 1 1' '1 1 1'; do
 set -- $matrix
 test_sms=$1 test_voice=$2 expected=$3
 started='' ports='' rtps=''
 : >"$tmp/instances"; : >"$tmp/args"
 start_direction a
 [ "$(wc -l <"$tmp/instances")" -eq "$expected" ]
 if [ "$expected" = 1 ]; then
  grep -q 'qmodem_voip_sip_consumer' "$tmp/args"
  if grep -q 'qmodem_voip_sip_wait' "$tmp/args"; then exit 1; fi
  grep -q -- '--listen-address 192.0.2.1' "$tmp/args"
 fi
done
started='' ports='' rtps=''
: >"$tmp/instances"; : >"$tmp/args"
test_sms=1 test_voice=1
start_direction a
start_direction b  # duplicate group/direction must not become a worker
start_direction c
[ "$(wc -l <"$tmp/instances")" -eq 2 ]
grep -q 'first-outbound' "$tmp/instances"
grep -q 'second-outbound' "$tmp/instances"
[ -f "$tmp/run/first-outbound.conf" ] && [ -f "$tmp/run/second-outbound.conf" ]
grep -q -- '--modem-id m1' "$tmp/args"
grep -q -- '--modem-id m2' "$tmp/args"
grep -q -- '--rtp-start 40008' "$tmp/args"
printf '%s\n' 'Multi-group service activation and isolation passed'
