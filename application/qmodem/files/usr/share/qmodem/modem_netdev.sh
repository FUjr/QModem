#!/bin/sh
# Resolve the same USB/PCIe data endpoint before either bridge setup or dialing.
# Interface enumeration does not require an active SIM or a successful PDP.
instance="$1"
case "$instance" in ''|*[!A-Za-z0-9_]*) exit 2;; esac
path="$("${QMODEM_UCI:-uci}" -q get "qmodem.$instance.path")" || exit 1
path="$(readlink -f "$path")" || exit 1
[ -d "$path" ] && [ "$path" != / ] || exit 1
endpoints="$(find "$path" -name net -type d 2>/dev/null |
    while IFS= read -r netdir; do
        for entry in "$netdir"/*; do
            [ -e "$entry" ] || continue
            # QMI mux devices expose net/wwan0/net/wwan0_1. Use the
            # child data interface instead of counting its parent twice.
            [ ! -d "$entry/net" ] || continue
            printf '%s\n' "${entry##*/}"
        done
    done)"
# Independent endpoints remain ambiguous; never select by find order.
[ -n "$endpoints" ] || exit 1
[ "$(printf '%s\n' "$endpoints" | wc -l)" = 1 ] || exit 1
endpoint="$endpoints"
case "$endpoint" in ''|*[!A-Za-z0-9_.:-]*|lo|br-*|bqm*) exit 1;; esac
printf '%s\n' "$endpoint"
