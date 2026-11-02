#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
VENDOR="$ROOT/files/usr/share/qmodem/vendor/fibocom.sh"
. "$ROOT/tests/lib/jshn_stub.sh"
get_function() {
    awk -v name="$1" '$0 ~ "^" name "\\(\\)" {p=1} p {print} p && $0 == "}" {exit}' "$VENDOR"
}
for fn in fibocom_gtact_rat get_network_prefer_nr get_network_prefer_lte \
          fibocom_gtact_set_result fibocom_get_carrier; do
    eval "$(get_function "$fn")"
done
at_port=/dev/mock
platform=mediatek
cmd_gtact_query() { printf '%b\n' "$response"; }
for response in '+GTACT: 2,6,3,101\r' '+GTACT:2,6,3,101\r' '+GTACT:\t2\r'; do
    json_init
    get_network_prefer_nr
    [ "$(json_dump | jq -c .network_prefer)" = '{"3G":"0","4G":"1","5G":"0"}' ]
    json_init
    get_network_prefer_lte
    [ "$(json_dump | jq -c .network_prefer)" = '{"3G":"0","4G":"1"}' ]
done
for entry in '14 0 0 1' '17 0 1 1' '20 1 1 1' '1 1 0 0' '4 1 1 0' '16 1 0 1'; do
    set -- $entry
    response="+GTACT:$1\r"
    json_init
    get_network_prefer_nr
    [ "$(json_dump | jq -r '[.network_prefer["3G"],.network_prefer["4G"],.network_prefer["5G"]] | join(" ")')" = "$2 $3 $4" ]
done
for response in 'ERROR\r' '+GTACT:999\r' ''; do
    json_init
    if get_network_prefer_nr; then echo 'FAIL: invalid RAT accepted' >&2; exit 1; fi
    [ "$(json_dump | jq -r .network_prefer)" = null ]
done
cmd_gtcurcar_query() { printf '+GTCURCAR: 1,"%s"\r\n' "$carrier_response"; }
cmd_cops_query() { printf '+COPS:0,0,"China Mobile",11\r\n'; }
for carrier_response in Generic generic UNKNOWN ''; do
    [ "$(fibocom_get_carrier)" = 'China Mobile' ]
done
carrier_response='China Telecom'
[ "$(fibocom_get_carrier)" = 'China Telecom' ]
json_init
fibocom_gtact_set_result "$(printf '\r\nOK\r\n')"
[ "$(json_dump | jq -r .success)" = true ]
for response in ERROR '+CME ERROR: 3' '' 'OKAY'; do
    json_init
    fibocom_gtact_set_result "$response"
    [ "$(json_dump | jq -r .success)" = false ]
done
echo 'PASS: Fibocom RAT framing, explicit modes, invalid replies, carrier fallback and set errors'
