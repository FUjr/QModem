#!/bin/sh

openluat_parse_prefixed()
{
    local parser_id="$1" prefix="$2" key="$3" value
    value=$(awk -v prefix="$prefix" '
        function clean(v) { sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v); if (v ~ /^".*"$/) { sub(/^"/, "", v); sub(/"$/, "", v) } return v }
        { line=$0; sub(/\r$/, "", line); sub(/^[[:space:]]+/, "", line)
          if (index(line,prefix)==1) { value=clean(substr(line,length(prefix)+1)); if (value!="" && value!~/^\+/) { print value; exit } waiting=1; next }
          if (waiting) { value=clean(line); if (value=="") next; if (value=="OK" || value=="ERROR" || value~/^\+/) exit; print value; exit } }')
    [ -n "$value" ] || { qmodem_parser_error "$parser_id" parse_failed; return 1; }
    qmodem_parser_string "$key" "$value"
}

parser_openluat_identity()
{
    local context="$3" prefix key
    prefix=$(printf '%s' "$context" | jq -r '.prefix // empty')
    key=$(printf '%s' "$context" | jq -r '.key // "value"')
    [ -n "$prefix" ] || { qmodem_parser_error openluat.identity invalid_context; return 2; }
    openluat_parse_prefixed openluat.identity "$prefix" "$key"
}

parser_openluat_number()
{
    local parser_id="$1" key="$2" min="$3" max="$4" value
    value=$(awk -v min="$min" -v max="$max" '{ line=$0; while (match(line,/[0-9]+/)) { v=substr(line,RSTART,RLENGTH); if (length(v)>=min && length(v)<=max) { print v; exit } line=substr(line,RSTART+RLENGTH) } }')
    [ -n "$value" ] || { qmodem_parser_error "$parser_id" parse_failed; return 1; }
    qmodem_parser_string "$key" "$value"
}

parser_openluat_cbc()
{
    local value
    value=$(awk '/^[[:space:]]*\+CBC[[:space:]]*:/ { line=$0; sub(/^[[:space:]]*\+CBC[[:space:]]*:[[:space:]]*/,"",line); n=split(line,f,","); v=f[3]; gsub(/[[:space:]\r]/,"",v); if(n==3 && v~/^[0-9]+$/ && v+0>0 && v+0<=10000) print v+0; exit }')
    [ -n "$value" ] || { qmodem_parser_error openluat.cbc parse_failed; return 1; }
    jq -cnS --argjson voltage_mv "$value" '{voltage_mv:$voltage_mv}'
}

