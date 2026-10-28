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
children=''
trap 'for child in $children; do kill "$child" 2>/dev/null || :; done' EXIT INT TERM
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
up_probe_route 0 cell0 10.0.0.2 10.0.0.1
up_probe_route 1 cell1 10.0.0.2 10.0.0.1
up_probe cell0
up_probe cell1
# Even an earlier user policy affecting the target cannot contaminate probes.
ip rule add pref 100 to 223.5.5.5/32 table 125
ip route add unreachable default table 125
up_probe cell0
up_probe cell1
ip rule del pref 100 to 223.5.5.5/32 table 125
# Neither probe relies on whichever default route is currently selected.
up_route_default "$UP_BUSINESS" cell0 10.0.0.2 10.0.0.1
ip -4 route get 223.5.5.5 | grep -q 'dev cell0'
ping -c 1 -W 1 223.5.5.5 >/dev/null
nsenter -t "$peer0" -n ip addr del 223.5.5.5/32 dev lo
! up_probe cell0
up_probe cell1
up_route_default "$UP_BUSINESS" cell1 10.0.0.2 10.0.0.1
ip -4 route get 223.5.5.5 | grep -q 'dev cell1'
ping -c 1 -W 1 223.5.5.5 >/dev/null
# All unhealthy: terminal unreachable must beat the still-live main default.
ip route del default table "$UP_BUSINESS" metric 1 proto "$UP_PROTO"
! ip -4 route get 223.5.5.5 2>/dev/null
# A missing reachable probe route must not fall through to another ISP either.
ip route del default table "$UP_FIRST" metric 1 proto "$UP_PROTO"
! up_probe cell0
up_probe cell1
nsenter -t "$peer0" -n ip addr add 223.5.5.5/32 dev lo
up_probe_route 0 cell0 10.0.0.2 10.0.0.1
up_probe cell0
up_route_default "$UP_BUSINESS" cell0 10.0.0.2 10.0.0.1
ip -4 route get 223.5.5.5 | grep -q 'dev cell0'
up_cleanup_routes
[ "$(ip -j -4 route show table main)" = "$baseline" ]
ip rule show | grep -q '100:.*lookup 123'
if [ -n "${TEST_UCI:-}" ]; then
    PEER0=$peer0 PEER1=$peer1 TEST_BASELINE="$baseline" sh "$root/tests/test_daemon.sh"
fi
# Foreign resources are rejected without altering them.
ip route add blackhole default table "$UP_FIRST" proto static
! up_check_namespace
ip route show table "$UP_FIRST" | grep -q blackhole
ip route del blackhole default table "$UP_FIRST" proto static
ip rule add pref 1 lookup 124
! up_check_namespace
ip rule show | grep -q '1:.*lookup 124'
echo 'PASS: real packets, overlapping subnets, isolated probes, failover/failback, all-dead, cleanup, conflict detection'
