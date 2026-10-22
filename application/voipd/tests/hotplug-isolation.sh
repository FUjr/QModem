#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/state/first" "$tmp/state/second"
printf 'slot=2-1\nphase=enabled\n' > "$tmp/state/first/modem-safety.journal"
printf 'slot=2-2\nphase=enabled\n' > "$tmp/state/second/modem-safety.journal"
cat > "$tmp/recover" <<EOF2
#!/bin/sh
printf '%s\\n' "\$QMODEM_VOIP_MODEM_ID" >> "$tmp/recovered"
EOF2
chmod +x "$tmp/recover"
sed -e "s|/var/lib/qmodem_voip|$tmp/state|g" -e "s|/usr/sbin/qmodem_voip_modem_safety|$tmp/recover|g" \
 "$root/files/etc/hotplug.d/usb/21-qmodem-voip-audio" > "$tmp/hotplug"
uci() {
 case "$*" in
 '-q show qmodem_voip') printf 'qmodem_voip.first=modem\nqmodem_voip.second=modem\n' ;;
 '-q get qmodem_voip.first.modem_id') printf m1 ;;
 '-q get qmodem_voip.second.modem_id') printf m2 ;;
 *) return 1 ;;
 esac
}
logger() { :; }
# The sourced hotplug script exits its own subshell; wait for its background job.
( ACTION=bind DEVPATH=/sys/devices/usb2/2-1/2-1:1.0; . "$tmp/hotplug" )
# A bounded poll permits asynchronous recovery to finish.
for attempt in 1 2 3 4 5; do [ -f "$tmp/recovered" ] && break; sleep 0.1; done
[ "$(cat "$tmp/recovered")" = m1 ]
printf '%s\n' 'PASS: USB re-enumeration recovers only the selected modem journal'
