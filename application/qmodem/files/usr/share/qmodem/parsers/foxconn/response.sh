#!/bin/sh
qmodem_foxconn_trim(){ xargs; }
qmodem_foxconn_line(){ awk -v p="$1" '{sub(/\r$/,"");if(index($0,p)==1){x=substr($0,length(p)+1);sub(/^[[:space:]]*/,"",x);print x;exit}}'; }
qmodem_foxconn_label(){ awk -v p="$1" '{if((n=index($0,p))){x=substr($0,n+length(p));sub(/\r$/, "", x);print x;exit}}'; }
qmodem_foxconn_first(){ awk '{print $1;exit}'; }
qmodem_foxconn_average(){ awk '{while(match($0,/[-+]?[0-9]+([.][0-9]+)?/)){sum+=substr($0,RSTART,RLENGTH);n++;$0=substr($0,RSTART+RLENGTH)}}END{if(n)printf "%.2f",sum/n}'; }
qmodem_foxconn_band_array(){ awk -v key="$1" 'index($0,key){sub(/^.*:/,"");gsub(/[ \r]/,"");print;exit}'|awk -F, '{for(i=1;i<=NF;i++)if($i!="")print $i}'|jq -Rsc 'split("\n")|map(select(length>0))'; }
qmodem_foxconn_completion(){ local output rc; output=$(qmodem_parser_completion "$1"); rc=$?; printf '%s' "$output"|jq -cS '.result=.response_text|del(.response_text)'; return "$rc"; }
qmodem_foxconn_parse(){
 local id="$1" raw value a b c d e f g h i j k l m n o p; raw=$(cat)
 case "$id" in
  foxconn.ati) a=$(printf '%s\n' "$raw"|qmodem_foxconn_line 'IMEI:'|qmodem_foxconn_trim); b=$(printf '%s\n' "$raw"|qmodem_foxconn_line 'Manufacturer:'|qmodem_foxconn_trim); c=$(printf '%s\n' "$raw"|qmodem_foxconn_line 'Revision:'|qmodem_foxconn_trim); [ -n "$a$b$c" ]&&jq -cn --arg imei "$a" --arg manufacturer "$b" --arg revision "$c" '{imei:$imei,manufacturer:$manufacturer,name:$manufacturer,revision:$revision}'; value="$a$b$c";;
  foxconn.pciemode) value=$(printf '%s\n' "$raw"|grep -o '[0-9]'|tr -d '\n'); [ -n "$value" ]&&jq -cn --arg config_type "$value" '{config_type:$config_type}';;
  foxconn.usbswitch) value=$(printf '%s\n' "$raw"|qmodem_foxconn_line 'USBSWITCH:'|qmodem_foxconn_trim); [ -n "$value" ]&&jq -cn --arg config_type "$value" '{config_type:$config_type}';;
  foxconn.slmode) value=$(printf '%s\n' "$raw"|grep -o '[0-9]\+'|tr -d '\n '); [ -n "$value" ]&&jq -cn --arg code "$value" '{code:$code}';;
  foxconn.switch_slot) value=$(printf '%s\n' "$raw"|awk '/ENABLE/{if(match($0,/SIM[0-9]+/))print substr($0,RSTART,RLENGTH);exit}'); [ -n "$value" ]&&jq -cn --arg slot "$value" '{slot:$slot}';;
  foxconn.cpin) value=$(printf '%s\n' "$raw"|qmodem_foxconn_line '+CPIN:'); [ -n "$value" ]&&jq -cn --arg status "$(printf '%s' "$value"|tr A-Z a-z)" '{status:$status}';;
  foxconn.cops) value=$(printf '%s\n' "$raw"|awk 'NR==2{sub(/\r$/,"");print;exit}'); [ -n "$value" ]&&jq -cn --arg operator "$(printf '%s' "$value"|awk -F\" '{print $2}')" --arg rat "$(printf '%s' "$value"|awk -F, '{print $4}')" '{operator:$operator,rat_code:$rat}';;
  foxconn.cnum) value=$(printf '%s\n' "$raw"|awk -F\" '/^\+CNUM:/{print $2;exit}'|qmodem_foxconn_trim); [ -n "$value" ]&&jq -cn --arg number "$value" '{number:$number}';;
  foxconn.cimi) value=$(printf '%s\n' "$raw"|awk 'NR==2{sub(/\r$/,"");print;exit}'); [ -n "$value" ]&&jq -cn --arg imsi "$value" '{imsi:$imsi}';;
  foxconn.iccid) value=$(printf '%s\n' "$raw"|awk 'NR==2{gsub(/[^0-9]/,"");print;exit}'); [ -n "$value" ]&&jq -cn --arg iccid "$value" '{iccid:$iccid}';;
  foxconn.band_pref) a=$(printf '%s\n' "$raw"|qmodem_foxconn_band_array 'WCDMA,Enable Bands'); b=$(printf '%s\n' "$raw"|qmodem_foxconn_band_array 'WCDMA,Disable Bands'); c=$(printf '%s\n' "$raw"|qmodem_foxconn_band_array 'LTE,Enable Bands'); d=$(printf '%s\n' "$raw"|qmodem_foxconn_band_array 'LTE,Disable Bands'); e=$(printf '%s\n' "$raw"|qmodem_foxconn_band_array 'NR5G_NSA,Enable Bands'); f=$(printf '%s\n' "$raw"|qmodem_foxconn_band_array 'NR5G_NSA,Disable Bands'); g=$(printf '%s\n' "$raw"|qmodem_foxconn_band_array 'NR5G_SA,Enable Bands'); h=$(printf '%s\n' "$raw"|qmodem_foxconn_band_array 'NR5G_SA,Disable Bands'); jq -cn --argjson we "$a" --argjson wd "$b" --argjson le "$c" --argjson ld "$d" --argjson ne "$e" --argjson nd "$f" --argjson se "$g" --argjson sd "$h" '{wcdma:{enabled:$we,disabled:$wd},lte:{enabled:$le,disabled:$ld},nr_nsa:{enabled:$ne,disabled:$nd},nr_sa:{enabled:$se,disabled:$sd}}'; value=x;;
  foxconn.pcvolt) value=$(printf '%s\n' "$raw"|sed -n 's/.*Power supply voltage: \([0-9]*\) mV.*/\1/p'|head -1); [ -n "$value" ]&&jq -cn --arg millivolts "$value" '{millivolts:$millivolts}';;
  foxconn.temp) value=$(printf '%s\n' "$raw"|sed -n 's/.*TSENS: \([0-9]*\)C.*/\1/p'|head -1); [ -n "$value" ]&&jq -cn --arg celsius "$value" '{celsius:$celsius}';;
  foxconn.debug)
   a=$(printf '%s\n' "$raw"|qmodem_foxconn_label 'RAT:'|qmodem_foxconn_trim)
   b=$(printf '%s\n' "$raw"|qmodem_foxconn_label 'mcc:'|awk -F, '{print $1}'|qmodem_foxconn_trim); c=$(printf '%s\n' "$raw"|qmodem_foxconn_label 'mnc:'|qmodem_foxconn_trim)
   d=$(printf '%s\n' "$raw"|qmodem_foxconn_label 'channel:'|qmodem_foxconn_first|qmodem_foxconn_trim); e=$(printf '%s\n' "$raw"|qmodem_foxconn_label 'pci:'|qmodem_foxconn_first|qmodem_foxconn_trim)
   if [ "$a" = LTE ]; then
    f=$(printf '%s\n' "$raw"|qmodem_foxconn_label 'lte_cell_id:'|qmodem_foxconn_trim); g=$(printf '%s\n' "$raw"|qmodem_foxconn_label 'lte_band:'|qmodem_foxconn_first); h=$(printf '%s\n' "$raw"|qmodem_foxconn_label 'lte_band_width:'|qmodem_foxconn_trim); i=$(printf '%s\n' "$raw"|qmodem_foxconn_label 'lte_snr:'|qmodem_foxconn_first|qmodem_foxconn_average); j=$(printf '%s\n' "$raw"|qmodem_foxconn_label 'rsrq:'|qmodem_foxconn_average); k=$(printf '%s\n' "$raw"|qmodem_foxconn_label 'lte_rssi:'|awk -F, '{print $1}'|qmodem_foxconn_average); l=$(printf '%s\n' "$raw"|qmodem_foxconn_label 'lte_tac:'|qmodem_foxconn_trim); m=$(printf '%s\n' "$raw"|qmodem_foxconn_label 'lte_tx_pwr:'|qmodem_foxconn_trim)
    jq -cn --arg mode "$a" --arg mcc "$b" --arg mnc "$c" --arg channel "$d" --arg pci "$e" --arg cell "$f" --arg band "$g" --arg bw "$h" --arg sinr "$i" --arg rsrq "$j" --arg rssi "$k" --arg tac "$l" --arg tx "$m" '{network_mode:$mode,mcc:$mcc,mnc:$mnc,earfcn:$channel,pci:$pci,cell_id:$cell,band:$band,band_width:$bw,sinr:$sinr,rsrq:$rsrq,rssi:$rssi,tac:$tac,tx_power:$tx,has_ca:false}'
   else
    f=$(printf '%s\n' "$raw"|qmodem_foxconn_label 'nr_cell_id:'|qmodem_foxconn_trim); g=$(printf '%s\n' "$raw"|qmodem_foxconn_label 'nr_band:'|qmodem_foxconn_first); h=$(printf '%s\n' "$raw"|qmodem_foxconn_label 'nr_band_width:'|qmodem_foxconn_first); i=$(printf '%s\n' "$raw"|qmodem_foxconn_label 'nr_snr:'|qmodem_foxconn_first|qmodem_foxconn_average); j=$(printf '%s\n' "$raw"|qmodem_foxconn_label 'rsrq:'|qmodem_foxconn_average); k=$(printf '%s\n' "$raw"|qmodem_foxconn_label 'rsrp:'|qmodem_foxconn_first|qmodem_foxconn_average); l=$(printf '%s\n' "$raw"|qmodem_foxconn_label 'nr_rssi:'|awk -F, '{print $1}'|qmodem_foxconn_average); m=$(printf '%s\n' "$raw"|qmodem_foxconn_label 'nr_tac:'|qmodem_foxconn_trim); n=$(printf '%s\n' "$raw"|qmodem_foxconn_label 'nr_tx_pwr:'|qmodem_foxconn_trim); o=$(printf '%s\n' "$raw"|awk '/nr_scc1:/{f=1;next}f'|qmodem_foxconn_label 'nr_band:'|qmodem_foxconn_first); p=$(printf '%s\n' "$raw"|awk '/nr_scc1:/{f=1;next}f'|qmodem_foxconn_label 'nr_band_width:'|qmodem_foxconn_first)
    jq -cn --arg mode "$a" --arg mcc "$b" --arg mnc "$c" --arg channel "$d" --arg pci "$e" --arg cell "$f" --arg band "$g" --arg bw "$h" --arg sinr "$i" --arg rsrq "$j" --arg rsrp "$k" --arg rssi "$l" --arg tac "$m" --arg tx "$n" --arg sb "$o" --arg sw "$p" '{network_mode:$mode,mcc:$mcc,mnc:$mnc,earfcn:$channel,pci:$pci,cell_id:$cell,band:$band,band_width:$bw,sinr:$sinr,rsrq:$rsrq,rsrp:$rsrp,rssi:$rssi,tac:$tac,tx_power:$tx,has_ca:($sb!=""),scc1_band:$sb,scc1_band_width:$sw}'
   fi; value="$a";;
 esac
 [ -n "${value:-}" ]||{ qmodem_parser_error "$id" parse_failed; return 1; }
}
