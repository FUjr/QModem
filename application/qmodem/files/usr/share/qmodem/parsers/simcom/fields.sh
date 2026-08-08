#!/bin/sh

simcom_fail() { qmodem_parser_error "$1" parse_failed; return 1; }
simcom_string() { [ -n "$3" ] || { simcom_fail "$1"; return; }; qmodem_parser_string "$2" "$3"; }

parser_simcom_line2()
{
    local id="$1" key="$2" value
    value=$(awk 'NR==2 { sub(/\r$/,""); print; exit }')
    simcom_string "$id" "$key" "$value"
}

parser_simcom_prefixed()
{
    local id="$1" prefix="$2" key="$3" value
    value=$(awk -v p="$prefix" 'index($0,p) { sub(/\r$/,""); sub("^.*" p "[[:space:]]*",""); print; exit }')
    simcom_string "$id" "$key" "$value"
}

parser_simcom_csv()
{
    local id="$1" prefix="$2" key="$3" field="$4" value
    value=$(awk -v p="$prefix" -v n="$field" -F',' 'index($0,p) { v=$n; sub("^.*" p "[[:space:]]*", "", v); gsub(/[[:space:]\r]/,"",v); print v; exit }')
    simcom_string "$id" "$key" "$value"
}

parser_simcom_quoted()
{
    local id="$1" prefix="$2" key="$3" field="$4" value
    value=$(awk -v p="$prefix" -v n="$field" -F'"' 'index($0,p) { print $n; exit }')
    simcom_string "$id" "$key" "$value"
}

parser_simcom_cgsn()
{
    local value
    value=$(awk 'match($0,/[0-9]{15}/) { print substr($0,RSTART,15); exit }')
    simcom_string simcom.cgsn imei "$value"
}

parser_simcom_iccid()
{
    local value
    value=$(awk 'match($0,/\+ICCID:[ ]*[-0-9]+/) { value=substr($0,RSTART,RLENGTH); sub(/^\+ICCID:[ ]*/,"",value); while (length(value)) { print substr(value,1,4); value=substr(value,5) } exit }')
    simcom_string simcom.iccid iccid "$value"
}

parser_simcom_cnmp()
{
    local mode
    mode=$(awk '/\+CNMP:/ { sub(/^.*\+CNMP:[ ]*/,""); gsub(/[[:space:]\r]/,""); print; exit }')
    [ -n "$mode" ] || { simcom_fail simcom.cnmp; return; }
    jq -cnS --arg mode "$mode" '{mode:$mode}'
}

parser_simcom_cnbp()
{
    local values mode lte ext
    values=$(awk -F',' '/\+CNBP:/ { sub(/^.*\+CNBP:[ ]*/,"",$1); gsub(/[[:space:]\r]/,"",$1); gsub(/[[:space:]\r]/,"",$2); gsub(/[[:space:]\r]/,"",$3); print $1 " " $2 " " $3; exit }')
    set -- $values; mode=$1; lte=$2; ext=$3
    [ -n "$mode" ] || { simcom_fail simcom.cnbp; return; }
    jq -cnS --arg mode "$mode" --arg lte "$lte" --arg ext "$ext" '{mode:$mode,lte_mode:$lte,lte_modeext:$ext}'
}


# Structured parsers below deliberately expose semantic fields rather than raw
# response lines.  They remain single-command, stdin-only transformations.
parser_simcom_myconfig() { jq -RscS '[split("\n")[]|sub("\r$";"")|select(contains("MYCONFIG:"))][0] | if .==null then error("missing") else sub("^.*MYCONFIG:[ ]*";"")|split(",")|{usbnet_mode:(.[1]//""|gsub("^[ ]+|[ ]+$";"")),auxiliary:(.[2]//""|gsub("^[ ]+|[ ]+$";""))} end' || { simcom_fail simcom.myconfig; return; }; }

parser_simcom_csyssel() { jq -RscS '[split("\n")[]|sub("\r$";"")|select(contains("+CSYSSEL:"))][0] | if .==null then error("missing") else sub("^.*\\+CSYSSEL:[ ]*";"")|split(",")|{selector:(.[0]//""|gsub("^[ ]+|[ ]+$";"")|gsub("\"";"")),bands:(.[1]//""|gsub("^[ ]+|[ ]+$";"")|split(":")|map(select(length>0)))} end' || { simcom_fail simcom.csyssel; return; }; }

parser_simcom_ccellcfg() { jq -RscS '[split("\n")[]|sub("\r$";"")|select(contains("+CCELLCFG:"))][0] | if .==null then {locked:false,pci:"",arfcn:""} else sub("^.*\\+CCELLCFG:[ ]*";"")|split(",")|{locked:true,pci:(.[0]//""|gsub("^[ ]+|[ ]+$";"")),arfcn:(.[1]//""|gsub("^[ ]+|[ ]+$";""))} end'; }