parser_openluat_cops()
{
    local values operator rat
    values=$(awk -F',' '/^[[:space:]]*\+COPS:/ { op=$3; gsub(/^[[:space:]"]+|[[:space:]"\r]+$/,"",op); rat=$4; gsub(/[[:space:]"\r]/,"",rat); print op "\t" rat; exit }')
    [ -n "$values" ] || { qmodem_parser_error openluat.cops parse_failed; return 1; }
    operator=${values%%	*}; rat=${values#*	}
    jq -cnS --arg operator "$operator" --arg rat_code "$rat" '{operator:$operator,rat_code:$rat_code}'
}

parser_openluat_cnum()
{
    local value
    value=$(awk -F'"' '/^[[:space:]]*\+CNUM:/ { if($4!="") print $4; else print $2; exit }')
    [ -n "$value" ] || { qmodem_parser_error openluat.cnum parse_failed; return 1; }
    qmodem_parser_string number "$value"
}

parser_openluat_cpin()
{
    local value
    value=$(awk '{ line=$0; sub(/\r$/, "", line); if(line~/^[[:space:]]*\+(CPIN|CME ERROR):/) { sub(/^[[:space:]]*/,"",line); print line; exit } }')
    [ -n "$value" ] || { qmodem_parser_error openluat.cpin parse_failed; return 1; }
    qmodem_parser_string status_line "$value"
}

parser_openluat_csq()
{
    local value
    value=$(awk -F'[:,]' '/^[[:space:]]*\+CSQ:/ { v=$2; gsub(/[[:space:]\r]/,"",v); if(v~/^[0-9]+$/) print v; exit }')
    [ -n "$value" ] || { qmodem_parser_error openluat.csq parse_failed; return 1; }
    jq -cnS --argjson rssi_raw "$value" '{rssi_raw:$rssi_raw}'
}

parser_openluat_ctec()
{
    local value
    value=$(awk '/^[[:space:]]*\+CTEC[[:space:]]*:/ { line=$0; sub(/^[[:space:]]*\+CTEC[[:space:]]*:[[:space:]]*/,"",line); sub(/\r$/, "", line); n=split(line,f,","); for(i=1;i<=n;i++)gsub(/^[[:space:]]+|[[:space:]]+$/,"",f[i]); v=f[2]; if(v!~/^(0|2|4)$/)v=f[1]; if(v~/^(0|2|4)$/)print v; exit }')
    [ -n "$value" ] || { qmodem_parser_error openluat.ctec parse_failed; return 1; }
    jq -cnS --argjson mode "$value" '{mode:$mode}'
}

parser_openluat_setusb()
{
    local value
    value=$(awk '{ line=$0; sub(/\r$/, "", line); if(line~/^[[:space:]]*[Mm]ode:[[:space:]]*[12][[:space:]]*$/) { sub(/^[^:]*:[[:space:]]*/,"",line); gsub(/[[:space:]]/,"",line); print line; exit } }')
    [ -n "$value" ] || { qmodem_parser_error openluat.setusb parse_failed; return 1; }
    jq -cnS --argjson mode "$value" '{mode:$mode}'
}

parser_openluat_band()
{
    local values
    values=$(awk '/^[[:space:]]*[*]BAND[[:space:]]*:/ { line=$0; sub(/^[[:space:]]*[*]BAND[[:space:]]*:[[:space:]]*/,"",line); sub(/\r$/, "",line); n=split(line,f,","); if(n<8)exit; for(i=1;i<=8;i++){gsub(/^[[:space:]]+|[[:space:]]+$/,"",f[i]);if(f[i]!~/^[0-9]+$/)exit} printf "%s",f[1];for(i=2;i<=8;i++)printf ",%s",f[i];print "";exit }')
    [ -n "$values" ] || { qmodem_parser_error openluat.band parse_failed; return 1; }
    printf '%s' "$values" | awk -F, '{ printf "{\"mode\":%s,\"gsm_band\":%s,\"umts_band\":%s,\"lte_high\":%s,\"lte_low\":%s,\"roaming_config\":%s,\"srv_domain\":%s,\"priority\":%s}\n",$1,$2,$3,$4,$5,$6,$7,$8 }'
}

parser_openluat_cgcontrdp()
{
    local context="$3" cid line dns1 dns2
    cid=$(printf '%s' "$context" | jq -r '.cid // empty')
    [ -n "$cid" ] || { qmodem_parser_error openluat.cgcontrdp invalid_context; return 2; }
    line=$(awk -v cid="$cid" 'function clean(v){gsub(/^[[:space:]"]+|[[:space:]"]+$/,"",v);return v} function parse(s){n=split(s,f,",");if(n>=8&&clean(f[1])==cid){print clean(f[7]) "\t" clean(f[8]);return 1}} {line=$0;sub(/\r$/, "",line);if(line~/^[[:space:]]*\+CGCONTRDP:/){sub(/^[[:space:]]*\+CGCONTRDP:[[:space:]]*/,"",line);if(line==""){wait=1;next}if(parse(line))exit;next}if(wait){gsub(/^[[:space:]]+|[[:space:]]+$/,"",line);if(line=="")next;wait=0;if(line=="OK"||line=="ERROR"||line~/^\+/)next;if(parse(line))exit}}')
    [ -n "$line" ] || { qmodem_parser_error openluat.cgcontrdp parse_failed; return 1; }
    dns1=${line%%	*}; dns2=${line#*	}
    jq -cnS --arg ipv4_dns1 "$dns1" --arg ipv4_dns2 "$dns2" '{ipv4_dns1:$ipv4_dns1,ipv4_dns2:$ipv4_dns2}'
}
