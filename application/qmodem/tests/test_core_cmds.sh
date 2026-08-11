#!/bin/sh
# Ensure modem_dial/modem_util wrappers pass the exact final command to at().
set -eu

PACKAGE_DIR=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
QMODEM_DIR="$PACKAGE_DIR/files/usr/share/qmodem"
observed=

at()
{
    observed_port=$1
    observed=$2
    export observed_port observed
}

. "$QMODEM_DIR/cmds/modem_util.sh"
. "$QMODEM_DIR/cmds/modem_dial.sh"

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

echo 'core cmds tests passed'
