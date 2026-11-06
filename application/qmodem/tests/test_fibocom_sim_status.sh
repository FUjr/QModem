#!/usr/bin/env bash
set -eu
TESTS_DIR=$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$TESTS_DIR/lib/test_env.sh"
. "$QMODEM_JSHN"
. "$QMODEM_HOME/vendor/fibocom.sh"
test_temp=$(mktemp -d)
trap 'rm -rf "$test_temp"' EXIT

cmd_gtdualsim_query() { printf '+GTDUALSIM: "SUB0"\n'; }
cmd_cgsn() { printf '+CGSN: "TEST"\n'; }
cmd_cpin_query() { printf '%s\n' "$cpin_response"; }
unexpected_card_query() { : >"$test_temp/unexpected-query"; return 1; }
fibocom_get_carrier() { unexpected_card_query; }
cmd_cnum() { unexpected_card_query; }
cmd_cimi() { unexpected_card_query; }
cmd_iccid() { unexpected_card_query; }
cmd_ccid() { unexpected_card_query; }

for state in miss unknown pin; do
    case "$state" in
        miss) cpin_response='+CME ERROR: 10'; expected=miss ;;
        unknown) cpin_response='+CPIN: UNRECOGNIZED'; expected=unknown ;;
        pin) cpin_response='+CPIN: SIM PIN'; expected='MT is waiting SIM PIN to be given' ;;
    esac
    json_init
    json_add_array modem_info
    sim_info || { echo 'SIM information query failed' >&2; exit 1; }
    json_close_array
    result=$(json_dump)
    printf '%s' "$result" | jq -e --arg expected "$expected" \
        '[.modem_info[] | select(.key == "SIM Status")] | length == 1 and .[0].value == $expected' >/dev/null
done
[ ! -e "$test_temp/unexpected-query" ]

fibocom_get_carrier() { printf 'Test carrier\n'; }
cmd_cnum() { printf '+CNUM: "5550100"\n'; }
cmd_cimi() { printf '+CIMI: 12345678\n'; }
cmd_iccid() { printf '+ICCID: 1234\n'; }
cpin_response='+CPIN: READY'
json_init
json_add_array modem_info
sim_info || { echo 'Ready SIM information query failed' >&2; exit 1; }
json_close_array
json_dump | jq -e '
    [.modem_info[] | select(.key == "SIM Status")][0].value == "ready" and
    [.modem_info[] | select(.key == "ISP")][0].value == "Test carrier" and
    [.modem_info[] | select(.key == "IMSI")][0].value == "12345678" and
    [.modem_info[] | select(.key == "ICCID")][0].value == "1234"
' >/dev/null
echo 'PASS: absent, unknown and PIN states survive; ready SIM queries retain their values'
