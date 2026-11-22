#!/bin/sh

# Automatic APN selection shared by MBIM and QMI dial paths.
#
# The resolver is deliberately best-effort: callers keep their original APN
# and credentials when the modem, database, or parser is unavailable.

QMODEM_APN_DATABASE="${QMODEM_APN_DATABASE:-/usr/share/qmodem/apns.json}"

qmodem_apn_is_auto()
{
    [ -z "${1:-}" ] || [ "$1" = "auto" ]
}

qmodem_extract_imsi()
{
    awk '
        {
            candidate = $0
            gsub(/\r/, "", candidate)
            gsub(/[^0-9]/, "", candidate)
            if (length(candidate) >= 14 && length(candidate) <= 16) {
                print candidate
                exit
            }
        }
    '
}

qmodem_lookup_apn_record()
{
    local imsi="$1"
    local database="${2:-$QMODEM_APN_DATABASE}"
    local mcc mnc2 mnc3

    [ -r "$database" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1

    mcc=$(printf '%s' "$imsi" | cut -c1-3)
    mnc3=$(printf '%s' "$imsi" | cut -c4-6)
    mnc2=$(printf '%s' "$imsi" | cut -c4-5)
    [ "${#mcc}" -eq 3 ] && [ "${#mnc3}" -eq 3 ] &&
        [ "${#mnc2}" -eq 2 ] || return 1

    # Keep the lookup order compatible with the former C implementation:
    # first try the three-digit MNC, then retry using its first two digits.
    # In each pass the first database entry containing "default" wins.
    jq -ce --arg mcc "$mcc" --arg mnc3 "$mnc3" --arg mnc2 "$mnc2" '
        def candidates:
            ((.apns.apn? // [])[]?
                | select(type == "object")
                | ((._mcc? // "") | tostring) as $entry_mcc
                | ((._mnc? // "") | tostring) as $entry_mnc
                | ((._type? // "") | tostring) as $entry_type
                | select($entry_mcc == $mcc)
                | select($entry_type | contains("default"))
                | { record: ., mnc: $entry_mnc });

        ([candidates | select(.mnc == $mnc3)][0].record //
         [candidates | select((.mnc | length) >= 2 and
                              (.mnc | startswith($mnc2)))][0].record //
         empty)
    ' "$database" 2>/dev/null
}

qmodem_resolve_auto_apn()
{
    local port="$1"
    local database="${2:-$QMODEM_APN_DATABASE}"
    local response imsi record selected_apn selected_user selected_password

    qmodem_apn_is_auto "${apn:-}" || return 1

    response=$(cmd_dial_cimi_query "$port" 2>/dev/null) || return 1
    imsi=$(printf '%s\n' "$response" | qmodem_extract_imsi) || return 1
    [ -n "$imsi" ] || return 1

    record=$(qmodem_lookup_apn_record "$imsi" "$database") || return 1
    [ -n "$record" ] || return 1

    selected_apn=$(printf '%s\n' "$record" |
        jq -er '._apn | select(type == "string" and length > 0)' 2>/dev/null) || return 1
    selected_user=$(printf '%s\n' "$record" |
        jq -r 'if (._user | type) == "string" then ._user else "" end' 2>/dev/null) || return 1
    selected_password=$(printf '%s\n' "$record" |
        jq -r 'if (._password | type) == "string" then ._password else "" end' 2>/dev/null) || return 1

    # Commit results only after every required step succeeds. This keeps all
    # failure paths atomic and preserves the protocol's original dial flow.
    apn="$selected_apn"
    if [ -z "${username:-}" ] && [ -z "${password:-}" ] &&
       [ -n "$selected_user" ] && [ -n "$selected_password" ]; then
        username="$selected_user"
        password="$selected_password"
    fi

    return 0
}
