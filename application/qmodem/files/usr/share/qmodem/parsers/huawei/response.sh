#!/bin/sh

qmodem_huawei_line()
{
    awk -v prefix="$1" '{ sub(/\r$/, ""); if (index($0,prefix)==1) { line=substr($0,length(prefix)+1); sub(/^[[:space:]]*/,"",line); print line; exit } }'
}

qmodem_huawei_csv()
{
    awk -F, '{ for(i=1;i<=NF;i++) { gsub(/^[[:space:]]+|[[:space:]\r]+$/, "", $i); printf "%s%s", (i==1?"":"\034"), $i } exit }' |
        jq -Rsc 'split("\u001c")'
}

qmodem_huawei_parse()
{
    local id="$1" raw value fields fallback
    raw=$(cat)
    case "$id" in
        huawei.cgsn) value=$(printf '%s\n' "$raw" | grep -o '[0-9]\{15\}' | head -n1); [ -n "$value" ] && jq -cn --arg imei "$value" '{imei:$imei}' ;;
        huawei.setmode)
            if [ "$platform" = unisoc ]; then value=$(printf '%s\n' "$raw" | sed -n 's/.*SETMODE[^0-9]*\([0-9]\).*/\1/p' | head -n1)
            else value=$(printf '%s\n' "$raw" | awk 'NR==2{sub(/\r$/,"");print;exit}'); fi
            [ -n "$value" ] && jq -cn --arg mode_num "$value" '{mode_num:$mode_num}' ;;
        huawei.syscfgex) value=$(printf '%s\n' "$raw" | qmodem_huawei_line '^SYSCFGEX:' | awk -F\" '{print $2}'); [ -n "$value" ] && jq -cn --arg rat_codes "$value" '{rat_codes:$rat_codes}' ;;
        huawei.cpin)
            value=$(printf '%s\n' "$raw" | awk '/^\+CPIN:|^\+CME ERROR: 10/{sub(/\r$/,"");print;exit}')
            [ -n "$value" ] && jq -cn --arg status_line "$value" '{status_line:$status_line}' ;;
        huawei.cnum)
            value=$(printf '%s\n' "$raw" | awk -F\" '/^\+CNUM:/{print $2;exit}')
            fallback=$(printf '%s\n' "$raw" | awk -F\" '/^\+CNUM:/{print $4;exit}')
            [ -n "$value$fallback" ] && jq -cn --arg primary_number "$value" --arg fallback_number "$fallback" \
                '{primary_number:$primary_number,fallback_number:$fallback_number,number:(if $primary_number=="" then $fallback_number else $primary_number end)}' ;;
        huawei.cimi) value=$(printf '%s\n' "$raw" | awk 'NR==2{sub(/\r$/,"");print;exit}'); [ -n "$value" ] && jq -cn --arg imsi "$value" '{imsi:$imsi}' ;;
        huawei.cgmm) value=$(printf '%s\n' "$raw" | awk '$0!~/OK/{n++;if(n==2){sub(/\r$/,"");print;exit}}'); [ -n "$value" ] && jq -cn --arg name "$value" '{name:$name}' ;;
        huawei.cgmi) value=$(printf '%s\n' "$raw" | awk 'NR==2{sub(/\r$/,"");print;exit}'); [ -n "$value" ] && jq -cn --arg manufacturer "$value" '{manufacturer:$manufacturer}' ;;
        huawei.ati) value=$(printf '%s\n' "$raw" | sed -n 's/^Revision: //p' | sed 's/\r$//' | head -n1); [ -n "$value" ] && jq -cn --arg revision "$value" '{revision:$revision}' ;;
        huawei.monsc) value=$(printf '%s\n' "$raw" | qmodem_huawei_line '^MONSC:'); fields=$(printf '%s\n' "$value" | qmodem_huawei_csv); [ -n "$value" ] && jq -cn --argjson f "$fields" '{rat:($f[0]//""),mcc:($f[1]//""),mnc:($f[2]//""),channel:($f[3]//""),nr:{scs_code:($f[4]//""),cell_id_hex:($f[5]//""),pci_hex:($f[6]//""),tac:($f[7]//""),rsrp:($f[8]//""),rsrq:($f[9]//""),sinr:($f[10]//"")},lte:{cell_id_hex:($f[4]//""),pci_hex:($f[5]//""),tac:($f[6]//""),rsrp:($f[7]//""),rsrq:($f[8]//""),rxlev:($f[9]//"")},wcdma:{psc:($f[4]//""),cell_id_hex:($f[5]//""),lac:($f[6]//""),rscp:($f[7]//""),rxlev:($f[8]//""),ecn0:($f[9]//""),drx:($f[10]//""),ura:($f[11]//"")},gsm:{band_code:($f[3]//""),arfcn:($f[4]//""),bsic:($f[5]//""),cell_id_hex:($f[6]//""),lac:($f[7]//""),rxlev:($f[8]//""),rx_quality:($f[9]//""),timing_advance:($f[10]//"")}}' ;;
        huawei.cserssi) value=$(printf '%s\n' "$raw" | awk '/^[[:space:]]*\^?CSERSSI:/{sub(/\r$/,"");print;exit}'); fields=$(printf '%s\n' "$value"|qmodem_huawei_csv); [ -n "$value" ] && jq -cn --argjson f "$fields" '{nr:{rsrp:($f[11]//""),rsrq:($f[12]//""),sinr:($f[13]//"")}}' ;;
        huawei.hfreqinfo) value=$(printf '%s\n' "$raw" | awk '/HFREQINFO:/{sub(/\r$/,"");print;exit}'); [ -n "$value" ] && jq -cn --arg text "$value" '{text:$text}' ;;
        huawei.band.config)
            fields=$(printf '%s\n' "$raw" | awk '/^[0-9]+ - /{gsub(/\r/,""); type=$3; sub(/:$/,"",type); print type "\034" $4 "\034" $5}' | jq -Rsc '[splits("\n")|select(length>0)|split("\u001c")|{type:.[0],low_mask:.[1],high_mask:.[2]}]')
            jq -cn --argjson configurations "$fields" '{configurations:$configurations}' ;;
        huawei.band.list)
            fields=$(printf '%s\n' "$raw" | awk 'BEGIN{active=0;type=""} /^Available:/{active=1;next} active && /^OK/{exit} active && /^[0-9]+ - .*:/{x=$0;sub(/\r/,"",x);sub(/^[0-9]+ - /,"",x);sub(/:$/,"",x);type=x;next} active && NF{line=$0;sub(/\r/,"",line);name=line;sub(/^.*-[[:space:]]*/,"",name);mask=line;sub(/[[:space:]]*-.*$/, "", mask);gsub(/^[[:space:]]+|[[:space:]]+$/,"",mask);gsub(/^[[:space:]]+|[[:space:]]+$/,"",name);if(name!="")print type "\034" mask "\034" name}' | jq -Rsc '[splits("\n")|select(length>0)|split("\u001c")|{type:.[0],mask:.[1],name:.[2]}]')
            jq -cn --argjson bands "$fields" '{bands:$bands}' ;;
        huawei.chiptemp) value=$(printf '%s\n' "$raw"|awk -F, '/^\^CHIPTEMP/{gsub(/\r/,"",$6);print $6;exit}'); [ -n "$value" ] && jq -cn --arg temperature "$value" '{temperature:$temperature}' ;;
    esac || return 1
    [ -n "${value:-}${fields:-}" ] || case "$id" in huawei.band.*) return 0;; *) qmodem_parser_error "$id" parse_failed; return 1;; esac
}
