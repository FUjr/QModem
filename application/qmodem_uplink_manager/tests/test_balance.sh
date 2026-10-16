#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
if [ "${UPLINK_NETNS_TEST:-0}" != 1 ]; then
    # Root already has namespace capabilities; a second user namespace would
    # hide runner-owned directories from the mapped root identity.
    ns_flags=-Urnm
    [ "$(id -u)" != 0 ] || ns_flags=-nm
    exec unshare "$ns_flags" sh -c 'mount --make-rprivate /; mount -t sysfs sysfs /sys; exec env UPLINK_NETNS_TEST=1 "$@"' sh "$0"
fi
. "$root/root/usr/share/qmodem-uplink/core.sh"
UP_TARGETS=223.5.5.5 UP_TIMEOUT=1
fixture=$(mktemp -d)
RUN=$fixture
UP_STATE=$fixture/state
. "$root/root/usr/share/qmodem-uplink/balance.sh"
children=''
cleanup() {
    rc=$?
    if [ "$rc" != 0 ] && [ -n "${TEST_ARTIFACT_DIR:-}" ]; then
        conntrack -L -f ipv4 -o extended > "$TEST_ARTIFACT_DIR/conntrack.txt" 2>&1
        conntrack -S > "$TEST_ARTIFACT_DIR/conntrack-stats.txt"
        ip -4 route show table all > "$TEST_ARTIFACT_DIR/routes.txt"
        nft list ruleset > "$TEST_ARTIFACT_DIR/ruleset.txt"
        ip -s link > "$TEST_ARTIFACT_DIR/link-stats.txt"
    fi
    for child in $children; do kill "$child" 2>/dev/null || :; done
    rm -rf "$fixture"
}
trap cleanup EXIT INT TERM
if [ -n "${TEST_ARTIFACT_DIR:-}" ]; then
    tcpdump -Z root -U -i any -w "$TEST_ARTIFACT_DIR/balance.pcap" > "$TEST_ARTIFACT_DIR/capture.log" 2>&1 & children="$children $!"
fi
ip link set lo up
# Two independent virtual ISPs deliberately use identical local/gateway/target IPs.
for i in 0 1; do
    unshare -n sh -c 'exec sleep 600' & child=$!
    children="$children $child"
    eval "peer$i=$child"
    # Wait for child to enter its new namespace before moving the peer.
    n=0
    while [ "$(readlink /proc/$child/ns/net)" = "$(readlink /proc/self/ns/net)" ]; do
        n=$((n+1)); [ "$n" -lt 1000 ];
    done
    ip link add "cell$i" type veth peer name "isp$i"
    ip link set "isp$i" netns "$child"
    ip addr add 10.0.0.2/24 dev "cell$i"; ip link set "cell$i" up
    nsenter -t "$child" -n ip link set lo up
    nsenter -t "$child" -n ip addr add 223.5.5.5/32 dev lo
    nsenter -t "$child" -n ip addr add 10.0.0.1/24 dev "isp$i"
    nsenter -t "$child" -n ip link set "isp$i" up
    echo 0 > "/proc/sys/net/ipv4/conf/cell$i/rp_filter"
    nsenter -t "$child" -n sysctl -qw "net.ipv4.conf.isp$i.rp_filter=0"
done
echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter
# Existing business route and a higher priority user policy must survive.
ip route add default via 10.0.0.1 dev cell1 metric 50
ip rule add pref 100 to 198.51.100.0/24 table 123
ip route add blackhole 198.51.100.0/24 table 123
baseline=$(ip -j -4 route show table main)
up_policy_init
ip link add br-lan type bridge
ip link set br-lan up
ip addr add 172.19.0.1/24 dev br-lan
for i in 0 1; do
    unshare -n sh -c 'exec sleep 600' & child=$!
    children="$children $child"
    eval "client$i=$child"
    while [ "$(readlink /proc/$child/ns/net)" = "$(readlink /proc/self/ns/net)" ]; do :; done
    ip link add "lan$i" type veth peer name "host$i"
    ip link set "lan$i" master br-lan
    ip link set "lan$i" up
    ip link set "host$i" netns "$child"
    nsenter -t "$child" -n ip addr add "172.19.0.$((i+2))/24" dev "host$i"
    nsenter -t "$child" -n ip link set "host$i" up
    nsenter -t "$child" -n ip link set lo up
    nsenter -t "$child" -n ip route add default via 172.19.0.1
    eval "peer=\$peer$i"
    nsenter -t "$peer" -n python3 "$root/tests/packet_peer.py" server "$i" & children="$children $!"
done
echo 1 > /proc/sys/net/ipv4/ip_forward
nft 'add table ip test_nat; add chain ip test_nat post { type nat hook postrouting priority srcnat; policy accept; }; add rule ip test_nat post oifname { "cell0", "cell1" } masquerade'
: > "$RUN/rules"
config_generation=test UP_MODE=balance
result='[{"id":"wired:cell0","mark_id":1,"device":"cell0","address":"10.0.0.2","gateway":"10.0.0.1","priority":10,"weight":1,"enabled":true,"health":{"healthy":true}},{"id":"modem:cell1","mark_id":2,"device":"cell1","address":"10.0.0.2","gateway":"10.0.0.1","priority":10,"weight":1,"enabled":true,"health":{"healthy":true}}]'
up_nft_publish
# Control experiment: reproduce host NAT behavior without manager rules/routes.
if [ "${TEST_BASELINE_NAT:-0}" = 1 ]; then
    up_nft_cleanup; up_cleanup_routes
    sleep 0.2
    for start in 20000 30000; do
        for client in "$client0" "$client1"; do
            nsenter -t "$client" -n python3 "$root/tests/packet_peer.py" sample 5000 "$start" 1
        done
    done
    echo 'PASS: baseline NAT without manager'
    exit 0
