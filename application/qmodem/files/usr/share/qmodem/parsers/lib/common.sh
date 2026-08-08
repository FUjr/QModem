#!/bin/sh

qmodem_parser_error()
{
    local parser_id="$1" code="$2"
    jq -cnS --arg code "$code" --arg parser "$parser_id" \
        '{error:{code:$code,parser:$parser}}'
}

qmodem_parser_string()
{
    local key="$1" value="$2"
    jq -cnS --arg key "$key" --arg value "$value" '{($key):$value}'
}

qmodem_parser_completion()
{
    local parser_id="$1" response final accepted error_code

    response=$(cat)
    final=$(printf '%s\n' "$response" | awk '
        {
            line=$0
            sub(/\r$/, "", line)
            if (line == "OK" || line == "ERROR" ||
                line ~ /^\+CME ERROR:/ || line ~ /^\+CMS ERROR:/)
                result=line
        }
        END { if (result != "") print result }
    ')
    [ -n "$final" ] || {
        qmodem_parser_error "$parser_id" "parse_failed"
        return 1
    }

    accepted=false
    error_code=""
    if [ "$final" = "OK" ]; then
        accepted=true
    else
        error_code=$(printf '%s\n' "$final" | sed -n 's/^+C[MMS][E ]*ERROR:[[:space:]]*//p')
    fi
    jq -cnS \
        --argjson accepted "$accepted" \
        --arg final "$final" \
        --arg error_code "$error_code" \
        --arg result "$response" \
        '{accepted:$accepted,final:$final,result:$result}
         + if $error_code == "" then {} else {error_code:$error_code} end'
}
