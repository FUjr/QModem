#!/bin/sh
qmodem_gosuncn_prefix(){ awk -v p="$1" '{sub(/\r$/,"");if(index($0,p)==1){x=substr($0,length(p)+1);sub(/^[[:space:]]*/,"",x);print x;exit}}'; }
qmodem_gosuncn_fields(){ awk -F, '{for(i=1;i<=NF;i++){gsub(/^[[:space:]]+|[[:space:]\r]+$/,"",$i);printf "%s%s",i==1?"":"\034",$i}exit}'|jq -Rsc 'split("\u001c")'; }
qmodem_gosuncn_parse(){
 local id="$1" raw value fields; raw=$(cat)
 case "$id" in
  gosuncn.cgsn) value=$(printf '%s\n' "$raw"|grep -o '[0-9]\{15\}'|head -1); [ -n "$value" ]&&jq -cn --arg imei "$value" '{imei:$imei}';;
  gosuncn.zswitch) value=$(printf '%s\n' "$raw"|qmodem_gosuncn_prefix '+ZSWITCH:'|cut -c1); [ -n "$value" ]&&jq -cn --arg mode "$value" '{mode:$mode}';;
  gosuncn.zsnt) value=$(printf '%s\n' "$raw"|qmodem_gosuncn_prefix '+ZSNT:'); fields=$(printf '%s' "$value"|qmodem_gosuncn_fields); [ -n "$value" ]&&jq -cn --argjson fields "$fields" '{cm_mode:($fields[0]//""),fields:$fields}';;
  gosuncn.mtsm) value=$(printf '%s\n' "$raw"|qmodem_gosuncn_prefix '+MTSM:'|tr -d ' '); [ -n "$value" ]&&jq -cn --arg temperature "$value" '{temperature:$temperature}';;
  gosuncn.zband) value=$(printf '%s\n' "$raw"|awk 'tolower($0)~/lte/{sub(/\r$/,"");sub(/^[^:]*:/,"");gsub(/ /,"");print;exit}'); [ -n "$value" ]&&jq -cn --arg lte "$value" '{lte:$lte}';;
  gosuncn.zband.list) value=$(printf '%s\n' "$raw"|awk 'tolower($0)~/lte/{sub(/\r$/,"");sub(/^[^:]*:/,"");gsub(/[() ]/,"");print;exit}'); [ -n "$value" ]&&jq -cn --arg lte "$value" '{lte:$lte}';;
  gosuncn.cpin) value=$(printf '%s\n' "$raw"|awk 'NR==2{sub(/\r$/,"");print;exit}'); [ -n "$value" ]&&jq -cn --arg status_line "$value" '{status_line:$status_line}';;
  gosuncn.cops) value=$(printf '%s\n' "$raw"|awk '/^\+COPS:/{sub(/\r$/,"");print;exit}'); [ -n "$value" ]&&jq -cn --arg operator "$(printf '%s' "$value"|awk -F\" '{print $2}')" --arg rat "$(printf '%s' "$value"|awk -F, '{print $4}')" '{operator:$operator,rat_code:$rat}';;
  gosuncn.cnum) value=$(printf '%s\n' "$raw"|awk '/^\+CNUM:/{if(match($0,/[0-9]{9,}/))print substr($0,RSTART,RLENGTH);exit}'); [ -n "$value" ]&&jq -cn --arg number "$value" '{number:$number}';;
  gosuncn.cimi) value=$(printf '%s\n' "$raw"|awk 'NR==2{sub(/\r$/,"");print;exit}'); [ -n "$value" ]&&jq -cn --arg imsi "$value" '{imsi:$imsi}';;
  gosuncn.iccid) value=$(printf '%s\n' "$raw"|sed -n 's/^+ICCID:[ ]*\([-0-9A-Fa-f]*\).*/\1/p'|head -1); [ -n "$value" ]&&jq -cn --arg iccid "$value" '{iccid:$iccid}';;
  gosuncn.cgmm) value=$(printf '%s\n' "$raw"|awk 'NR==2{sub(/\r$/,"");print;exit}'); [ -n "$value" ]&&jq -cn --arg name "$value" '{name:$name}';;
  gosuncn.cgmi) value=$(printf '%s\n' "$raw"|awk 'NR==2{sub(/\r$/,"");print;exit}'); [ -n "$value" ]&&jq -cn --arg manufacturer "$value" '{manufacturer:$manufacturer}';;
  gosuncn.cgmr) value=$(printf '%s\n' "$raw"|awk 'NR==2{sub(/\r$/,"");print;exit}'); [ -n "$value" ]&&jq -cn --arg revision "$value" '{revision:$revision}';;
  gosuncn.csq) value=$(printf '%s\n' "$raw"|qmodem_gosuncn_prefix '+CSQ:'); fields=$(printf '%s' "$value"|qmodem_gosuncn_fields); [ -n "$value" ]&&jq -cn --argjson f "$fields" '{rssi_code:($f[0]//""),ber_code:($f[1]//"")}';;
  gosuncn.cesq) value=$(printf '%s\n' "$raw"|qmodem_gosuncn_prefix '+CESQ:'); fields=$(printf '%s' "$value"|qmodem_gosuncn_fields); [ -n "$value" ]&&jq -cn --argjson f "$fields" '{rxlev_code:($f[0]//""),ber_code:($f[1]//""),rscp_code:($f[2]//""),ecno_code:($f[3]//""),rsrq_code:($f[4]//""),rsrp_code:($f[5]//"")}';;
  gosuncn.zcellinfo) value=$(printf '%s\n' "$raw"|qmodem_gosuncn_prefix '+ZCELLINFO:'); fields=$(printf '%s' "$value"|qmodem_gosuncn_fields); [ -n "$value" ]&&jq -cn --argjson f "$fields" 'if ($f[0]|startswith("tac:")) then {tac:($f[0]|sub("^tac:";"")),cell_id:($f[1]|sub("^cellid:";"")),pci:($f[2]|sub("^pci:";"")),band:($f[3]|sub("^band:";""))} else {tac:$f[0],cell_id:$f[1],pci:$f[2],band:$f[3]} end';;
 esac
 [ -n "${value:-}${fields:-}" ]||{ qmodem_parser_error "$id" parse_failed; return 1; }
}
