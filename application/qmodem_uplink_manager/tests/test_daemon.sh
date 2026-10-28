#!/bin/sh
# Invoked by test_routes.sh inside its disposable network namespace.
set -eu
[ "${UPLINK_NETNS_TEST:-0}" = 1 ] || exit 2
pkg=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
workspace=$(CDPATH= cd -- "$pkg/../../../.." && pwd)
functions=${TEST_FUNCTIONS:-$workspace/../../immortalwrt/package/base-files/files/lib/functions.sh}
fixture=$(mktemp -d)
dnsdir="/tmp/dnsmasq.uplinktest$$.d"
watcher=''
cleanup() {
    [ -z "$watcher" ] || { kill "$watcher" 2>/dev/null || :; wait "$watcher" 2>/dev/null || :; }
    rm -rf "$fixture" "$dnsdir"
}
trap cleanup EXIT INT TERM
mkdir -p "$fixture/bin" "$fixture/config" "$fixture/delta"
export TEST_CONFIG="$fixture/config" TEST_DELTA="$fixture/delta"
cat > "$fixture/bin/uci" <<'SCRIPT'
#!/bin/sh
exec "$TEST_UCI" -c "$TEST_CONFIG" -t "$TEST_DELTA" "$@"
SCRIPT
cat > "$fixture/bin/ubus" <<'SCRIPT'
#!/bin/sh
case "$2" in network.interface.cell0) dev=cell0; dns=223.5.5.5;; network.interface.cell1) dev=cell1; dns=119.29.29.29;; *) exit 1;; esac
printf '{"up":true,"l3_device":"%s","ipv4-address":[{"address":"10.0.0.2"}],"route":[{"target":"0.0.0.0","mask":0,"nexthop":"10.0.0.1"}],"dns-server":["%s"]}\n' "$dev" "$dns"
SCRIPT
chmod +x "$fixture/bin/uci" "$fixture/bin/ubus"
export PATH="$fixture/bin:$PATH"
{ printf '. "%s"\n' "$functions"; cat <<'SCRIPT'
NO_EXPORT=''
config_load() {
    CONFIG_SECTIONS='' CONFIG_NUM_SECTIONS=0 CONFIG_SECTION=''
    eval "$(uci -S -n export "$1")"
}
SCRIPT
} > "$fixture/functions"
cat > "$fixture/config/qmodem_uplink" <<'CFG'
config manager 'main'
 option enabled '1'
 option interval '1'
 option timeout '1'
 option fail_threshold '1'
 option recover_threshold '1'
 option stable_seconds '0'
 list targets '223.5.5.5'
config member 'primary'
 option kind 'wired'
 option target 'cell0'
 option priority '10'
config member 'backup'
 option kind 'wired'
 option target 'cell1'
 option priority '20'
CFG
printf "config dnsmasq 'test'\n option confdir '%s'\n" "$dnsdir" > "$fixture/config/dhcp"
printf "config defaults 'defaults'\n option flow_offloading '1'\n option flow_offloading_hw '1'\n option fullcone '1'\n" > "$fixture/config/firewall"
: > "$fixture/config/network"
export QMODEM_UPLINK_BALANCE="$pkg/root/usr/share/qmodem-uplink/balance.sh" QMODEM_UPLINK_SETTINGS="$pkg/root/usr/share/qmodem-uplink/settings.sh" QMODEM_UPLINK_STATE="$fixture/state" QMODEM_UPLINK_CONFIG_LOCK="$fixture/config.lock" QMODEM_UPLINK_FIREWALL_SERVICE=/bin/true
export QMODEM_UPLINK_FUNCTIONS="$fixture/functions" QMODEM_UPLINK_CORE="$pkg/root/usr/share/qmodem-uplink/core.sh" QMODEM_UPLINK_RUN="$fixture/run" QMODEM_UPLINK_DNS_SERVICE=/bin/true
# Start with strict RPF to cover cold-start/all-dead probe recovery.
echo 1 > /proc/sys/net/ipv4/conf/all/rp_filter
echo 1 > /proc/sys/net/ipv4/conf/cell0/rp_filter
echo 1 > /proc/sys/net/ipv4/conf/cell1/rp_filter
sh "$pkg/root/usr/libexec/qmodem-uplink-watch" > "$fixture/log" 2>&1 & watcher=$!
await_active() {
    n=0
    while ! jq -e --arg want "$1" '(.active // "none")==$want' "$fixture/run/status.json" >/dev/null 2>&1; do
        n=$((n+1))
        [ "$n" -lt 150 ] || { cat "$fixture/log"; cat "$fixture/run/status.json"; ip -4 rule; ip -4 route show table all; ping -4 -n -c 1 -W 1 -I cell0 223.5.5.5 || :; return 1; }
        sleep 0.1
    done
}
await_active wired:cell0
# Crash during the idle period: no orphaned sleep may retain the daemon lock.
# Restart must recover the same leases and retain live policy/member IDs.
kill -KILL "$watcher"; wait "$watcher" 2>/dev/null || :
sh "$pkg/root/usr/libexec/qmodem-uplink-watch" >> "$fixture/log" 2>&1 & watcher=$!
n=0
while [ "$(cat "$fixture/run/pid" 2>/dev/null)" != "$watcher" ]; do
    n=$((n+1)); [ "$n" -lt 100 ] || exit 1; sleep 0.1
