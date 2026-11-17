#!/bin/sh
set -eu
pkg="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
. "$pkg/files/usr/share/qmodem/led_scripts/misectel_led.sh"
controller="$(sed '/^\. /d; /^misectel_led_init || exit 1/,$d' "$pkg/files/usr/share/qmodem/led_scripts/misectel_3led.sh" | sed 's@$(/usr/share/qmodem/modem_ctrl.sh cell_info "$MODEM_CFG")@${CELL_FIXTURE}@')"
set -- signal_hold_test on
eval "$controller"
LED_SIGNAL_POOR=rf1 LED_SIGNAL_GOOD=rf2 LED_SIGNAL_EXCELLENT=rf3
LED_SIGNAL_MAX=rf4 LED_SIM=sim LED_5G=nr
get_sim_state() { echo "$SIM_STATE"; }
get_mode() { echo 1; }
signal_uptime() { echo "$NOW"; }
led_turn() { [ -z "$1" ] || writes="${writes}$1=$2 "; }
step() { writes=; update_leds; }
valid='{"modem_info":[{"key":"RSRP","value":"-74"}]}'
invalid='{"modem_info":[]}'
# Startup failure must not illuminate signal LEDs.
SIM_STATE=present NOW=100 CELL_FIXTURE="$invalid"
step
[ "$writes" = 'sim=1 rf4=0 rf1=0 rf2=0 rf3=0 nr=0 ' ]
CELL_FIXTURE="$valid"
step
[ "$writes" = 'sim=1 nr=1 rf4=1 rf1=1 rf2=1 rf3=1 ' ]
# Failed queries neither change the signal LEDs nor extend their lifetime.
CELL_FIXTURE="$invalid" NOW=110
step
[ "$writes" = 'sim=1 ' ]
SIM_STATE=unknown NOW=129
step
[ -z "$writes" ]
NOW=130
step
[ "$writes" = 'rf4=0 rf1=0 rf2=0 rf3=0 nr=0 ' ]
# A valid sample recovers immediately and starts a new lifetime.
SIM_STATE=present CELL_FIXTURE="$valid" NOW=131
step
[ "$writes" = 'sim=1 nr=1 rf4=1 rf1=1 rf2=1 rf3=1 ' ]
# Confirmed removal clears all LEDs and invalidates retained state immediately.
SIM_STATE=absent NOW=132
step
[ "$writes" = 'rf4=0 rf1=0 rf2=0 rf3=0 sim=0 nr=0 ' ]
[ -z "$last_valid_signal_time" ]
SIM_STATE=present CELL_FIXTURE="$invalid" NOW=133
step
[ "$writes" = 'sim=1 rf4=0 rf1=0 rf2=0 rf3=0 nr=0 ' ]
echo 'Signal hold, expiry, recovery and SIM removal tests passed'
