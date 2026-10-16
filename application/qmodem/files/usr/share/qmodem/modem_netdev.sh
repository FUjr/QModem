#!/bin/sh
# Resolve the same USB/PCIe data endpoint before either bridge setup or dialing.
# Interface enumeration does not require an active SIM or a successful PDP.
instance="$1"
case "$instance" in ''|*[!A-Za-z0-9_]*) exit 2;; esac
path="$("${QMODEM_UCI:-uci}" -q get "qmodem.$instance.path")" || exit 1
path="$(readlink -f "$path")" || exit 1
[ -d "$path" ] && [ "$path" != / ] || exit 1
netdir="$(find "$path" -name net -type d 2>/dev/null)"
[ "$(printf '%s\n' "$netdir" | wc -l)" = 1 ] || exit 1
[ -n "$netdir" ] || exit 1
set -- "$netdir"/*
# Do not feed a whitespace-separated list into an interface-name argument.
[ "$#" = 1 ] && [ -e "$1" ] || exit 1
endpoint="${1##*/}"
case "$endpoint" in ''|*[!A-Za-z0-9_.:-]*|lo|br-*|bqm*) exit 1;; esac
printf '%s\n' "$endpoint"
