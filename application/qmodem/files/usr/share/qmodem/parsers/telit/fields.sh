#!/bin/sh

telit_fail()
{
    qmodem_parser_error "$1" parse_failed
    return 1
}

telit_parse_completion()
{
    local raw parsed
    raw=$(cat)
    parsed=$(printf '%s' "$raw" | qmodem_parser_completion telit.command.completion) || return
    printf '%s' "$parsed" | jq -cS '{accepted,final,command_output:.response_text} + (if has("error_code") then {error_code} else {} end)'
}

telit_parse_body()
{
    local parser_id="$1" key="$2" value
    value=$(awk 'BEGIN{n=0} {sub(/\r$/,"")} !/^AT/ && $0!="" && $0!="OK" && $0!="ERROR" {print; exit}')
    [ -n "$value" ] || { telit_fail "$parser_id"; return; }
    jq -cnS --arg k "$key" --arg v "$value" '{($k):$v}'
}

telit_parse_csv()
{
    local parser_id="$1" prefix="$2" key="$3" field="$4" value
    value=$(awk -F',' -v p="$prefix" -v f="$field" 'index($0,p){v=$f; sub(/^.*:[[:space:]]*/,"",v); gsub(/[[:space:]\r]/,"",v); print v; exit}')
    [ -n "$value" ] || { telit_fail "$parser_id"; return; }
    jq -cnS --arg k "$key" --arg v "$value" '{($k):$v}'
}

telit_parse_ws46()
{
    local code
    code=$(awk -F':' '/\+WS46:/{gsub(/[[:space:]\r]/,"",$2); print $2; exit}')
    [ -n "$code" ] || { telit_fail telit.ws46; return; }
    case "$code" in
        22) g3=true; g4=false; g5=false ;;
        28) g3=false; g4=true; g5=false ;;
        36) g3=false; g4=false; g5=true ;;
        31) g3=true; g4=true; g5=false ;;
        40) g3=true; g4=false; g5=true ;;
        37) g3=false; g4=true; g5=true ;;
        38) g3=true; g4=true; g5=true ;;
        *) g3=false; g4=false; g5=false ;;
    esac
    jq -cnS --arg code "$code" --argjson g3 "$g3" --argjson g4 "$g4" --argjson g5 "$g5" \
        '{mode_code:$code,enabled:{"3G":$g3,"4G":$g4,"5G":$g5}}'
}

telit_parse_usbcfg()
{
    local mode_num
    mode_num=$(awk -F':' '/#USBCFG:/{gsub(/[[:space:]\r]/,"",$2); print $2; exit}')
    [ -n "$mode_num" ] || { telit_fail telit.usbcfg; return; }
    # legacy_mode_num preserves the historical grep -o "#USBCFG:" result.
    jq -cnS --arg mode_num "$mode_num" '{mode_num:$mode_num,legacy_mode_num:""}'
}

telit_parse_qss()
{
    local slot
    slot=$(awk -F',' '/#QSS:/{gsub(/[[:space:]\r]/,"",$3); print $3; exit}')
    [ -n "$slot" ] || { telit_fail telit.qss; return; }
    case "$slot" in 0) slot=1;; 1) slot=2;; esac
    qmodem_parser_string sim_slot "$slot"
}

telit_parse_cops()
{
    local operator
    operator=$(awk -F'"' '/\+COPS:/{print $2; exit}')
    [ -n "$operator" ] || { telit_fail telit.cops; return; }
    qmodem_parser_string operator "$operator"
}

telit_parse_iccid()
{
    local iccid chunks
    iccid=$(awk 'match($0,/\+ICCID:[ ]*[-0-9]+/){v=substr($0,RSTART,RLENGTH); sub(/^\+ICCID:[ ]*/,"",v); print v; exit}')
    [ -n "$iccid" ] || { telit_fail telit.iccid; return; }
    chunks=$(printf '%s' "$iccid" | awk '{while(length($0)){print substr($0,1,4); $0=substr($0,5)}}' | jq -Rsc 'split("\n")|map(select(length>0))')
    jq -cnS --arg iccid "$iccid" --argjson chunks "$chunks" '{iccid:$iccid,iccid_chunks:$chunks}'
}

