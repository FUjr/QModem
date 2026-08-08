#!/bin/sh

parser_openluat_cced_serving()
{
    local row
    row=$(awk 'function trim(v){gsub(/^[[:space:]]+|[[:space:]\r]+$/,"",v);return v}
      /^[[:space:]]*\+CCED:LTE current cell[[:space:]]*:/ {line=$0;sub(/^[[:space:]]*\+CCED:LTE current cell[[:space:]]*:[[:space:]]*/,"",line);n=split(line,f,",");if(n!=13)next;printf "LTE";for(i=1;i<=13;i++)printf "\t%s",trim(f[i]);print "";exit}
      /^[[:space:]]*\+CCED:GSM current cell info[[:space:]]*:/ {line=$0;sub(/^[[:space:]]*\+CCED:GSM current cell info[[:space:]]*:[[:space:]]*/,"",line);n=split(line,f,",");if(n!=8)next;printf "GSM";for(i=1;i<=8;i++)printf "\t%s",trim(f[i]);print "";exit}')
    [ -n "$row" ] || { qmodem_parser_error openluat.cced.serving parse_failed; return 1; }
    printf '%s\n' "$row" | jq -RscS 'split("\n")[0] | split("\t") as $f |
      if $f[0] == "LTE" then {rat:$f[0],mcc:$f[1],mnc:$f[2],imsi:$f[3],roaming:$f[4],band:$f[5],bandwidth:$f[6],dl_earfcn:$f[7],cell_id:$f[8],rsrp_raw:$f[9],rsrq_raw:$f[10],tac:$f[11],srxlev:$f[12],pci:$f[13]}
      else {rat:$f[0],mcc:$f[1],mnc:$f[2],lac:$f[3],cell_id:$f[4],bsic:$f[5],rxlev:$f[6],rxlev_sub:$f[7],arfcn:$f[8]} end'
}

parser_openluat_cced_neighbors()
{
    local rows
    rows=$(awk 'function trim(v){gsub(/^[[:space:]]+|[[:space:]\r]+$/,"",v);return v}
      /^[[:space:]]*\+CCED:LTE neighbor cell[[:space:]]*:/ {line=$0;sub(/^[[:space:]]*\+CCED:LTE neighbor cell[[:space:]]*:[[:space:]]*/,"",line);n=split(line,f,",");if(n!=9)next;printf "LTE";for(i=1;i<=9;i++)printf "\t%s",trim(f[i]);print "";next}
      /^[[:space:]]*\+CCED:GSM neighbor cell info[[:space:]]*:/ {line=$0;sub(/^[[:space:]]*\+CCED:GSM neighbor cell info[[:space:]]*:[[:space:]]*/,"",line);n=split(line,f,",");if(n!=6)next;printf "GSM";for(i=1;i<=6;i++)printf "\t%s",trim(f[i]);print ""}')
    [ -n "$rows" ] || { qmodem_parser_error openluat.cced.neighbors parse_failed; return 1; }
    printf '%s\n' "$rows" | jq -RscS '{records:(split("\n") | map(select(length>0) | split("\t") as $f |
      if $f[0] == "LTE" then {rat:$f[0],mcc:$f[1],mnc:$f[2],arfcn:$f[3],cell_id:$f[4],rsrp_raw:$f[5],rsrq_raw:$f[6],tac:$f[7],srxlev:$f[8],pci:$f[9]}
      else {rat:$f[0],mcc:$f[1],mnc:$f[2],lac:$f[3],cell_id:$f[4],bsic:$f[5],rxlev:$f[6]} end))}'
}

parser_openluat_eem_lte()
{
    local row
    row=$(awk 'function trim(v){gsub(/^[[:space:]]+|[[:space:]\r]+$/,"",v);return v}
      /^[[:space:]]*\+EEMLTESVC[[:space:]]*:/ {line=$0;sub(/^[[:space:]]*\+EEMLTESVC[[:space:]]*:[[:space:]]*/,"",line);n=split(line,f,",");if(n<22)next;for(i=1;i<=n;i++)f[i]=trim(f[i]);layout="Air720";rssi=f[19];cqi=f[20];tx=f[21];rank=f[22];if(n>=50){layout="Air720S";rssi=f[32];cqi=f[33];rank=f[46];tx=f[50]} printf "LTE";idx[1]=1;idx[2]=3;idx[3]=4;idx[4]=5;idx[5]=6;idx[6]=7;idx[7]=8;idx[8]=9;idx[9]=10;idx[10]=11;idx[11]=12;idx[12]=13;idx[13]=14;for(i=1;i<=13;i++)printf "\t%s",f[idx[i]];printf "\t%s\t%s\t%s\t%s\t%s\n",rssi,cqi,tx,rank,layout;exit}')
    [ -n "$row" ] || { qmodem_parser_error openluat.eem.lte parse_failed; return 1; }
    printf '%s\n' "$row" | jq -RscS 'split("\n")[0] | split("\t") as $f |
      {rat:$f[0],mcc:$f[1],mnc:$f[2],tac:$f[3],pci:$f[4],dl_earfcn:$f[5],ul_earfcn:$f[6],band:$f[7],dl_bandwidth:$f[8],cell_id:$f[9],trans_mode:$f[10],rsrp_raw:$f[11],rsrq_raw:$f[12],sinr_raw:$f[13],rssi_raw:$f[14],cqi_raw:$f[15],tx_power_raw:$f[16],rank_index:$f[17],layout:$f[18]}'
}
