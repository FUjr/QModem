#!/bin/sh
set -eu
package=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
script=${QMODEM_DIAL_SCRIPT:-$package/files/usr/share/qmodem/modem_dial.sh}
real_uci=$(command -v "${TEST_UCI:-uci}")
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT INT TERM
mkdir "$fixture/config" "$fixture/delta" "$fixture/bin"
export TEST_REAL_UCI="$real_uci" TEST_CONFIG="$fixture/config" TEST_DELTA="$fixture/delta"
cat > "$fixture/bin/uci" <<'SCRIPT'
#!/bin/sh
exec "$TEST_REAL_UCI" -c "$TEST_CONFIG" -t "$TEST_DELTA" "$@"
SCRIPT
chmod +x "$fixture/bin/uci"
export PATH="$fixture/bin:$PATH"
# Use the installed functions with isolated real UCI data; no service/device writes.
sed -n '/^append_to_fw_zone()/,/^set_if()/p' "$script" | sed '$d' > "$fixture/functions"
. "$fixture/functions"
append() {
    [ "$1" = retained_networks ] || return 2
    retained_networks="${retained_networks:+$retained_networks }$2"
}
printf "config zone 'wan'\n option name 'wan'\n option network 'wan wan6'\n" > "$fixture/config/firewall"
n=0
while [ "$n" -lt 10 ]; do
    append_to_fw_zone wan pcie0
    append_to_fw_zone wan wwan0
    n=$((n+1))
done
[ "$(uci -q get firewall.wan.network)" = 'wan wan6 pcie0 wwan0' ]
remove_from_fw_zone wan pcie0
[ "$(uci -q get firewall.wan.network)" = 'wan wan6 wwan0' ]
# Repair escaped legacy memberships produced by scalar/list round trips.
broken="wan6'\\' wan'\\' wan"
uci -q set "firewall.wan.network=$broken"
append_to_fw_zone wan pcie0
append_to_fw_zone wan wwan0
[ "$(uci -q get firewall.wan.network)" = 'wan6 wan pcie0 wwan0' ]
echo 'PASS: real UCI legacy scalar, repeated modem membership, removal and escaped-list repair'