parser_simcom_c5gcellcfg() { jq -RscS '[split("\n")[]|sub("\r$";"")|select(contains("+C5GCELLCFG:"))][0] | if .==null then {locked:false,status:"",pci:"",arfcn:"",scs:"",band:""} else sub("^.*\\+C5GCELLCFG:[ ]*";"")|split(",")|{status:(.[0]//""|gsub("^[ ]+|[ ]+$";"")|gsub("\"";"")),locked:((.[0]//""|gsub("[^0-9]";""))!="0"),pci:(.[1]//""|gsub("^[ ]+|[ ]+$";"")),arfcn:(.[2]//""|gsub("^[ ]+|[ ]+$";"")),scs:(.[3]//""|gsub("^[ ]+|[ ]+$";"")),band:(.[4]//""|gsub("^[ ]+|[ ]+$";""))} end'; }

parser_simcom_cpsi() { jq -RscS '
 def t:gsub("^[ ]+|[ ]+$";"");
 [split("\n")[]|select(contains("+CPSI:"))|sub("^.*\\+CPSI:[ ]*";"")|split(",")|map(sub("\\r$";"")|t)|. as $f|($f[0]//"") as $r|
 if $r=="NR5G_NSA" then {rat:$r,pci:($f[1]//""),band_code:($f[2]//""),arfcn:($f[3]//""),rsrp_tenth:($f[4]//""),rsrq_tenth:($f[5]//""),sinr_tenth:($f[6]//""),scs_code:($f[7]//""),dl_bandwidth_code:($f[8]//"")}
 elif $r=="LTE" then {rat:$r,operation_mode:($f[1]//""),plmn:($f[2]//""),tac:($f[3]//""),cell_id:($f[4]//""),pci:($f[5]//""),band_code:($f[6]//""),arfcn:($f[7]//""),dl_bandwidth_code:($f[8]//""),ul_bandwidth_code:($f[9]//""),rsrq_tenth:($f[10]//""),rsrp_tenth:($f[11]//""),rssi_tenth:($f[12]//""),sinr:($f[13]//"")}
 elif $r=="NR5G_SA" then {rat:$r,operation_mode:($f[1]//""),plmn:($f[2]//""),tac:($f[3]//""),cell_id:($f[4]//""),pci:($f[5]//""),band_code:($f[6]//""),arfcn:($f[7]//""),rsrp_tenth:($f[8]//""),rsrq_tenth:($f[9]//""),sinr:($f[10]//"")}
 elif $r=="WCDMA" then {rat:$r,operation_mode:($f[1]//""),plmn:($f[2]//""),lac:($f[3]//""),cell_id:($f[4]//""),band_code:($f[5]//""),psc:($f[6]//""),uarfcn:($f[7]//""),ssc:($f[8]//""),ecio:($f[9]//""),rscp_tenth:($f[10]//""),quality:($f[11]//""),rxlev:($f[12]//""),tx_power:($f[13]//"")} else {rat:$r,fields:$f} end] | if length==0 then error("missing") else {records:.} end' || { simcom_fail simcom.cpsi; return; }; }

parser_simcom_cnwinfo() { jq -RscS 'def t:gsub("^[ ]+|[ ]+$";""); [split("\n")[]|select(contains("+CNWINFO:"))|sub("^.*\\+CNWINFO:[ ]*";"")|split(",")|map(sub("\\r$";"")|t)] | if length==0 then error("missing") else .[0] as $f|{rat:($f[0]//""),operator:($f[1]//""),band:($f[2]//""),srxlev:($f[3]//""),rxlev:($f[4]//""),cqi_or_dlmod:($f[7]//""),tx_power_or_ulmod:($f[8]//""),dl_bandwidth:($f[10]//""),tx_power:($f[11]//""),rssi_tenth:($f[12]//""),cqi:($f[13]//"")} end' || { simcom_fail simcom.cnwinfo; return; }; }

parser_simcom_cnwsearch() { jq -RscS 'def t:gsub("^[ ]+|[ ]+$";""); [split("\n")[]|sub("\\r$";"")|if contains("+NR_NGH_CELL:") then sub("^.*\\+NR_NGH_CELL:[ ]*";"")|split(",")|map(t)|{rat:"NR",arfcn:(.[0]//""),pci:(.[1]//""),rsrp:(.[2]//""),rsrq:(.[3]//"")} elif contains("+LTE_CELL:") then sub("^.*\\+LTE_CELL:[ ]*";"")|split(",")|map(t)|{rat:"LTE",mnc:(.[1]//""),band:(.[4]//""),arfcn:(.[5]//""),pci:(.[6]//""),rsrp:(.[7]//""),rsrq:(.[8]//"")} elif contains("WCDMA") then split(",")|map(t)|{rat:"WCDMA",arfcn:(.[3]//""),pci:(.[6]//""),ecno:(.[9]//""),rscp:(.[10]//"")} else empty end]|{cells:.}'; }
