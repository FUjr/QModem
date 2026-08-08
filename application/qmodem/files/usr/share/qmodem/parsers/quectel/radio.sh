#!/bin/sh

parser_quectel_qeng()
{
    jq -RscS '
      def clean: gsub("^[[:space:]\\\"]+|[[:space:]\\\"\\r]+$"; "");
      def fields: sub("^[[:space:]]*\\+QENG:[[:space:]]*"; "") | split(",") | map(clean);
      def record:
        fields as $f |
        if $f[0] == "LTE" then
          {rat:"LTE",duplex:$f[1],mcc:$f[2],mnc:$f[3],cell_id:$f[4],pci:$f[5],earfcn:$f[6],band_code:$f[7],ul_bandwidth_code:$f[8],dl_bandwidth_code:$f[9],tac:$f[10],rsrp:$f[11],rsrq:$f[12],rssi:$f[13],sinr:$f[14],cqi:$f[15],tx_power:$f[16],srxlev:$f[17]}
        elif $f[0] == "NR5G-NSA" then
          {rat:"NR5G-NSA",mcc:$f[1],mnc:$f[2],pci:$f[3],rsrp:$f[4],sinr:$f[5],rsrq:$f[6],arfcn:$f[7],band_code:$f[8],dl_bandwidth_code:$f[9],scs_code:$f[15]}
        elif $f[0] == "servingcell" and $f[2] == "NR5G-SA" then
          {rat:"NR5G-SA",state:$f[1],duplex:$f[3],mcc:$f[4],mnc:$f[5],cell_id:$f[6],pci:$f[7],tac:$f[8],arfcn:$f[9],band_code:$f[10],dl_bandwidth_code:$f[11],rsrp:$f[12],rsrq:$f[13],sinr:$f[14],scs_code:$f[15],srxlev:$f[16]}
        elif $f[0] == "servingcell" and $f[2] == "LTE" then
          {rat:"LTE",state:$f[1],duplex:$f[3],mcc:$f[4],mnc:$f[5],cell_id:$f[6],pci:$f[7],earfcn:$f[8],band_code:$f[9],ul_bandwidth_code:$f[10],dl_bandwidth_code:$f[11],tac:$f[12],rsrp:$f[13],rsrq:$f[14],rssi:$f[15],sinr:$f[16],cqi:$f[17],tx_power:$f[18],srxlev:$f[19]}
        elif $f[0] == "servingcell" and $f[2] == "WCDMA" then
          {rat:"WCDMA",state:$f[1],mcc:$f[3],mnc:$f[4],lac:$f[5],cell_id:$f[6],uarfcn:$f[7],psc:$f[8],rac:$f[9],rscp:$f[10],ecio:$f[11],phych_code:$f[12],sf_code:$f[13],slot_code:$f[14],speech_code:$f[15],compression_mode:$f[16]}
        elif $f[0] == "servingcell" then {rat:$f[2],state:$f[1]}
        else {rat:$f[0]} end;
      [split("\n")[] | select(test("^[[:space:]]*\\+QENG:")) | record] as $r |
      if ($r|length)==0 then error("parse_failed") else
        {records:$r,
         lte:($r|map(select(.rat=="LTE"))|first // null),
         nr5g_nsa:($r|map(select(.rat=="NR5G-NSA"))|first // null),
         nr5g_sa:($r|map(select(.rat=="NR5G-SA"))|first // null),
         wcdma:($r|map(select(.rat=="WCDMA"))|first // null)}
      end' 2>/dev/null || { qmodem_parser_error quectel.qeng parse_failed; return 1; }
}

parser_quectel_qeng_neighbors()
{
    jq -RscS '
      def clean: gsub("^[[:space:]\\\"]+|[[:space:]\\\"\\r]+$"; "");
      [split("\n")[] | select(test("^[[:space:]]*\\+QENG:")) |
       sub("^[[:space:]]*\\+QENG:[[:space:]]*"; "") | split(",") | map(clean) as $f |
       if $f[1]=="LTE" then {rat:"LTE",neighbourcell:$f[0],arfcn:$f[2],pci:$f[3],rsrq:$f[4],rsrp:$f[5]}
       elif $f[1]=="NR5G" or $f[1]=="NR" then {rat:"NR",neighbourcell:$f[0],arfcn:$f[2],pci:$f[3],rsrp:$f[4],rsrq:$f[5]}
       elif $f[1]=="WCDMA" then {rat:"WCDMA",neighbourcell:$f[0],arfcn:$f[2],pci:$f[3],rscp:$f[5],ecno:$f[6]}
       else empty end] as $r |
      {records:$r,lte:($r|map(select(.rat=="LTE"))),nr:($r|map(select(.rat=="NR"))),wcdma:($r|map(select(.rat=="WCDMA")))}'
}

parser_quectel_qcainfo()
{
    jq -RscS '
      def clean: gsub("^[[:space:]\\\"]+|[[:space:]\\\"\\r]+$"; "");
      [split("\n")[] | select(test("^[[:space:]]*\\+QCAINFO:")) |
       sub("^[[:space:]]*\\+QCAINFO:[[:space:]]*"; "") | split(",") | map(clean) as $f |
       {role:$f[0],arfcn:$f[1],bandwidth_code:$f[2],band_info:$f[3],state:$f[4],pci:$f[5],rsrp:$f[6],rsrq:$f[7],rssi:$f[8],sinr:$f[9]}] as $c |
      if ($c|length)==0 then error("parse_failed") else {carriers:$c,pcc:($c|map(select(.role=="PCC"))|first // null),scc:($c|map(select(.role=="SCC")))} end' 2>/dev/null || { qmodem_parser_error quectel.qcainfo parse_failed; return 1; }
}

parser_quectel_qnwlock()
{
    local context="$3" domain
    domain=$(printf '%s' "$context" | jq -r '.domain // empty')
    jq -RscS --arg domain "$domain" '
      def clean: gsub("^[[:space:]\\\"]+|[[:space:]\\\"\\r]+$"; "");
      [split("\n")[] | select(test("^[[:space:]]*\\+QNWLOCK:")) |
       sub("^[[:space:]]*\\+QNWLOCK:[[:space:]]*"; "") | split(",") | map(clean)] as $rows |
      if ($rows|length)==0 then error("parse_failed") else
        {domain:$domain,rows:$rows,enabled:(($rows[0][0] // "0") != "0")}
      end' 2>/dev/null || { qmodem_parser_error quectel.qnwlock parse_failed; return 1; }
}

parser_quectel_band_value()
{
    local context="$3" family key
    family=$(printf '%s' "$context" | jq -r '.family // empty')
    key=$(printf '%s' "$context" | jq -r '.key // empty')
    [ -n "$key" ] || { qmodem_parser_error quectel.band.value invalid_context; return 2; }
    jq -RscS --arg family "$family" --arg key "$key" '
      def clean: gsub("^[[:space:]\\\"]+|[[:space:]\\\"\\r]+$"; "");
      [split("\n")[] | select(test("^[[:space:]]*\\+(QNWPREFCFG|QCFG):")) |
       sub("^[[:space:]]*\\+(QNWPREFCFG|QCFG):[[:space:]]*"; "") | split(",") | map(clean) |
       select(.[0]==$key)] | first as $r |
      if $r==null then error("parse_failed") else {family:$family,key:$key,value:($r[1:]|join(",")),values:$r[1:]} end' 2>/dev/null || { qmodem_parser_error quectel.band.value parse_failed; return 1; }
}

parser_quectel_usage()
{
    local context="$3" kind
    kind=$(printf '%s' "$context" | jq -r '.kind // empty')
    jq -RscS --arg kind "$kind" '
      def nums: scan("[0-9]+") | tonumber;
      ([nums] | if $kind=="nr" then {tx_bytes:.[0],rx_bytes:.[1]} else {rx_bytes:.[0],tx_bytes:.[1]} end) as $v |
      if ($v.rx_bytes==null or $v.tx_bytes==null) then error("parse_failed") else $v end' 2>/dev/null || { qmodem_parser_error quectel.usage parse_failed; return 1; }
}

parser_quectel_sim_slots()
{
    jq -RscS '[scan("\\+(?:QUIMSLOT|QUSIMSLOT):[[:space:]]*([^\\r\\n]+)")[0] | scan("[12]") | tonumber] | unique | {slots:.}' 2>/dev/null || { qmodem_parser_error quectel.sim_slots parse_failed; return 1; }
}
