#!/bin/sh
qmodem_sierra_completion(){ local out rc; out=$(qmodem_parser_completion "$1"); rc=$?; printf '%s' "$out"|jq -cS '.result=.response_text|del(.response_text)'; return "$rc"; }
qmodem_sierra_line(){ awk -v p="$1" '{sub(/\r$/,"");if(index($0,p)==1){x=substr($0,length(p)+1);sub(/^[[:space:]]*/,"",x);print x;exit}}'; }
qmodem_sierra_trim(){ xargs; }
qmodem_sierra_gstatus(){ awk -F'\t' '
 {for(i=1;i<=NF;i++){part=$i;sub(/\r$/, "", part);if(part~/^AT!GSTATUS|^!GSTATUS|^OK$/)continue;if(index(part,":")){key=part;sub(/:.*/,"",key);val=part;sub(/^.*:/,"",val);gsub(/^[ ]+|[ ]+$/,"",key);gsub(/^[ ]+|[ ]+$/,"",val);if(val!=""&&val!="---")printf "%s\034%s\n",key,val}}}
 ' | jq -Rsc 'split("\n")|map(select(length>0)|split("\u001c")|{key:.[0],value:.[1],kind:(if .[0]|test("SINR") then "sinr" elif .[0]|test("RSRP") then "rsrp" elif .[0]|test("RSRQ") then "rsrq" elif .[0]|test("RSSI") then "rssi" else "plain" end)})'
}
qmodem_sierra_band_list(){ awk '
 function maskid(mask, i,c,n){gsub(/[ \t]/,"",mask);n=length(mask);for(i=n;i>=1;i--){c=tolower(substr(mask,i,1));if(c!="0")return (n-i)*4+index("1248",c)}return ""}
 /^Available:/{on=1;next} !on||/^OK/{next}
 /^[0-9]+ - .*:/{type=$0;sub(/^[0-9]+ - /,"",type);sub(/:.*$/,"",type);next}
 type!=""&&/-/{mask=$0;sub(/-.*/,"",mask);name=$0;sub(/^.*-/,"",name);gsub(/^[ \t]+|[ \t\r]+$/,"",name);id=name;sub(/^[BbNn]/,"",id);if(type=="GW")id=maskid(mask);if(name!="")printf "%s\034%s\034%s\n",type,id,name}
 ' | jq -Rsc 'split("\n")|map(select(length>0)|split("\u001c")|{type:.[0],id:.[1],name:.[2]})|group_by(.type)|map({type:.[0].type,bands:map({id:.id,name:.name})})'
}
qmodem_sierra_band_config(){ awk '/^[0-9]+ - /{type=$3;sub(/:$/,"",type);gsub(/,/," ");low="";high="";for(i=1;i<=NF;i++){x=$i;gsub(/\r/,"",x);if(x~/^[0-9A-Fa-f]{16}$/){if(low=="")low=x;else if(high=="")high=x}}if(low!="")printf "%s\034%s\034%s\n",type,low,high}'|jq -Rsc 'split("\n")|map(select(length>0)|split("\u001c")|{type:.[0],low_mask:.[1],high_mask:.[2]})'; }
qmodem_sierra_parse(){
 local id="$1" raw value data; raw=$(cat)
 case "$id" in
  sierra.cgsn) value=$(printf '%s\n' "$raw"|grep -o '[0-9]\{15\}'|head -1); [ -n "$value" ]&&jq -cn --arg imei "$value" '{imei:$imei}';;
  sierra.usbcomp) a=$(printf '%s\n' "$raw"|sed -n 's/.*Config Type:  *\([0-9]\).*/\1/p'|head -1); value=$(printf '%s\n' "$raw"|sed -n 's/.*Interface bitmask: *\([0-9a-fA-Fx]*\).*/\1/p'|head -1); [ -n "$value" ]&&jq -cn --arg config_type "$a" --arg interface_mask "$value" '{config_type:$config_type,interface_mask:$interface_mask}';;
  sierra.selrat) value=$(printf '%s\n' "$raw"|sed -n 's/^!SELRAT: *\([0-9A-Fa-f]*\).*/\1/p'|head -1); [ -n "$value" ]&&jq -cn --arg code "$value" '{code:$code}';;
  sierra.uims) value=$(printf '%s\n' "$raw"|sed -n 's/^!UIMS: *\([0-9]*\).*/\1/p'|head -1); [ -n "$value" ]&&jq -cn --arg slot_index "$value" '{slot_index:$slot_index}';;
  sierra.cpin) value=$(printf '%s\n' "$raw"|qmodem_sierra_line '+CPIN:'); [ -n "$value" ]&&jq -cn --arg status "$(printf '%s' "$value"|tr A-Z a-z)" '{status:$status}';;
  sierra.cgmm) value=$(printf '%s\n' "$raw"|awk 'NR==2{sub(/\r$/,"");print;exit}'); [ -n "$value" ]&&jq -cn --arg name "$value" '{name:$name}';;
  sierra.cgmi) value=$(printf '%s\n' "$raw"|awk 'NR==2{sub(/\r$/,"");print;exit}'); [ -n "$value" ]&&jq -cn --arg manufacturer "$value" '{manufacturer:$manufacturer}';;
  sierra.ati) value=$(printf '%s\n' "$raw"|qmodem_sierra_line 'Revision:'); [ -n "$value" ]&&jq -cn --arg revision "$value" '{revision:$revision}';;
  sierra.gstatus) data=$(printf '%s\n' "$raw"|qmodem_sierra_gstatus); [ "$(printf '%s' "$data"|jq length)" -gt 0 ]&&jq -cn --argjson entries "$data" '{entries:$entries}'; value="$data";;
  sierra.band.config) data=$(printf '%s\n' "$raw"|qmodem_sierra_band_config); jq -cn --argjson configurations "$data" '{configurations:$configurations}'; value=x;;
  sierra.band.list) data=$(printf '%s\n' "$raw"|qmodem_sierra_band_list); jq -cn --argjson types "$data" '{types:$types}'; value=x;;
  sierra.pcvolt) value=$(printf '%s\n' "$raw"|sed -n 's/.*Power supply voltage: \([0-9]*\) mV.*/\1/p'|head -1); [ -n "$value" ]&&jq -cn --arg millivolts "$value" '{millivolts:$millivolts}';;
  sierra.pctemp) value=$(printf '%s\n' "$raw"|sed -n 's/.*Temperature: \([0-9]*\.[0-9]*\).*/\1/p'|head -1); [ -n "$value" ]&&jq -cn --arg celsius "$value" '{celsius:$celsius}';;
 esac
 [ -n "${value:-}" ]||{ qmodem_parser_error "$id" parse_failed; return 1; }
}
