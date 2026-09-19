#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
NM_LIBRARY_ONLY=1
export NM_LIBRARY_ONLY
. "$ROOT/application/qmodem_monitor/files/usr/share/qmodem/monitor_recovery.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
NM_RUN=$TMP/run NM_INTENTS=$TMP/intents Modem_ID=test
mkdir -p "$NM_RUN" "$NM_INTENTS"
fail() { echo "FAIL: $*" >&2; exit 1; }
for ip in 1.1.1.1 223.5.5.5 192.168.1.1; do nm_ip "$ip" || fail "valid IP $ip"; done
for ip in '' 1.1.1.1. 01.1.1.1 127.0.0.1 224.0.0.1 240.0.0.1 256.1.1.1 '1.1.1.1;id' 'example.org' ::1; do
    if nm_ip "$ip"; then fail "invalid IP accepted: $ip"; fi
done
nm_uint 3 1 10 || fail uint
if nm_uint 03 1 10; then fail leading_zero; fi

# Execute the actual probe function with controlled network/command outcomes.
nm_interface() { NetDev=wwan_test; Address=true; }
nm_run() {
    shift
    printf '%s\n' "$*" >> "$TMP/pings"
    case "$*" in *1.1.1.1) return "$PRIMARY_RC";; *8.8.8.8) return "$BACKUP_RC";; esac
    return 1
}
nm_init_state
Primary=1.1.1.1 Backup=8.8.8.8 Timeout=3 PRIMARY_RC=1 BACKUP_RC=0
nm_sample || fail backup_success
[ "$PrimaryOK:$BackupOK" = false:true ] || fail backup_results
grep -q -- '-I wwan_test' "$TMP/pings" || fail binding
PRIMARY_RC=0
before=$(wc -l < "$TMP/pings")
nm_sample || fail primary_success
[ "$(wc -l < "$TMP/pings")" -eq "$((before+1))" ] || fail primary_short_circuit
PRIMARY_RC=1 BACKUP_RC=1
if nm_sample; then fail outage; fi

# Four strategies and N boundaries use production transition functions.
nm_init_state
Action=redial_then_switch N=3
for n in 1 2 3; do
    nm_choose_action
    [ "$LastAction" = redial ] || fail "premature switch $n"
    nm_result offline
done
nm_choose_action; [ "$LastAction" = switch_sim_slot ] || fail missing_escalation
nm_result offline; nm_choose_action; [ "$LastAction" = redial ] || fail reset_after_switch
Action=switch_then_redial Switched=0
nm_choose_action; [ "$LastAction" = switch_sim_slot ] || fail switch_first
nm_result offline
for n in 1 2 3; do nm_choose_action; [ "$LastAction" = redial ] || fail repeated_switch; nm_result offline; done
nm_result online; nm_choose_action; [ "$LastAction" = switch_sim_slot ] || fail new_incident
Action=redial_then_switch N=1
nm_choose_action; nm_result offline; nm_choose_action
[ "$LastAction" = switch_sim_slot ] || fail n_one

# Exercise actual CFUN/intent code with transport failures, not string matching.
nm_state() { :; }
nm_sleep() { printf 'sleep %s\n' "$1" >> "$TMP/actions"; }
sync() { :; }
nm_run() { shift; "$@"; }
nm_at_command() {
    printf '%s\n' "$1" >> "$TMP/actions"
    case "$1" in 'AT+CFUN=0') return "$OFF_RC";; 'AT+CFUN=1') return "$ON_RC";; esac
}
redial_stub() { printf 'dial %s\n' "$*" >> "$TMP/actions"; }
NM_NET_SERVICE=redial_stub OFF_RC=0 ON_RC=0
nm_redial || fail recovery
printf '%s\n' 'AT+CFUN=0' 'sleep 1' 'AT+CFUN=1' 'dial redial test' > "$TMP/expected"
cmp "$TMP/actions" "$TMP/expected" || fail action_order
[ ! -e "$NM_INTENTS/test" ] || fail intent_not_cleared
OFF_RC=1
if nm_redial; then fail off_error_hidden; fi
[ ! -e "$NM_INTENTS/test" ] || fail compensation_missing
OFF_RC=0 ON_RC=1
if nm_redial; then fail on_error_hidden; fi
[ -f "$NM_INTENTS/test" ] || fail lost_intent
ON_RC=0
nm_cfun_on || fail restart_compensation
[ ! -e "$NM_INTENTS/test" ] || fail compensation_intent

echo 'network monitor behavioral tests passed'

# Threshold and success-reset exercise the full round, including intervals.
nm_init_state
Packets=3 PacketInterval=2 Samples=0 SucceededAt=99 Delay=0
nm_sample() { Samples=$((Samples+1)); [ "$Samples" = "$SucceededAt" ]; }
nm_sleep() { Delay=$((Delay+$1)); }
if nm_probe_round; then fail threshold; fi
[ "$Samples:$Failures:$Delay" = 3:3:4 ] || fail threshold_timing
Samples=0 Delay=0 SucceededAt=2 ActionFailures=2 Switched=1
nm_probe_round || fail middle_success
[ "$Samples:$Failures:$ActionFailures:$Switched:$Delay" = 2:0:0:0:2 ] || fail success_reset
echo 'network monitor threshold tests passed'

(
    . "$ROOT/application/qmodem_monitor/files/usr/share/qmodem/monitor_recovery.sh"
    nm_init_state
    Connectivity=online
    nm_state online tested
    nm_get() { case "$1" in monitor_enabled) echo 1;; monitor_profile) echo network_recovery;; esac; }
    ubus() { printf '{"qmodem_monitor":{"instances":{"m_test":{"running":true,"pid":%s}}}}\n' "$$"; }
    nm_status | jq -e '.running == true and .stale == false and .connectivity == "online"' >/dev/null || fail live_status
    ubus() { echo '{}'; }
    nm_status | jq -e '.running == false and .stale == true and .connectivity == "unknown"' >/dev/null || fail stopped_status
    AT_PORT=fake
    at() { printf '%s\n' 'NOTOK'; }
    if nm_at_command 'AT+CFUN=1'; then fail substring_ok; fi
    at() { printf 'OK\r\nERROR\r\n'; }
    if nm_at_command 'AT+CFUN=1'; then fail final_error; fi
    at() { printf 'OK\r\n'; return 1; }
    if nm_at_command 'AT+CFUN=1'; then fail transport_error; fi
    at() { printf 'AT+CFUN=1\r\nOK\r\n'; }
    nm_at_command 'AT+CFUN=1' || fail exact_ok
)
echo 'network monitor status and AT result tests passed'