done
# Live reload must retain member IDs and reject invalid policies atomically.
ids=$(cat "$fixture/state/ids.json")
uci set qmodem_uplink.primary.weight=3
uci set qmodem_uplink.main.mode=balance
uci commit qmodem_uplink
kill -USR1 "$watcher"
n=0
while ! jq -e '.mode=="balance" and .config_generation==.applied_generation and any(.members[]; .weight==3)' "$fixture/run/status.json" >/dev/null; do
    n=$((n+1)); [ "$n" -lt 150 ] || exit 1; sleep 0.1
done
[ "$(cat "$fixture/state/ids.json")" = "$ids" ]
oldpolicy=$(nft list table ip qmodem_uplink)
uci set qmodem_uplink.primary.weight=0
uci set qmodem_uplink.main.interval=0
uci commit qmodem_uplink
kill -USR1 "$watcher"
n=0
while ! jq -e '.reason=="invalid_config"' "$fixture/run/status.json" >/dev/null; do
    n=$((n+1)); [ "$n" -lt 150 ] || exit 1; sleep 0.1
done
[ "$(nft list table ip qmodem_uplink)" = "$oldpolicy" ]
sleep 0.2
! grep -q 'sleep:.*invalid' "$fixture/log"
uci set qmodem_uplink.main.interval=1
uci set qmodem_uplink.primary.weight=1
uci set qmodem_uplink.main.mode=failover
uci commit qmodem_uplink
kill -USR1 "$watcher"
await_active wired:cell0
grep -q 'server=223.5.5.5' "$dnsdir/qmodem-uplink.conf"
nsenter -t "$PEER0" -n ip addr del 223.5.5.5/32 dev lo
await_active wired:cell1
ip route get 223.5.5.5 | grep -q 'dev cell1'
grep -q 'server=119.29.29.29' "$dnsdir/qmodem-uplink.conf"
nsenter -t "$PEER0" -n ip addr add 223.5.5.5/32 dev lo
await_active wired:cell0
nsenter -t "$PEER0" -n ip addr del 223.5.5.5/32 dev lo
nsenter -t "$PEER1" -n ip addr del 223.5.5.5/32 dev lo
await_active none
! ip route get 223.5.5.5 2>/dev/null
! grep -q '^server=' "$dnsdir/qmodem-uplink.conf"
[ "$(uci -q get firewall.defaults.fullcone)" = 0 ]
kill "$watcher"; wait "$watcher"; watcher=''
[ ! -f "$dnsdir/qmodem-uplink.conf" ]
[ "$(uci -q get firewall.defaults.fullcone)" = 1 ]
[ "$(uci -q get firewall.defaults.flow_offloading)" = 1 ]
[ "$(cat /proc/sys/net/ipv4/conf/all/rp_filter)" = 1 ]
[ "$(cat /proc/sys/net/ipv4/conf/cell0/rp_filter)" = 1 ]
[ "$(cat /proc/sys/net/ipv4/conf/cell1/rp_filter)" = 1 ]
[ "$(ip -j -4 route show table main)" = "$TEST_BASELINE" ]
ip rule show | grep -q '100:.*lookup 123'
nsenter -t "$PEER0" -n ip addr add 223.5.5.5/32 dev lo
nsenter -t "$PEER1" -n ip addr add 223.5.5.5/32 dev lo
echo 'PASS: daemon selection, failover, failback, DNS transitions, all-dead and shutdown cleanup'
