#!/bin/sh
# Ensure modem_dial/modem_util wrappers pass the exact final command to at().
set -eu

PACKAGE_DIR=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
QMODEM_DIR="$PACKAGE_DIR/files/usr/share/qmodem"
GENERIC_FILE="$QMODEM_DIR/generic.sh"
FIBOCOM_FILE="$QMODEM_DIR/vendor/fibocom.sh"
observed=

at()
{
    observed_port=$1
    observed=$2
    export observed_port observed
}

. "$QMODEM_DIR/cmds/modem_util.sh"
. "$QMODEM_DIR/cmds/modem_dial.sh"
. "$QMODEM_DIR/cmds/fibocom.sh"

cmd_util_quimslot_query /dev/ttyUSB2
[ "$observed_port" = /dev/ttyUSB2 ]
[ "$observed" = 'AT+QUIMSLOT?' ]

cmd_dial_cpin_unlock /dev/ttyUSB3 1234
[ "$observed_port" = /dev/ttyUSB3 ]
[ "$observed" = 'AT+CPIN="1234"' ]

dynamic='AT+CGDCONT=3,"IPV4V6","internet"'
cmd_dial_command /dev/ttyUSB4 "$dynamic"
[ "$observed_port" = /dev/ttyUSB4 ]
[ "$observed" = "$dynamic" ]

cmd_dial_neoway_simcross_iccid /dev/ttyUSB5
[ "$observed" = 'AT+SIMCROSS=1,1;$MYCCID' ]

cmd_gtcurcar_query /dev/ttyUSB6
[ "$observed_port" = /dev/ttyUSB6 ]
[ "$observed" = 'AT+GTCURCAR?' ]

get_function()
{
    awk -v name="$1" '
        $0 == name "()" { capture = 1 }
        capture { print }
        capture && $0 == "}" { exit }
    ' "$2"
}

eval "$(get_function get_cgpaddr_ipv4 "$GENERIC_FILE")"
fm350_cgpaddr='+CGPADDR: 2,"10.3.4.136","0.0.0.0.0.0.0.0.24.141.77.91.197.17.80.76"'
[ "$(get_cgpaddr_ipv4 "$fm350_cgpaddr")" = '10.3.4.136' ]
[ -z "$(get_cgpaddr_ipv4 '+CGPADDR: 1,"0.0.0.0",""')" ]

eval "$(get_function fibocom_get_carrier "$FIBOCOM_FILE")"
platform=mediatek
at_port=/dev/ttyUSB6
cmd_gtcurcar_query() { printf '%s\n' '+GTCURCAR: 117,"China Telecom"'; }
cmd_cops_query() { printf '%s\n' '+COPS: 0,2,"garbled",7'; }
[ "$(fibocom_get_carrier)" = 'China Telecom' ]
cmd_gtcurcar_query() { :; }
[ "$(fibocom_get_carrier)" = 'garbled' ]

echo 'core cmds tests passed'
