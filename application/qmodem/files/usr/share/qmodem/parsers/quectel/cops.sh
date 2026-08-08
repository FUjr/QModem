#!/bin/sh

parser_quectel_cops_operator()
{
    local operator_code
    operator_code=$(awk -F'"' '/^[[:space:]]*\+COPS:/ { if ($2 != "") { print $2; exit } }')
    [ -n "$operator_code" ] || {
        qmodem_parser_error "quectel.cops.operator" "parse_failed"
        return 1
    }
    qmodem_parser_string "operator_code" "$operator_code"
}

parser_quectel_cops_rat()
{
    local rat_code
    rat_code=$(awk -F',' '
        /^[[:space:]]*\+COPS:/ {
            value=$4
            gsub(/[[:space:]\r"]/, "", value)
            if (value ~ /^[0-9]+$/) { print value; exit }
        }
    ')
    [ -n "$rat_code" ] || {
        qmodem_parser_error "quectel.cops.rat" "parse_failed"
        return 1
    }
    jq -cnS --argjson rat_code "$rat_code" '{rat_code:$rat_code}'
}
