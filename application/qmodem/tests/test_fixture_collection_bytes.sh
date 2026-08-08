#!/usr/bin/env bash
# Collection must not alter stdout bytes or the AT tool exit status.
set -u

PACKAGE_DIR=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
QMODEM_HOME="$PACKAGE_DIR/files/usr/share/qmodem"
QMODEM_LIB_FUNCTIONS="$PACKAGE_DIR/tests/lib/functions_stub.sh"
QMODEM_COLLECT_TESTCASE=1
QMODEM_COLLECT_DIR=$(mktemp -d)
vendor=quectel
platform=qualcomm
QMODEM_TESTCASE_MODEL=RM500Q-AE
clear_buffer=0
options=
use_ubus_flag=
export QMODEM_HOME QMODEM_LIB_FUNCTIONS QMODEM_COLLECT_TESTCASE QMODEM_COLLECT_DIR
export vendor platform QMODEM_TESTCASE_MODEL clear_buffer options use_ubus_flag

cleanup() { rm -rf "$QMODEM_COLLECT_DIR" "$expected" "$actual" "$recorded"; }
expected=$(mktemp)
actual=$(mktemp)
recorded=$(mktemp)
trap cleanup EXIT

uci() { return 1; }
tom_modem()
{
    case " $* " in
        *' -t 1 '*) printf 'FAST\r\n\r\n\r\n'; return 9 ;;
        *) printf 'NORMAL\r\n\r\n\r\n'; return 7 ;;
    esac
}

. "$QMODEM_HOME/modem_util.sh"
. "$PACKAGE_DIR/tests/lib/hex.sh"

printf 'NORMAL\r\n\r\n\r\n' > "$expected"
at /dev/ttyUSB2 'AT+BYTECHECK' > "$actual"
rc=$?
[ "$rc" -eq 7 ]
cmp "$expected" "$actual"
fixture=$(find "$QMODEM_COLLECT_DIR/quectel" -name '*BYTECHECK*.json')
fixture_hex_decode "$(jq -r '.responses[0].response_hex' "$fixture")" > "$recorded"
cmp "$expected" "$recorded"
[ "$(jq -r '.responses[0].rc' "$fixture")" -eq 7 ]
[ "$(jq -r '.platform' "$fixture")" = qualcomm ]
[ "$(jq -r '.model' "$fixture")" = RM500Q-AE ]
case "$fixture" in */quectel/qualcomm/rm500q-ae-9f94df3c/*) ;; *) exit 1 ;; esac

printf 'FAST\r\n\r\n\r\n' > "$expected"
fastat /dev/ttyUSB2 'AT+FASTBYTECHECK' > "$actual"
rc=$?
[ "$rc" -eq 9 ]
cmp "$expected" "$actual"
fixture=$(find "$QMODEM_COLLECT_DIR/quectel" -name '*FASTBYTECHECK*.json')
fixture_hex_decode "$(jq -r '.responses[0].response_hex' "$fixture")" > "$recorded"
cmp "$expected" "$recorded"
[ "$(jq -r '.responses[0].rc' "$fixture")" -eq 9 ]
[ "$(jq -r '.responses[0].scenario' "$fixture")" = default ]
[ "$(jq -r '.responses[0].sequence' "$fixture")" -eq 0 ]
[ "$(jq -r '.responses[0].capture_sequence' "$fixture")" -eq 0 ]

variant=ONE
tom_modem()
{
    printf '%s\r\nOK\r\n' "$variant"
}
at /dev/ttyUSB2 'AT+VARIANT' >/dev/null
variant=TWO
at /dev/ttyUSB2 'AT+VARIANT' >/dev/null
at /dev/ttyUSB2 'AT+VARIANT' >/dev/null
QMODEM_TESTCASE_SCENARIO=sim-absent
export QMODEM_TESTCASE_SCENARIO
at /dev/ttyUSB2 'AT+VARIANT' >/dev/null
fixture=$(find "$QMODEM_COLLECT_DIR/quectel" -name '*VARIANT*.json')
[ "$(jq '.responses | length' "$fixture")" -eq 4 ]
[ "$(jq -r '.responses[0].response_hex' "$fixture")" != "$(jq -r '.responses[1].response_hex' "$fixture")" ]
[ "$(jq -r '[.responses[] | select(.scenario == "default") | .sequence] | join(" ")' "$fixture")" = '0 1 2' ]
[ "$(jq -r '[.responses[] | select(.scenario == "sim-absent") | .sequence] | join(" ")' "$fixture")" = '0' ]

QMODEM_TESTCASE_SCENARIO=parallel
export QMODEM_TESTCASE_SCENARIO
for n in 0 1 2 3 4 5 6 7; do
    response_file="$QMODEM_COLLECT_DIR/parallel-$n.response"
    printf 'RESPONSE-%s\r\n' "$n" > "$response_file"
    (qmodem_record_testcase_file at 'AT+PARALLEL' "$response_file" 0) &
done
wait
fixture=$(find "$QMODEM_COLLECT_DIR/quectel" -name '*PARALLEL*.json')
[ "$(jq '.responses | length' "$fixture")" -eq 8 ]
[ "$(jq -r '[.responses[].sequence] | sort | join(" ")' "$fixture")" = '0 1 2 3 4 5 6 7' ]

echo 'fixture collection byte tests passed'
