#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
. "$root/files/usr/lib/qmodem_voip/at_daemon_adapter.sh"
QMODEM_VOIP_SYSFS_ROOT=$tmp/sys
mkdir -p "$QMODEM_VOIP_SYSFS_ROOT"
# Simulate a modem disappearing, then returning under a different tty name.
qmodem_voip_adapter_endpoint() { [ -d "$QMODEM_VOIP_SYSFS_ROOT/2-1" ] && echo /dev/ttyUSB7; }
qmodem_voip_adapter_pcm_endpoint() { return 1; }
json_init() { :; }
json_add_string() { [ "$1" = at_port ]; refreshed_port=$2; }
json_dump() { printf '{"at_port":"%s"}' "$refreshed_port"; }
ubus() {
 [ "$*" = '-t 5 call at-daemon close {"at_port":"/dev/ttyUSB7"}' ] || exit 1
 echo "$*" >> "$tmp/closed"
 [ "$reject_close" = 0 ]
}
sleep() { mkdir -p "$QMODEM_VOIP_SYSFS_ROOT/2-1"; }
reject_close=0
qmodem_voip_adapter_wait_reenumeration 2-1 any 3
[ "$(wc -l < "$tmp/closed")" -eq 1 ]
# A failed close must not permit configuration through a stale descriptor.
rm -rf "$QMODEM_VOIP_SYSFS_ROOT/2-1"
reject_close=1
if qmodem_voip_adapter_wait_reenumeration 2-1 any 3; then exit 1; fi
echo 'PASS: USB reenumeration refreshes only the rediscovered AT endpoint'
