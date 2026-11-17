#!/bin/sh
# Resolve the same USB/PCIe data endpoint before either bridge setup or dialing.
# Interface enumeration does not require an active SIM or a successful PDP.
instance="$1"
case "$instance" in ''|*[!A-Za-z0-9_]*) exit 2;; esac
path="$("${QMODEM_UCI:-uci}" -q get "qmodem.$instance.path")" || exit 1
path="$(readlink -f "$path")" || exit 1
[ -d "$path" ] && [ "$path" != / ] || exit 1
# Find independent USB/PCIe endpoint directories without counting mux children.
netdir="$(find "$path" -type d -name net ! -path "*/mhi*_IP_SW*/net" -print -prune 2>/dev/null)"
[ "$(printf '%s\n' "$netdir" | wc -l)" = 1 ] || exit 1
[ -n "$netdir" ] || exit 1
while :; do
    set -- "$netdir"/*
    # Every level must identify one data interface, including QMI mux children.
    [ "$#" = 1 ] && [ -d "$1" ] && [ ! -L "$1" ] || exit 1
    endpoint="${1##*/}"
    case "$endpoint" in ''|*[!A-Za-z0-9_.:-]*|lo|br-*|bqm*) exit 1;; esac
    # Do not follow sysfs backlinks or accept a malformed nested endpoint.
    [ ! -L "$1/net" ] || exit 1
    [ -e "$1/net" ] || break
    [ -d "$1/net" ] || exit 1
    netdir="$1/net"
done
printf '%s\n' "$endpoint"