telit_parse_cqi()
{
    local values first second cqi
    values=$(awk -F':' '/#CQI:/{gsub(/[[:space:]\r]/,"",$2); print $2; exit}')
    [ -n "$values" ] || { telit_fail telit.cqi; return; }
    first=${values%%,*}; second=${values#*,}; cqi=$first
    [ "$first" = 31 ] && cqi=$second
    qmodem_parser_string downlink_cqi "$cqi"
}

telit_mask_bands()
{
    local mask="$1" prefix="$2" offset="$3" decimal bit index out
    [ -n "$mask" ] || { printf '[]'; return; }
    decimal=$(printf 'ibase=16; %s\n' "$(printf '%s' "$mask" | tr a-f A-F)" | bc 2>/dev/null) || decimal=0
    index=0; out='[]'
    while [ "$decimal" != 0 ]; do
        bit=$(expr "$decimal" % 2)
        [ "$bit" -eq 1 ] && out=$(printf '%s' "$out" | jq -c --arg b "$prefix$(expr "$index" + "$offset")" '. + [$b]')
        decimal=$(expr "$decimal" / 2); index=$(expr "$index" + 1)
    done
    printf '%s' "$out"
}

telit_parse_bnd()
{
    local kind="$1" line csv lte nsa1 nsa2 sa1 sa2 lte_bands nsa_a nsa_b sa_a sa_b
    line=$(awk '/#BND:/{sub(/\r$/,""); print; exit}')
    [ -n "$line" ] || { telit_fail "telit.bnd.$kind"; return; }
    csv=$(printf '%s' "$line" | sed 's/^.*#BND:[[:space:]]*//; s/[()]//g; s/[[:space:]]//g')
    lte=$(printf '%s' "$csv" | cut -d, -f3); nsa1=$(printf '%s' "$csv" | cut -d, -f5)
    nsa2=$(printf '%s' "$csv" | cut -d, -f6); sa1=$(printf '%s' "$csv" | cut -d, -f7); sa2=$(printf '%s' "$csv" | cut -d, -f8)
    lte_bands=$(telit_mask_bands "$lte" B 1); nsa_a=$(telit_mask_bands "$nsa1" N 1); nsa_b=$(telit_mask_bands "$nsa2" N 65)
    sa_a=$(telit_mask_bands "$sa1" N 1); sa_b=$(telit_mask_bands "$sa2" N 65)
    jq -cnS --arg kind "$kind" --arg lte "$lte" --arg lte_ext "$(printf '%s' "$csv"|cut -d, -f4)" \
      --arg nsa1 "$nsa1" --arg nsa2 "$nsa2" --arg sa1 "$sa1" --arg sa2 "$sa2" \
      --argjson lte_bands "$lte_bands" --argjson nsa_a "$nsa_a" --argjson nsa_b "$nsa_b" --argjson sa_a "$sa_a" --argjson sa_b "$sa_b" \
      '{kind:$kind,masks:{lte:$lte,lte_ext:$lte_ext,nsa_1_64:$nsa1,nsa_65_128:$nsa2,sa_1_64:$sa1,sa_65_128:$sa2},bands:{lte:$lte_bands,nsa:($nsa_a+$nsa_b),sa:($sa_a+$sa_b)}}'
}

telit_parse_cainfoext()
{
    local raw
    raw=$(cat)
    printf '%s' "$raw" | grep -q '#CAINFOEXT:' || { telit_fail telit.cainfoext; return; }
    jq -cnS --arg raw "$raw" '
      def clean: gsub("\\r";"") | gsub("^[[:space:]]+|[[:space:]]+$";"");
      def capturev($s;$k): (try ($s | capture($k+":[[:space:]]*(?<v>[^,]+)").v | clean) catch "");
      def one_decimal: if floor == . then (tostring + ".0") else tostring end;
      def band($n): ({"120":"B1","121":"B2","122":"B3","123":"B4","124":"B5","126":"B7","127":"B8","132":"B13","134":"B17","145":"B20","149":"B41","158":"B28","161":"B30","166":"B66","250":"N1","252":"N3","253":"N5","255":"N8","257":"N28","259":"N41","262":"N66","268":"N77","269":"N78","270":"N79"}[$n] // $n);
      def bw($s): ((capturev($s;"BW")) as $v | if $v!="" then $v else ({"0":"1.4 MHz","1":"3 MHz","2":"5 MHz","3":"10 MHz","4":"15 MHz","5":"20 MHz"}[capturev($s;"DL_BW")] // capturev($s;"DL_BW")) end);
      def carrier($s): {band:band(capturev($s;"BandClass")),bandwidth:bw($s),arfcn:(capturev($s;"CH") as $v|if $v=="" then capturev($s;"RX_CH") else $v end),pci:capturev($s;"PCI"),rsrp:capturev($s;"RSRP"),rsrq:capturev($s;"RSRQ"),rssi:capturev($s;"RSSI"),sinr_raw:capturev($s;"SINR")};
      ($raw|split("\n")|map(clean)) as $l |
      ($l|map(select(startswith("#CAINFOEXT:")))|first|sub("^#CAINFOEXT:[[:space:]]*";"")|split(",")) as $h |
      ($l|map(select(test("PCC-")))|first // "") as $p |
      ($l|map(select(test("SCC[0-9]+-")))|map(carrier(.))) as $s |
      (carrier($p)) as $pc | ($h[0]|tonumber) as $count |
      {ca_count:$count,network_mode:(($h[1]|clean) + (if $count>1 then " with \($count) CA" else "" end)),
       band:([$pc.band]+($s|map(.band))|join(" / ")),bandwidth:([$pc.bandwidth]+($s|map(.bandwidth))|join(" / ")),
       arfcn:([$pc.arfcn]+($s|map(.arfcn))|join(" / ")),pci:([$pc.pci]+($s|map(.pci))|join(" / ")),
       rsrp:$pc.rsrp,rsrq:$pc.rsrq,rssi:$pc.rssi,sinr:((capturev($p;"SINR")|tonumber*.2-20)*10|round/10|one_decimal),
       tac:capturev($p;"TAC"),tx_power:(capturev($p;"TX_PWR") as $v|if $v=="" then "0" else (($v|tonumber)/10*10|round/10|one_decimal) end),
       ul_mod:({"0":"BPSK","1":"QPSK","2":"16QAM","3":"64QAM","4":"256QAM"}[capturev($p;"UL_MOD")] // capturev($p;"UL_MOD")),
       dl_mod:({"0":"BPSK","1":"QPSK","2":"16QAM","3":"64QAM","4":"256QAM"}[(capturev($p;"DL_MOD")|gsub("[^0-9]";""))] // capturev($p;"DL_MOD"))}'
}
