#!/bin/sh

parser_quectel_qcfg_value()
{
    local context="$3" name value
    name=$(printf '%s' "$context" | jq -r '.name // empty')
    [ -n "$name" ] || { qmodem_parser_error quectel.qcfg.value invalid_context; return 2; }
    value=$(awk -F',' -v name="$name" '/^[[:space:]]*\+QCFG:/ { head=$1; gsub(/[[:space:]"]/,"",head); if(head=="+QCFG:" name){v=$2;gsub(/[[:space:]"\r]/,"",v);print v;exit} }')
    [ -n "$value" ] || { qmodem_parser_error quectel.qcfg.value parse_failed; return 1; }
    qmodem_parser_string value "$value"
}

parser_quectel_5glan()
{
    local value
    value=$(awk -F',' '/^[[:space:]]*\+QCFG:[[:space:]]*"5glan",/ {v=$3;gsub(/[[:space:]\r]/,"",v);if(v~/^[01]$/)print v;exit}')
    [ -n "$value" ] || { qmodem_parser_error quectel.qcfg.5glan parse_failed; return 1; }
    jq -cnS --argjson enabled "$value" '{enabled:$enabled}'
}

parser_quectel_qnwprefcfg_value()
{
    local context="$3" name value
    name=$(printf '%s' "$context" | jq -r '.name // empty')
    [ -n "$name" ] || { qmodem_parser_error quectel.qnwprefcfg.value invalid_context; return 2; }
    value=$(awk -F',' -v name="$name" '/^[[:space:]]*\+QNWPREFCFG:/ { head=$1;gsub(/[[:space:]"]/,"",head);if(head=="+QNWPREFCFG:" name){v=$2;gsub(/[[:space:]"\r]/,"",v);print v;exit} }')
    [ -n "$value" ] || { qmodem_parser_error quectel.qnwprefcfg.value parse_failed; return 1; }
    qmodem_parser_string value "$value"
}

parser_quectel_line()
{
    local context="$3" prefix key value
    prefix=$(printf '%s' "$context" | jq -r '.prefix // empty')
    key=$(printf '%s' "$context" | jq -r '.key // "value"')
    [ -n "$prefix" ] || { qmodem_parser_error quectel.line invalid_context; return 2; }
    value=$(awk -v prefix="$prefix" '{line=$0;sub(/\r$/, "",line);if(index(line,prefix)==1){sub("^" prefix "[[:space:]]*","",line);gsub(/^"|"$/,"",line);print line;exit}}')
    [ -n "$value" ] || { qmodem_parser_error quectel.line parse_failed; return 1; }
    qmodem_parser_string "$key" "$value"
}

parser_quectel_second_line()
{
    local context="$3" key value
    key=$(printf '%s' "$context" | jq -r '.key // "value"')
    value=$(awk '{line=$0;sub(/\r$/, "",line);if(line==""||line~/^AT[+^*]?/||line=="OK"||line=="ERROR")next;print line;exit}')
    [ -n "$value" ] || { qmodem_parser_error quectel.second_line parse_failed; return 1; }
    qmodem_parser_string "$key" "$value"
}

parser_quectel_cpin()
{
    local value
    value=$(awk '{line=$0;sub(/\r$/, "",line);if(line~/^[[:space:]]*\+(CPIN|CME ERROR):/){sub(/^[[:space:]]*/,"",line);print line;exit}}')
    [ -n "$value" ] || { qmodem_parser_error quectel.cpin parse_failed; return 1; }
    qmodem_parser_string status_line "$value"
}

parser_quectel_cnum()
{
    local value
    value=$(awk -F'"' '/^[[:space:]]*\+CNUM:/ {if($4!="")print $4;else print $2;exit}')
    [ -n "$value" ] || { qmodem_parser_error quectel.cnum parse_failed; return 1; }
    qmodem_parser_string number "$value"
}

parser_quectel_iccid()
{
    local value
    value=$(awk '/^[[:space:]]*\+(ICCID|CCID):/ {line=$0;sub(/^[^:]*:[[:space:]]*/,"",line);sub(/\r$/, "",line);if(line~/^[-0-9A-F]+$/){print line;exit}}')
    [ -n "$value" ] || { qmodem_parser_error quectel.iccid parse_failed; return 1; }
    qmodem_parser_string iccid "$value"
}

parser_quectel_csq()
{
    local values
    values=$(awk -F'[:,]' '/^[[:space:]]*\+CSQ:/ {a=$2;b=$3;gsub(/[[:space:]\r]/,"",a);gsub(/[[:space:]\r]/,"",b);if(a~/^[0-9]+$/&&b~/^[0-9]+$/)print a " " b;exit}')
    [ -n "$values" ] || { qmodem_parser_error quectel.csq parse_failed; return 1; }
    set -- $values
    jq -cnS --argjson rssi_raw "$1" --argjson ber "$2" '{rssi_raw:$rssi_raw,ber:$ber}'
}

parser_quectel_qnwinfo()
{
    local value
    value=$(awk -F'"' '/^[[:space:]]*\+QNWINFO:/ {if($2!=""){print $2;exit}}')
    [ -n "$value" ] || { qmodem_parser_error quectel.qnwinfo parse_failed; return 1; }
    qmodem_parser_string network_type "$value"
}

parser_quectel_qtemp()
{
    local values
    values=$(awk '/^[[:space:]]*\+QTEMP:/ {line=$0;while(match(line,/[0-9]+/)){v=substr(line,RSTART,RLENGTH)+0;if(v>10&&v<110)print v;line=substr(line,RSTART+RLENGTH)}}')
    [ -n "$values" ] || { qmodem_parser_error quectel.qtemp parse_failed; return 1; }
    printf '%s\n' "$values" | jq -RscS '{temperatures_c:(split("\n")|map(select(length>0)|tonumber))}'
}

parser_quectel_cbc()
{
    local value
    value=$(awk -F',' '/^[[:space:]]*\+CBC:/ {v=$3;gsub(/[[:space:]\r]/,"",v);if(v~/^[0-9]+$/)print v;exit}')
    [ -n "$value" ] || { qmodem_parser_error quectel.cbc parse_failed; return 1; }
    jq -cnS --argjson voltage_mv "$value" '{voltage_mv:$voltage_mv}'
}

parser_quectel_sim_slot()
{
    local value
    value=$(awk -F':' '/\+(QUIMSLOT|QUSIMSLOT):/ {v=$2;gsub(/[^0-9]/,"",v);if(v=="1"||v=="2"){print v;exit}}')
    [ -n "$value" ] || { qmodem_parser_error quectel.sim_slot parse_failed; return 1; }
    jq -cnS --argjson slot "$value" '{slot:$slot}'
}

parser_quectel_qnwcfg()
{
    jq -RscS '
      def clean: gsub("^[[:space:]\\\"]+|[[:space:]\\\"\\r]+$"; "");
      [split("\n")[] | select(test("^[[:space:]]*\\+QNWCFG:")) |
       sub("^[[:space:]]*\\+QNWCFG:[[:space:]]*"; "") | split(",") | map(clean)] as $r |
      if ($r|length)==0 then error("parse_failed") else
       {records:($r|map({name:.[0],values:.[1:]})),
        updown:($r|map(select(.[0]=="up/down")|{tx_rate:.[1],rx_rate:.[2]})|first // null),
        nr5g_ambr:($r|map(select(.[0]=="nr5g/ambr")|{context:.[1],cqi_dl:.[2],ambr_dl:.[3],cqi_ul:.[4],ambr_ul:.[5]}) )}
      end' 2>/dev/null || { qmodem_parser_error quectel.qnwcfg parse_failed; return 1; }
}