fi
# Incoming DNAT and router-local replies must return through ingress even
# when another uplink is preferred. These are real TCP connections.
nsenter -t "$client0" -n python3 "$root/tests/packet_peer.py" server 7 172.19.0.2 & children="$children $!"
python3 "$root/tests/packet_peer.py" server 8 0.0.0.0 & children="$children $!"
nft 'add chain ip test_nat pre { type nat hook prerouting priority dstnat; }; add rule ip test_nat pre iifname { "cell0", "cell1" } tcp dport 19001 dnat to 172.19.0.2:9001; add rule ip test_nat pre iifname { "cell0", "cell1" } tcp dport 19002 redirect to :9001'
# Wait for TCP listeners before checking the path.
sleep 0.2
for peer in "$peer0" "$peer1"; do
    nsenter -t "$peer" -n python3 "$root/tests/packet_peer.py" connect 10.0.0.2 19001 7
    nsenter -t "$peer" -n python3 "$root/tests/packet_peer.py" connect 10.0.0.2 19002 8
done
if [ "${TEST_NFT_TRACE:-0}" = 1 ]; then
    nft 'add table ip debug_trace; add chain ip debug_trace pre { type filter hook prerouting priority -96; }; add rule ip debug_trace pre ip saddr 172.19.0.3 udp sport 30000-35000 meta nftrace set 1'
    nft monitor trace > "$TEST_ARTIFACT_DIR/trace.txt" & children="$children $!"
fi
# Non-owned mark bits survive classification.
nft 'add table ip test_mark; add chain ip test_mark pre { type filter hook prerouting priority -95; }; add rule ip test_mark pre iifname "br-lan" meta mark set 0x01000000 ct mark set ct mark | 0x02000000'
nsenter -t "$client0" -n python3 "$root/tests/packet_peer.py" sample 5000 20000 0.5 > "$fixture/count0"
nsenter -t "$client1" -n python3 "$root/tests/packet_peer.py" sample 5000 20000 0.5 > "$fixture/count1"
cat "$fixture/count0" "$fixture/count1"
conntrack -L -f ipv4 -o extended 2>/dev/null | grep -q 'mark=33619968'
nsenter -t "$client0" -n python3 "$root/tests/packet_peer.py" pin "$fixture" & pinned=$!
children="$children $pinned"
wait_file() { n=0; while [ ! -f "$fixture/$1" ]; do n=$((n+1)); [ "$n" -lt 300 ] || return 1; sleep 0.05; done; }
wait_file ready
result=$(printf '%s' "$result" | jq -c '.[1].weight=3')
up_nft_publish
touch "$fixture/phase1"
wait_file done1
nsenter -t "$client0" -n python3 "$root/tests/packet_peer.py" sample 5000 30000 0.75
nsenter -t "$client1" -n python3 "$root/tests/packet_peer.py" sample 5000 30000 0.75
result=$(printf '%s' "$result" | jq -c '.[0].health.healthy=false')
up_nft_publish
touch "$fixture/phase2"
wait_file done2
nsenter -t "$client0" -n python3 "$root/tests/packet_peer.py" sample 100 40000 1
# A fixed rule must block instead of falling back while its exit is unhealthy.
echo 'ct mark & 0x00ff0000 == 0 ip saddr 172.19.0.3 ct mark set (ct mark & 0xff00ffff) | 65536' > "$RUN/rules"
up_nft_publish
nsenter -t "$client1" -n python3 "$root/tests/packet_peer.py" blocked 45000
result=$(printf '%s' "$result" | jq -c '.[0].health.healthy=true')
up_nft_publish
nsenter -t "$client1" -n python3 "$root/tests/packet_peer.py" sample 100 41000 0
: > "$RUN/rules"
result=$(printf '%s' "$result" | jq -c '.[1].priority=20')
up_nft_publish
nsenter -t "$client0" -n python3 "$root/tests/packet_peer.py" sample 100 42000 0
touch "$fixture/phase3"
wait_file done3
wait "$pinned"
result=$(printf '%s' "$result" | jq -c 'map(.health.healthy=false)')
up_nft_publish
nsenter -t "$client0" -n python3 "$root/tests/packet_peer.py" blocked 45001
# A firewall4-style reload touches only its table; the manager remains effective.
nft 'add table inet fw4; flush table inet fw4'
nsenter -t "$client1" -n python3 "$root/tests/packet_peer.py" blocked 45002
up_nft_cleanup
up_cleanup_routes
[ "$(ip -j -4 route show table main | jq -c '[.[]|select(.dev!="br-lan")]')" = "$(printf '%s' "$baseline" | jq -c .)" ]
echo 'PASS: 20000 weighted NAT connections from two LAN clients, overlapping WAN addresses, TCP pinning through policy changes/failure/recovery, priority groups, strict fixed rules, all-dead and firewall reload'
