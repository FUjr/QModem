#!/bin/sh
qmodem_neoway_prefix(){ awk -v p="$1" '{sub(/\r$/,"");if(index($0,p)==1){x=substr($0,length(p)+1);sub(/^[[:space:]]*/,"",x);print x;exit}}'; }
qmodem_neoway_fields(){ awk -F, '{for(i=1;i<=NF;i++){gsub(/^[[:space:]"]+|[[:space:]"\r]+$/,"",$i);printf "%s%s",i==1?"":"\034",$i}exit}'|jq -Rsc 'split("\u001c")'; }
qmodem_neoway_parse(){
 local id="$1" raw value fields; raw=$(cat)
 case "$id" in
  neoway.cgsn) value=$(printf '%s\n' "$raw"|grep -o '[0-9]\{15\}'|head -1); [ -n "$value" ]&&jq -cn --arg imei "$value" '{imei:$imei}';;
  neoway.mysysinfo) value=$(printf '%s\n' "$raw"|qmodem_neoway_prefix '$MYSYSINFO:'|awk -F, '{print $1}'|awk '{print $1}'); [ -n "$value" ]&&jq -cn --arg mode "$value" '{mode:$mode}';;
  neoway.cgmm) value=$(printf '%s\n' "$raw"|awk 'NR==2{sub(/\r$/,"");print;exit}'); [ -n "$value" ]&&jq -cn --arg name "$value" '{name:$name}';;
  neoway.cgmi) value=$(printf '%s\n' "$raw"|qmodem_neoway_prefix '+CGMI:'); [ -n "$value" ]&&jq -cn --arg manufacturer "$value" '{manufacturer:$manufacturer}';;
  neoway.ati) value=$(printf '%s\n' "$raw"|awk 'NR==5{sub(/\r$/,"");print;exit}'); [ -n "$value" ]&&jq -cn --arg revision "$value" '{revision:$revision}';;
  neoway.simcross) value=$(printf '%s\n' "$raw"|qmodem_neoway_prefix '+SIMCROSS:'|awk -F'[ ,]' '{print $1}'); [ -n "$value" ]&&jq -cn --arg slot "$value" '{slot:$slot}';;
  neoway.cpin) value=$(printf '%s\n' "$raw"|awk 'NR==3{sub(/\r$/,"");print;exit}'); [ -n "$value" ]&&jq -cn --arg status_line "$value" '{status_line:$status_line}';;
  neoway.cops) value=$(printf '%s\n' "$raw"|awk 'NR==2{sub(/\r$/,"");print;exit}'); [ -n "$value" ]&&jq -cn --arg operator "$(printf '%s' "$value"|awk -F\" '{print $2}')" '{operator:$operator}';;
  neoway.cnum) value=$(printf '%s\n' "$raw"|awk 'NR==3{sub(/\r$/,"");print;exit}'); [ -n "$value" ]&&jq -cn --arg number "$(printf '%s' "$value"|awk -F\" '{print $4}')" '{number:$number}';;
  neoway.cimi) value=$(printf '%s\n' "$raw"|awk 'NR==3{sub(/\r$/,"");print;exit}'); [ -n "$value" ]&&jq -cn --arg imsi "$value" '{imsi:$imsi}';;
  neoway.myccid) value=$(printf '%s\n' "$raw"|qmodem_neoway_prefix '$MYCCID:'|awk -F' "' '{gsub(/"/,"",$2);print $2}'); [ -n "$value" ]&&jq -cn --arg iccid "$value" '{iccid:$iccid}';;
  neoway.csq) value=$(printf '%s\n' "$raw"|qmodem_neoway_prefix '+CSQ:'); [ -n "$value" ]&&jq -cn --arg value "$value" '{value:$value}';;
  neoway.c5gqosrdp) value=$(printf '%s\n' "$raw"|qmodem_neoway_prefix '+C5GQOSRDP:'); fields=$(printf '%s' "$value"|qmodem_neoway_fields); [ -n "$value" ]&&jq -cn --argjson f "$fields" '{cid:($f[0]//""),five_qi:($f[1]//""),dl_gfbr:($f[2]//""),ul_gfbr:($f[3]//""),dl_mfbr:($f[4]//""),ul_mfbr:($f[5]//""),dl_sambr:($f[6]//""),ul_sambr:($f[7]//""),averaging_window:($f[8]//"")}';;
  neoway.nwsetband) value=$(printf '%s\n' "$raw"|qmodem_neoway_prefix '+NWSETBAND:'); [ -n "$value" ]&&jq -cn --arg value "$value" '{band_number:($value|split(" ")[0]),value:$value}';;
  neoway.nwsetband.list) fields=$(printf '%s\n' "$raw" | awk -F',' '/^\+NWSETBAND:/{for(i=2;i<=NF;i++){gsub(/[[:space:]\r]/,"",$i);if(length($i))print $i}}' | jq -Rsc '[splits("\n")|select(length>0)]'); [ "$fields" != "[]" ]&&jq -cn --argjson fields "$fields" '{available_bands:$fields}';;
  neoway.netdmsgex) value=$(printf '%s\n' "$raw"|qmodem_neoway_prefix '+NETDMSGEX:'); fields=$(printf '%s' "$value"|qmodem_neoway_fields); [ -n "$value" ]&&jq -cn --argjson f "$fields" '{net_mode:($f[0]//""),plmn:($f[1]//""),mcc:(($f[1]//"")|split("+")[0]),mnc:(($f[1]//"")|split("+")[1]//""),band:($f[2]//""),arfcn:($f[3]//""),nr:{gnbid:($f[4]//""),pci:($f[5]//""),ss_rsrp_tenth:($f[6]//""),ss_rsrq_tenth:($f[7]//""),ss_sinr_tenth:($f[8]//"")},lte:{tac:($f[4]//""),cell_id:($f[5]//""),pci:($f[6]//""),rx_dbm:($f[7]//""),tx_dbm:($f[8]//""),rsrp_tenth:($f[9]//""),rsrq_tenth:($f[10]//""),sinr_tenth:($f[11]//""),rssi_tenth:($f[12]//""),dl_bw_code:($f[16]//""),ul_bw_code:($f[17]//"")},wcdma:{lac:($f[4]//""),cell_id:($f[5]//""),psc:($f[6]//""),rac:($f[7]//""),rx_dbm:($f[8]//""),tx_dbm:($f[9]//""),rscp_tenth:($f[10]//""),ecio_tenth:($f[11]//""),rssi:($f[12]//""),srxlev:($f[13]//""),squal:($f[14]//""),phych_code:($f[15]//""),sf_code:($f[16]//""),slot_code:($f[17]//""),compression_mode:($f[18]//"")}}';;
 esac
 [ -n "${value:-}${fields:-}" ]||{ qmodem_parser_error "$id" parse_failed; return 1; }
}
