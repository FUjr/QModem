#!/bin/sh

parser_openluat_cesq()
{
    local values rsrq_raw rsrp_raw
    values=$(awk '
        /^[[:space:]]*\+CESQ[[:space:]]*:/ {
            line=$0
            sub(/^[[:space:]]*\+CESQ[[:space:]]*:[[:space:]]*/, "", line)
            if (split(line, fields, ",") < 6) exit
            gsub(/[[:space:]\r]/, "", fields[5])
            gsub(/[[:space:]\r]/, "", fields[6])
            if (fields[5] ~ /^[0-9]+$/ && fields[6] ~ /^[0-9]+$/)
                print fields[5] " " fields[6]
            exit
        }
    ')
    [ -n "$values" ] || {
        qmodem_parser_error "openluat.cesq" "parse_failed"
        return 1
    }
    set -- $values
    rsrq_raw=$1
    rsrp_raw=$2
    [ "$rsrq_raw" -le 34 ] && [ "$rsrp_raw" -le 97 ] || {
        qmodem_parser_error "openluat.cesq" "parse_failed"
        return 1
    }
    jq -cnS --argjson rsrq_raw "$rsrq_raw" --argjson rsrp_raw "$rsrp_raw" '
        {rsrq_db:(($rsrq_raw * 0.5) - 20),rsrp_dbm:($rsrp_raw - 141)}'
}
