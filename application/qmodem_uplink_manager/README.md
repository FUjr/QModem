# QModem IPv4 uplink manager

Install `qmodem-uplink-manager` and optionally `luci-app-qmodem-uplink`.
The manager is disabled by default. Configure `/etc/config/qmodem_uplink` or
Network → Uplink Balancing, select WAN logical interfaces and QModem instance
IDs, then enable it. Misectel network settings use the same UCI and RPC backend.

Healthy enabled members with the lowest numeric priority share **new IPv4
connections** by weight. Equal priority and weight use both cards (or WAN and
WWAN) concurrently across clients/connections. Higher priorities are backups.
Failover mode selects one member. A single connection never aggregates links.
The first successful probe admits a new member; recovery thereafter requires
both success count and stability duration. Configure one to four probe targets as IPv4 literals.

Ordered fixed exit rules match source/destination IPv4/CIDR, protocol and single
ports (TCP/UDP). First match wins. A failed fixed exit blocks matching new
connections instead of leaking them through another uplink. Existing connections
keep their mark when priorities, weights or rules change. Disabling a healthy
member drains existing connections. PDP/address/device-generation changes delete
only that member's stale conntrack entries. Link loss can interrupt its existing
connections; connections cannot migrate between different public IP addresses.

Only routed IPv4 participates. Passthrough/enslaved devices and unsupported
QModem dial backends are excluded with a reason. Managed Quectel CM normalizes
IPv4 events through netifd and does not configure host addresses/routes/DNS itself.
IPv6 keeps its existing independent behavior. Set IPv6 policy separately if IPv4
fixed-exit requirements must apply to an entire client application.

The manager uses software forwarding: firewall flow offload, hardware flow
offload and IPv4 FullCone are leased to zero while enabled and conditionally
restored on stop/disabled boot. Stop mwan3/QModem mwan first; concurrent ownership
is rejected. Firewall4 retains NAT and access control. This package adds no
forwarding permissions and needs normal WAN masquerading/forwarding configuration.

Reserved namespace: nft `ip qmodem_uplink` with ownership comment
`qmodem-uplink:v1`, conntrack/packet mark mask `0x00ff0000`, route protocol 201,
tables 31099–31264, rule priorities 1–64, 31000–31064, 31100–31101.
Conflicting routes/rules/table ownership are rejected. Do not use these mark bits
in another firewall policy. Member IDs persist in `/etc/qmodem-uplink/ids.json`;
retired IDs are reused only without surviving conntrack. Back up that directory
alongside the UCI configuration if preserving runtime identity across restores.

`ubus call qmodem.uplink status` reports desired/applied configuration hashes,
active member IDs, effective weights, health, session reasons and freshness.
Invalid reloads retain the previous packet policy and report `invalid_config`.
Status polling never changes modem selection in either UI. DNS uses the first
healthy preferred member and existing dnsmasq include directories; manual
per-domain servers remain authoritative. Custom include paths are not managed.

## Host validation

Run `tests/test_health.sh`; run `tests/test_routes.sh` and `tests/test_balance.sh`
on a Linux host with unprivileged user/network namespaces, ip-full, nftables,
jq, conntrack and Python 3. These create disposable namespaces, never modify host
routing. Supply `TEST_UCI` (native OpenWrt uci), `LD_LIBRARY_PATH` if needed, and
`TEST_FUNCTIONS` (OpenWrt lib/functions.sh) to include the real daemon/UCI test.
`test_balance.sh` sends 20,000 UDP connections from two clients, checks 1:1 and
1:3 distributions, TCP pinning, inbound DNAT/local replies, strict fixed exit, link recovery, and independent
firewall table reload. Host packets do not prove cellular modem/device behavior. Initial UDP requests
permit at most three attempts on the same socket, report retry counts, and fail
on excessive loss; established flow pinning has no retry. The optional
`TEST_BASELINE_NAT=1` control removes all manager rules/routes before sending
traffic. `TEST_ARTIFACT_DIR` enables pcap and failure diagnostics;
`TEST_NFT_TRACE=1` additionally records nft traces.

Before release, validate real dual-modem and WAN+WWAN hardware, NAT inbound
services, DNS, reboot/hotplug, throughput and memory with the intended firmware.
