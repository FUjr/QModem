#!/bin/sh

qmodem_meig_prefixed() { awk -v p="$1" '{sub(/\r$/,"");if(index($0,p)==1){line=substr($0,length(p)+1);sub(/^[[:space:]]*/,"",line);print line;exit}}'; }
qmodem_meig_fields() { awk -F, '{for(i=1;i<=NF;i++){gsub(/^[[:space:]]+|[[:space:]\r]+$/,"",$i);printf "%s%s",(i==1?"":"\034"),$i}exit}' | jq -Rsc 'split("\u001c")'; }

qmodem_meig_parse()
{
    local id="$1" raw value fields
    raw=$(cat)
    case "$id" in
        meig.cgsn) value=$(printf '%s\n' "$raw"|grep -o '[0-9]\{15\}'|head -n1); [ -n "$value" ] && jq -cn --arg imei "$value" '{imei:$imei}' ;;
        meig.ser) value=$(printf '%s\n' "$raw"|qmodem_meig_prefixed '+SER:'); [ -n "$value" ] && jq -cn --arg mode_num "$value" '{mode_num:$mode_num}' ;;
        meig.syscfgex) value=$(printf '%s\n' "$raw"|qmodem_meig_prefixed '^SYSCFGEX:'|awk -F\" '{print $2}'); [ -n "$value" ] && jq -cn --arg rat_codes "$value" '{rat_codes:$rat_codes}' ;;
        meig.temp) value=$(printf '%s\n' "$raw"|awk -F\" -v p="$platform" '$2==(p=="unisoc"?"soc-thmzone":"cpu0-0-usr"){print $4;exit}'); [ -n "$value" ] && jq -cn --arg temperature "$value" '{temperature:$temperature}' ;;
        meig.cgmm) value=$(printf '%s\n' "$raw"|awk 'NR==2{sub(/\r$/,"");print;exit}'); [ -n "$value" ] && jq -cn --arg name "$value" '{name:$name}' ;;
        meig.cgmi) value=$(printf '%s\n' "$raw"|awk 'NR==2{sub(/^\+CGMI: /,"");sub(/\r$/,"");print;exit}'); [ -n "$value" ] && jq -cn --arg manufacturer "$value" '{manufacturer:$manufacturer}' ;;
        meig.cgmr) value=$(printf '%s\n' "$raw"|sed -n 's/^+CGMR: //p'|sed 's/\r$//'|head -n1); [ -n "$value" ] && jq -cn --arg revision "$value" '{revision:$revision}' ;;
        meig.simslot) value=$(printf '%s\n' "$raw"|qmodem_meig_prefixed '^SIMSLOT:'|awk -F, '{print $2}'); [ -n "$value" ] && jq -cn --arg slot_flag "$value" '{slot_flag:$slot_flag}' ;;
        meig.cpin) value=$(printf '%s\n' "$raw"|awk 'NR==2{sub(/\r$/,"");print;exit}'); [ -n "$value" ] && jq -cn --arg status_line "$value" '{status_line:$status_line}' ;;
        meig.cops) value=$(printf '%s\n' "$raw"|awk 'NR==2{sub(/\r$/,"");print;exit}'); [ -n "$value" ] && jq -cn --arg line "$value" --arg operator "$(printf '%s' "$value"|awk -F\" '{print $2}')" --arg rat "$(printf '%s' "$value"|awk -F, '{print $4}')" '{line:$line,operator:$operator,rat_code:$rat}' ;;
        meig.cnum) value=$(printf '%s\n' "$raw"|awk 'NR==2{sub(/\r$/,"");print;exit}'); [ -n "$value" ] && jq -cn --arg number "$(printf '%s' "$value"|awk -F\" '{print $4}')" '{number:$number}' ;;
        meig.cimi) value=$(printf '%s\n' "$raw"|awk 'NR==2{sub(/\r$/,"");print;exit}'); [ -n "$value" ] && jq -cn --arg imsi "$value" '{imsi:$imsi}' ;;
        meig.iccid) value=$(printf '%s\n' "$raw"|sed -n 's/^+ICCID:[ ]*\([-0-9]*\).*/\1/p'|grep -o '[-0-9]\{1,4\}'|head -n1); [ -n "$value" ] && jq -cn --arg iccid "$value" '{iccid:$iccid}' ;;
        meig.sysinfoex) value=$(printf '%s\n' "$raw"|qmodem_meig_prefixed '^SYSINFOEX:'|awk -F\" '{print $4}'); [ -n "$value" ] && jq -cn --arg network_type "$value" '{network_type:$network_type}' ;;
        meig.csq) value=$(printf '%s\n' "$raw"|qmodem_meig_prefixed '+CSQ:'); [ -n "$value" ] && jq -cn --arg value "$value" '{value:$value}' ;;
        meig.dsambr)
            value=$(printf '%s\n' "$raw"|qmodem_meig_prefixed '^DSAMBR:')
            fields=$(printf '%s\n' "$value"|qmodem_meig_fields)
            [ -n "$value" ] && jq -cn --argjson f "$fields" '
                def last_nonzero($start):
                    [range($start; ([($f|length)-2, 0]|max); 2) as $i | $f[$i] | select(. != "0")][-1] // "0";
                {
                    lte: {uplink_kbps:last_nonzero(0), downlink_kbps:last_nonzero(1)},
                    nr: {uplink_kbps:($f[8] // "0"), downlink_kbps:($f[9] // "0")}
                }' ;;
        meig.dsflowqry)
            value=$(printf '%s\n' "$raw"|qmodem_meig_prefixed '^DSFLOWRPT:')
            fields=$(printf '%s\n' "$value"|qmodem_meig_fields)
            [ -n "$value" ] && jq -cn --argjson f "$fields" \
                '{tx_rate:($f[0]//"0"),rx_rate:($f[1]//"0")}' ;;
        meig.cellinfo)
            value=$(printf '%s\n' "$raw"|qmodem_meig_prefixed '^CELLINFO:')
            fields=$(printf '%s\n' "$value"|qmodem_meig_fields|jq -c 'map(gsub(" "; ""))')
            [ -n "$value" ] && jq -cn --argjson f "$fields" '
                ($f[0] // "") as $rat |
                {rat:$rat} +
                if $rat == "5G" then {nr:{
                    duplex_mode:($f[1]//""),mcc:($f[2]//""),mnc:($f[3]//""),
                    cell_id:($f[4]//""),physical_cell_id:($f[5]//""),tac:($f[6]//""),
                    band_num:($f[7]//""),dl_bandwidth_num:($f[8]//""),scs:($f[9]//""),
                    rsrp:($f[14]//""),rsrq:($f[15]//""),sinr_tenths:($f[16]//"")
                }}
                elif $rat == "LTE-NR" then {endc:{
                    lte:{duplex_mode:($f[1]//""),mcc:($f[2]//""),mnc:($f[3]//""),
                        physical_cell_id:($f[5]//""),cell_id:($f[7]//""),tac:($f[8]//""),
                        band_num:($f[9]//""),ul_bandwidth_num:($f[10]//""),
                        rsrp:($f[14]//""),rsrq:($f[15]//""),sinr_tenths:($f[16]//""),
                        tx_power:(if ($f|length) >= 23 then ($f[21]//"") else "" end)},
                    nr:{physical_cell_id:(if ($f|length) >= 30 then ($f[29]//"") else "" end),
                        rsrp:(if ($f|length) >= 31 then ($f[29]//"") else "" end),
                        rsrq:(if ($f|length) >= 32 then ($f[30]//"") else "" end),
                        sinr_tenths:(if ($f|length) >= 33 then ($f[31]//"") else "" end),
                        band_num:(if ($f|length) >= 34 then ($f[32]//"") else "" end),
                        dl_bandwidth_num:(if ($f|length) >= 36 then ($f[34]//"") else "" end),
                        scs:(if ($f|length) >= 38 then ($f[36]//"") else "" end)}
                }}
                elif ($rat == "LTE" or $rat == "eMTC" or $rat == "NB-IoT") then {lte:{
                    duplex_mode:($f[1]//""),mcc:($f[2]//""),mnc:($f[3]//""),
                    physical_cell_id:($f[5]//""),cell_id:($f[7]//""),tac:($f[8]//""),
                    band_num:($f[9]//""),ul_bandwidth_num:($f[10]//""),
                    rsrp:($f[14]//""),rsrq:($f[15]//""),sinr_tenths:($f[16]//""),
                    tx_power:(if ($f|length) >= 23 then ($f[21]//"") else "" end)
                }}
                elif ($rat == "WCDMA" or $rat == "UMTS") then {wcdma:{
                    mcc:($f[1]//""),mnc:($f[2]//""),psc:($f[4]//""),cell_id:($f[6]//""),
                    lac:($f[7]//""),band_num:($f[8]//""),
                    ecio:(if ($f|length) >= 14 then ($f[12]//"") else "" end),
                    rscp:(if ($f|length) >= 16 then ($f[14]//"") else "" end)
                }} else {} end' ;;
    esac || return 1
    [ -n "${value:-}${fields:-}" ] || { qmodem_parser_error "$id" parse_failed; return 1; }
}
