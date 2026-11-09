#!/bin/bash
set -euo pipefail
package=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
eval "$(sed -n '/^at()$/,/^fastat()$/p' "$package/files/usr/share/qmodem/modem_util.sh" | sed '$d')"
qmodem_at_lock() { return 0; }
qmodem_testcase_collect_enabled() { [[ "$collect" == 1 ]]; }
qmodem_record_testcase_file() { :; }
uci() { echo "$tool"; }
options=
clear_buffer=0
use_ubus_flag=
sms_tool_q() { printf '%s\n' "$@"; }
tom_modem() { printf '%s\n' "$@"; }
for tool in 0 1; do
    for collect in 0 1; do
        args=$(at /dev/test 'AT+QUIMSLOT?' 3)
        [[ "$args" == *$'-t\n3'* ]]
        args=$(at /dev/test 'AT+CGMI')
        [[ "$args" != *'-t'* ]]
    done
done
echo 'AT query timeout passes to both tools with and without fixture collection'
