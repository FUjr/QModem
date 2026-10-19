#!/bin/sh
set -eu

PACKAGE_DIR="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
. "$PACKAGE_DIR/files/usr/share/qmodem/led_scripts/misectel_led.sh"

# Stub board/UCI reads, but exercise the real selector and LED state machine.
cat() {
    case "$1" in
        /tmp/sysinfo/board_name) echo "$TEST_BOARD" ;;
        *) command cat "$@" ;;
    esac
}
config_load() { :; }
config_get() {
    case "$2:$3" in
        cellular1:led_group) eval "$1=5g1" ;;
        cellular2:led_group) eval "$1=5g2" ;;
        *) eval "$1=" ;;
    esac
}

# Load controller functions without target-only imports or its infinite loop.
controller="$(sed '/^\. /d; /^misectel_led_init || exit 1/,$d' \
    "$PACKAGE_DIR/files/usr/share/qmodem/led_scripts/misectel_3led.sh")"
set -- testmodem on
eval "$controller"

TEST_BOARD=misectel,m02k88
for group in 1 2; do
    QMODEM_LED_SECTION="cellular$group"
    misectel_led_init
    [ "$LED_SIM" = "5g${group}:sim" ]
    [ "$LED_SIGNAL_POOR" = "5g${group}:rf1" ]
    [ "$LED_SIGNAL_GOOD" = "5g${group}:rf2" ]
    [ "$LED_SIGNAL_EXCELLENT" = "5g${group}:rf3" ]
    [ -z "$LED_5G" ]

    writes=
    led_turn() {
        [ -n "$1" ] || return 0
        writes="${writes}${1}=${2} "
    }
    get_sim_state() { echo "$SIM_STATE"; }
    # Exercise the production JSON extraction and thresholds on both banks.
    get_mode() { echo 1; }
    # The controller invokes modem_ctrl by absolute path. Replace only that I/O.
    test_update="$(printf '%s\n' "$controller" | sed \
        's@$(/usr/share/qmodem/modem_ctrl.sh cell_info "$MODEM_CFG")@${CELL_FIXTURE}@')"
    eval "$test_update"
    get_sim_state() { echo "$SIM_STATE"; }
    get_mode() { echo 1; }
    for sample in '-120:1:0:0' '-100:1:1:0' '-80:1:1:1' '0:0:0:0'; do
        old_ifs="$IFS"; IFS=:; set -- $sample; IFS="$old_ifs"
        CELL_FIXTURE='{"modem_info":[{"key":"RSRP","value":"'"$1"'"}]}'
        SIM_STATE=present
        writes=
        update_leds
        expected="5g${group}:sim=1 5g${group}:rf1=$2 5g${group}:rf2=$3 5g${group}:rf3=$4 "
        [ "$writes" = "$expected" ] || { echo "unexpected state: $writes" >&2; exit 1; }
    done
    SIM_STATE=absent
    writes=
    update_leds
    [ "$writes" = "5g${group}:rf1=0 5g${group}:rf2=0 5g${group}:rf3=0 5g${group}:sim=0 " ]
done
QMODEM_LED_SECTION=invalid
if misectel_led_init; then
    echo 'invalid LED bank accepted' >&2
    exit 1
fi
unset QMODEM_LED_SECTION
if misectel_led_init; then
    echo 'missing LED bank accepted' >&2
    exit 1
fi
TEST_BOARD=misectel,m01k21
misectel_led_init
[ "$LED_SIM" = lede:blue:4gblue ]
# Generate real board JSON with the repository's JSON fixture implementation.
board_json="$(
    . "$PACKAGE_DIR/tests/lib/jshn_stub.sh"
    . "$PACKAGE_DIR/files/lib/functions/qmodem-defaults.sh"
    json_select_object() { json_select "$1"; }
    board_name() { echo misectel,m02k88; }
    board_config_update() { json_init; }
    board_config_flush() { json_dump; }
    eval "$(sed '/^\. /d' "$PACKAGE_DIR/files/etc/board.d/03_qmodem")"
)"
printf '%s\n' "$board_json" | jq -e '
    .qmodem.slots as $slots | .qmodem_led.modem_status as $leds |
    ($slots | keys) == ["pcie0", "usb0"] and
    $slots.usb0.slot == "2-1" and $slots.pcie0.slot == "0002:01:00.0" and
    ($slots[] | has("associated_usb") | not) and
    $slots.usb0.gpio == "5g1_en" and $slots.pcie0.gpio == "5g2_en" and
    ($slots[] | .gpio_up == "1" and .gpio_down == "0") and
    $leds.cellular1.port == $slots.usb0.slot and
    $leds.cellular2.port == $slots.pcie0.slot and
    $leds.cellular1.bind == "port" and $leds.cellular2.bind == "port" and
    $leds.cellular1.led_group == "5g1" and $leds.cellular2.led_group == "5g2"
' >/dev/null

echo 'M02K88 independent SIM/RF LED and board-default tests passed'
