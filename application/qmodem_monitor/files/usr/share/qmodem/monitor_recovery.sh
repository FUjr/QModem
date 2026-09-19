#!/bin/sh
# Shared QModem network monitor. The legacy monitor remains an opt-in profile.

NM_RUN=${NM_RUN:-/var/run/qmodem_monitor}
NM_INTENTS=${NM_INTENTS:-/etc/qmodem/monitor-intent}
NM_GUARD=${NM_GUARD:-/usr/libexec/qmodem-monitor-guard}
NM_NET_SERVICE=${NM_NET_SERVICE:-/etc/init.d/qmodem_network}

nm_now() { cut -d. -f1 /proc/uptime; }
nm_uint() {
    case "$1" in ''|*[!0-9]*|0[0-9]*) return 1;; esac
    [ "${#1}" -le 5 ] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}
nm_ip() {
    printf '%s\n' "$1" | awk -F. '
      NF != 4 {exit 1}
      {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || length($i)>3 || ($i ~ /^0[0-9]/) || $i>255) exit 1;
       if($1==0 || $1==127 || $1>=224) exit 1;}'
}
nm_get() { local v; v=$(uci -q get "qmodem.$Modem_ID.$1"); printf '%s' "${v:-$2}"; }
nm_config() {
    Enabled=$(nm_get monitor_enabled 0)
    Primary=$(nm_get monitor_primary_ip 223.5.5.5)
    Backup=$(nm_get monitor_backup_ip '')
    Timeout=$(nm_get monitor_timeout 3)
    Packets=$(nm_get monitor_failure_packets 3)
    PacketInterval=$(nm_get monitor_packet_interval 1)
    Interval=$(nm_get monitor_interval 15)
    Settle=$(nm_get monitor_settle_timeout 60)
    Action=$(nm_get monitor_recovery_action switch_sim_slot)
    N=$(nm_get monitor_action_failures 3)
    AT_PORT=$(nm_get at_port '')
    Alias=$(nm_get alias "$Modem_ID"); [ "$Alias" = - ] && Alias=$Modem_ID
    use_ubus_flag=''; [ "$(nm_get use_ubus 1)" = 1 ] && use_ubus_flag=-u
    nm_ip "$Primary" && { [ -z "$Backup" ] || { nm_ip "$Backup" && [ "$Backup" != "$Primary" ]; }; } &&
        nm_uint "$Timeout" 1 30 && nm_uint "$Packets" 1 10 &&
        nm_uint "$PacketInterval" 1 60 && nm_uint "$Interval" 5 3600 &&
        nm_uint "$Settle" 10 600 && nm_uint "$N" 1 12 || return 1
    case "$Action" in switch_sim_slot|redial|redial_then_switch|switch_then_redial) ;; *) return 1;; esac
    case "$Alias" in ''|*[!A-Za-z0-9_-]*) return 1;; esac
    [ -n "$AT_PORT" ]
}
nm_init_state() {
    Connectivity=unknown Phase=starting Reason='' Failures=0 ActionFailures=0
    PrimaryOK=null BackupOK=null LastAction='' CommandOK=null Address=false
    NetDev='' NextAction=0 Switched=0 Child='' Watchdog=''
}
nm_state() {
    [ -z "$1" ] || Phase=$1
    [ "$#" -lt 2 ] || Reason=$2
    local now wall
    now=$(nm_now); wall=$(date +%s)
    jq -n --arg modem "$Modem_ID" --arg interface "$NetDev" --arg phase "$Phase" \
        --arg connectivity "$Connectivity" --arg reason "$Reason" --arg last_action "$LastAction" \
        --argjson pid "$$" --argjson updated_at "$wall" --argjson heartbeat "$now" \
        --argjson failures "$Failures" --argjson action_failures "$ActionFailures" \
        --argjson primary_ok "$PrimaryOK" --argjson backup_ok "$BackupOK" \
        --argjson address_acquired "$Address" --argjson command_ok "$CommandOK" \
        --argjson next_action_at "$NextAction" \
        '{api_version:1,modem:$modem,interface:$interface,pid:$pid,phase:$phase,
          connectivity:$connectivity,reason:$reason,failures:$failures,
          action_failures:$action_failures,primary_ok:$primary_ok,backup_ok:$backup_ok,
          last_action:$last_action,address_acquired:$address_acquired,command_ok:$command_ok,
          next_action_at:$next_action_at,updated_at:$updated_at,heartbeat:$heartbeat}' \
        > "$NM_RUN/$Modem_ID.json.tmp.$$" && mv "$NM_RUN/$Modem_ID.json.tmp.$$" "$NM_RUN/$Modem_ID.json"
}
nm_status() {
    local enabled=false running=false state='{}' proc pid age stale=true profile
    [ "$(nm_get monitor_enabled 0)" = 1 ] && enabled=true
    profile=$(nm_get monitor_profile legacy)
    proc=$(ubus call service list '{"name":"qmodem_monitor"}' 2>/dev/null)
    pid=$(printf '%s' "$proc" | jq -r --arg i "m_$Modem_ID" '.qmodem_monitor.instances[$i] | select(.running == true) | .pid // empty')
    [ -z "$pid" ] || running=true
    [ ! -f "$NM_RUN/$Modem_ID.json" ] || state=$(jq -c 'select(type=="object")' "$NM_RUN/$Modem_ID.json" 2>/dev/null)
    [ -n "$state" ] || state='{}'
    age=$(printf '%s' "$state" | jq --argjson now "$(nm_now)" '$now-(.heartbeat // 0)')
    if [ "$running" = true ] && [ "$profile" = network_recovery ] &&
       [ "$(printf '%s' "$state" | jq -r '.pid // 0')" = "$pid" ] &&
       [ "$age" -ge 0 ] && [ "$age" -le 15 ]; then stale=false; fi
    printf '%s' "$state" | jq --argjson enabled "$enabled" --argjson running "$running" \
        --argjson stale "$stale" --argjson age "$age" --arg profile "$profile" \
        '. + {enabled:$enabled,running:$running,stale:$stale,age:$age,profile:$profile}
         | if $stale then .connectivity="unknown" else . end
         | if $profile != "network_recovery" then .phase="legacy" elif $enabled == false then .phase="disabled" else . end'
}
# A bounded child never retains the daemon flock. Heartbeat remains current
# during AT, netifd, ping and sleeps; stop interrupts the child before cleanup.
nm_run() {
    local limit=$1 deadline rc; shift
    "$@" 9>&- & Child=$!
    deadline=$(($(nm_now) + limit))
    while kill -0 "$Child" 2>/dev/null; do
        nm_state
        if [ "$(nm_now)" -ge "$deadline" ]; then
            nm_kill_tree "$Child"
            wait "$Child" 2>/dev/null
            Child=''
            return 124
        fi
        sleep 1
    done
    wait "$Child"; rc=$?; Child=''; return "$rc"
}
nm_sleep() {
    local end
    end=$(($(nm_now) + $1))
    while [ "$(nm_now)" -lt "$end" ]; do nm_state; sleep 1; done
}
nm_interface() {
    local info
    info=$(ubus call "network.interface.$Alias" status 2>/dev/null)
    NetDev=$(printf '%s' "$info" | jq -r '.l3_device // empty')
    Address=false
    [ "$(printf '%s' "$info" | jq -r '(.up == true) and ((.["ipv4-address"] // []) | length > 0)')" != true ] || Address=true
    case "$NetDev" in ''|*[!A-Za-z0-9_.:@-]*) NetDev=''; return 1;; esac
    [ -e "/sys/class/net/$NetDev" ]
}
nm_sample() {
    PrimaryOK=null BackupOK=null
    if ! nm_interface; then Reason=interface_unavailable; return 1; fi
    PrimaryOK=false
    if nm_run "$((Timeout+2))" ping -4 -c 1 -W "$Timeout" -w "$Timeout" -I "$NetDev" "$Primary" >/dev/null 2>&1; then PrimaryOK=true; return 0; fi
    if [ -n "$Backup" ]; then
        BackupOK=false
        if nm_run "$((Timeout+2))" ping -4 -c 1 -W "$Timeout" -w "$Timeout" -I "$NetDev" "$Backup" >/dev/null 2>&1; then BackupOK=true; return 0; fi
    fi
    Reason=targets_unreachable
    return 1
}
nm_at_command() {
    local rc
    # at() is the existing QModem transport, including ubus serialization.
    at "$AT_PORT" "$1" > "$NM_RUN/$Modem_ID.at" 2>/dev/null; rc=$?
    [ "$rc" = 0 ] || return "$rc"
    tr -d '\r' < "$NM_RUN/$Modem_ID.at" | awk 'NF {last=$0} END {exit(last != "OK")}'
}
nm_kill_tree() {
    local p=$1 child
    if [ -r "/proc/$p/task/$p/children" ]; then
        for child in $(cat "/proc/$p/task/$p/children"); do nm_kill_tree "$child"; done
    fi
    kill -TERM "$p" 2>/dev/null
    kill -KILL "$p" 2>/dev/null
    return 0
}
nm_cfun_on() {
    [ -f "$NM_INTENTS/$Modem_ID" ] || return 0
    nm_state recovering restoring_cfun
    if nm_run 20 nm_at_command 'AT+CFUN=1'; then
        rm -f "$NM_INTENTS/$Modem_ID"
        return 0
    fi
    nm_state error cfun_restore_failed
    return 1
}
nm_redial() {
    local off=1
    Address=false
    mkdir -p "$NM_INTENTS" || return 1
    # Durable only at recovery transitions, never on ordinary probe packets.
    printf '%s\n' pending > "$NM_INTENTS/$Modem_ID.tmp" &&
        mv "$NM_INTENTS/$Modem_ID.tmp" "$NM_INTENTS/$Modem_ID" || return 1
    sync
    nm_state recovering cfun_off
    nm_run 20 nm_at_command 'AT+CFUN=0' && off=0
    nm_sleep 1
    nm_cfun_on || return 1
    nm_state recovering restarting_dialer
    nm_run 30 "$NM_NET_SERVICE" redial "$Modem_ID" || return 1
    [ "$off" = 0 ]
}
nm_switch() {
    local caps slot target result payload
    payload=$(jq -nc --arg s "$Modem_ID" '{config_section:$s}')
    caps=$(ubus call qmodem get_sim_switch_capabilities "$payload" 2>/dev/null)
    [ "$(printf '%s' "$caps" | jq -r '.supportSwitch')" = 1 ] || return 2
    slot=$(ubus call qmodem get_sim_slot "$payload" 2>/dev/null | jq -r '.sim_slot // empty')
    [ -n "$slot" ] || return 1
    target=$(printf '%s' "$caps" | jq -r --arg s "$slot" '[.simSlots[]? | tostring | select(. != $s)][0] // empty')
    case "$target" in ''|*[!0-9]*) return 1;; esac
    payload=$(jq -nc --arg s "$Modem_ID" --arg t "$target" '{config_section:$s,slot:$t}')
    result=$(ubus call qmodem set_sim_slot "$payload" 2>/dev/null) || return 1
    printf '%s' "$result" | jq -e '.success == true and (.redial | tostring) == "0"' >/dev/null
}
nm_switch_supported() {
    local payload caps
    payload=$(jq -nc --arg s "$Modem_ID" '{config_section:$s}')
    caps=$(ubus call qmodem get_sim_switch_capabilities "$payload" 2>/dev/null) || return 1
    printf '%s' "$caps" | jq -e '(.supportSwitch | tostring) == "1" and (.simSlots | length) >= 2' >/dev/null
}
nm_choose_action() {
    case "$Action" in
        redial_then_switch) if [ "$ActionFailures" -ge "$N" ]; then LastAction=switch_sim_slot; else LastAction=redial; fi;;
        switch_then_redial) if [ "$Switched" = 1 ]; then LastAction=redial; else LastAction=switch_sim_slot; fi;;
        *) LastAction=$Action;;
    esac
}
nm_result() {
    if [ "$1" = online ]; then
        Connectivity=online Failures=0 ActionFailures=0 Switched=0
    else
        Connectivity=offline
        [ "$LastAction" != redial ] || ActionFailures=$((ActionFailures+1))
        [ "$LastAction" != switch_sim_slot ] || { ActionFailures=0; Switched=1; }
    fi
}
nm_guard() { [ ! -x "$NM_GUARD" ] || "$NM_GUARD" "$Modem_ID"; }
nm_probe_round() {
    Failures=0
    while [ "$Failures" -lt "$Packets" ]; do
        nm_state probing ''
        if nm_sample; then nm_result online; nm_state online probe_succeeded; return 0; fi
        Failures=$((Failures+1)); Connectivity=offline
        nm_state probing "$Reason"
        [ "$Failures" -ge "$Packets" ] || nm_sleep "$PacketInterval"
    done
    return 1
}
nm_cleanup() {
    trap '' INT TERM
    [ -z "$Child" ] || { nm_kill_tree "$Child"; wait "$Child" 2>/dev/null; Child=''; }
    # Preserve the intent if compensation fails; init also starts disabled
    # profiles with a pending intent so a service restart can finish it.
    nm_cfun_on
    Connectivity=unknown
    nm_state stopped stopped
    exit 0
}
nm_main() {
    case "$Modem_ID" in ''|*[!A-Za-z0-9_]*) return 1;; esac
    [ "$(uci -q get "qmodem.$Modem_ID")" = modem-device ] || return 1
    umask 077
    mkdir -p "$NM_RUN" || return 1
    exec 9>"$NM_RUN/$Modem_ID.lock"
    flock -n 9 || return 1
    nm_init_state
    trap nm_cleanup TERM INT
    # Restore radio functionality even if the newly saved probe config is bad.
    AT_PORT=$(nm_get at_port '')
    use_ubus_flag=''; [ "$(nm_get use_ubus 1)" = 1 ] && use_ubus_flag=-u
    while ! nm_cfun_on; do nm_sleep 10; done
    while ! nm_config; do nm_state error invalid_configuration; nm_sleep 5; done
    while ! nm_cfun_on; do nm_sleep 10; done
    [ "$Enabled" = 1 ] || { nm_state disabled disabled; return 0; }
    # Grace for initial registration; absence later counts as failure and can
    # recover a disappeared data interface instead of waiting forever.
    nm_state starting registration_grace
    nm_sleep "$Settle"
    while :; do
        if ! nm_guard; then Connectivity=unknown; nm_state error legacy_conflict; nm_sleep 5; continue; fi
        if ! nm_cfun_on; then Connectivity=unknown; nm_sleep 10; continue; fi
        if [ "$Action" != redial ] && ! nm_run 15 nm_switch_supported; then
            Connectivity=unknown; nm_state error sim_switch_unsupported; nm_sleep 15; continue
        fi
        if ! nm_probe_round; then
            # One action at most every 120 seconds (also persisted across a
            # process restart in /var/run; monotonic within this boot).
            NextAction=$(cat "$NM_RUN/$Modem_ID.next" 2>/dev/null)
            case "$NextAction" in ''|*[!0-9]*) NextAction=0;; esac
            if [ "$(nm_now)" -lt "$NextAction" ]; then nm_state cooldown rate_limited; nm_sleep 5; continue; fi
            if ! nm_guard; then nm_state error legacy_conflict; nm_sleep 5; continue; fi
            nm_choose_action
            NextAction=$(($(nm_now)+120)); printf '%s\n' "$NextAction" > "$NM_RUN/$Modem_ID.next"
            CommandOK=false
            nm_state recovering "$LastAction"
            case "$LastAction" in
                redial) nm_redial && CommandOK=true;;
                switch_sim_slot) nm_run 45 nm_switch && CommandOK=true;;
            esac
            nm_state settling waiting_registration
            nm_sleep "$Settle"
            if nm_sample && [ "$Address" = true ]; then nm_result online; nm_state online connectivity_verified
            else nm_result offline; nm_state offline recovery_not_verified; fi
        fi
        nm_sleep "$Interval"
    done
}

if [ "${NM_LIBRARY_ONLY:-0}" != 1 ]; then
    Modem_ID=$1
    if [ "$2" = status ]; then nm_status; exit $?; fi
    . /usr/share/qmodem/modem_util.sh
    nm_main
fi
