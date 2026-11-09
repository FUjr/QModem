#!/bin/bash
set -euo pipefail
package=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
scripts="$package/files/usr/share/qmodem"
load_function() {
    eval "$(awk -v name="$1" '$0 == name "()" { copy=1 } copy {print} copy && $0 == "}" {exit}' "$2")"
}
load_function at_get_slot "$scripts/modem_util.sh"
. "$scripts/cmds/modem_util.sh"
at_port=/dev/test
at() {
    [[ "$3" == 3 ]]
    case "$2" in
        'AT+QUIMSLOT?') printf '+QUIMSLOT: %s\r\n' "$slot" ;;
        'AT+GTDUALSIM?') printf '+GTDUALSIM: 1\r\n' ;;
        *) return 1 ;;
    esac
}
manufacturer=quectel
vendor=
slot=2
at_get_slot
[[ "$sim_slot" == 2 ]]
vendor=unknown
at_get_slot
[[ "$sim_slot" == 2 ]]
slot=invalid
at_get_slot
[[ "$sim_slot" == 2 ]] # Unknown vendor falls back to Fibocom's slot query.

load_function update_config "$scripts/modem_dial.sh"
config_load() { :; }
config_foreach() { :; }
get_driver() { :; }
update_sim_slot() { at_get_slot; }
get_platform_suggest_pdp_index() { echo 1; }
config_get() {
    local value=''
    case "$3" in
        manufacturer) value=quectel ;;
        vendor) value="$configured_vendor" ;;
        path) value=/sys/test ;;
        apn) value=sim1.example ;;
        apn2) value=sim2.example ;;
    esac
    printf -v "$1" '%s' "$value"
}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf '#!/bin/sh\necho wwan0\n' > "$tmp/modem_netdev.sh"
chmod +x "$tmp/modem_netdev.sh"
SCRIPT_DIR=$tmp
modem_config=modem1
pin=
configured_vendor=
for slot in 1 2; do
    vendor=stale
    update_config
    [[ "$vendor" == quectel ]]
    [[ "$apn" == "sim${slot}.example" ]]
done
configured_vendor=fibocom
update_config
[[ "$vendor" == fibocom && "$apn" == sim2.example ]]
echo 'SIM vendor fallback and per-slot APN tests passed'
