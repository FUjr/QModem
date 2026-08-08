#!/bin/sh

fibocom_parse_failed()
{
    qmodem_parser_error "$1" "parse_failed"
    return 1
}

fibocom_emit_string()
{
    [ -n "$3" ] || { fibocom_parse_failed "$1"; return; }
    qmodem_parser_string "$2" "$3"
}

parser_fibocom_prefixed()
{
    local parser_id="$1" prefix="$2" key="$3" value
    value=$(awk -v prefix="$prefix" '
        index($0, prefix) { line=$0; sub(/\r$/, "", line); sub("^.*" prefix "[[:space:]]*", "", line); print line; exit }
    ')
    fibocom_emit_string "$parser_id" "$key" "$value"
}

parser_fibocom_quoted()
{
    local parser_id="$1" prefix="$2" key="$3" index="${4:-2}" value
    value=$(awk -v prefix="$prefix" -v wanted="$index" -F'"' '
        index($0, prefix) { if ($wanted != "") { print $wanted; exit } }
    ')
    fibocom_emit_string "$parser_id" "$key" "$value"
}

parser_fibocom_csv()
{
    local parser_id="$1" prefix="$2" key="$3" field="$4" value
    value=$(awk -v prefix="$prefix" -v field="$field" -F',' '
        index($0, prefix) { value=$field; sub("^.*" prefix "[[:space:]]*", "", value); gsub(/[[:space:]\r"]/, "", value); print value; exit }
    ')
    fibocom_emit_string "$parser_id" "$key" "$value"
}

parser_fibocom_cgsn()
{
    local value
    value=$(awk -F'"' '/\+CGSN:[[:space:]]*/ { if ($2 ~ /^[0-9]+$/) { print $2; exit } }')
    fibocom_emit_string "fibocom.cgsn" "imei" "$value"
}

parser_fibocom_cpin()
{
    local value
    value=$(awk '/\+CPIN:|\+CME/ { sub(/\r$/, ""); print; exit }')
    fibocom_emit_string "fibocom.cpin.status" "status_text" "$value"
}

parser_fibocom_iccid()
{
    local value
    value=$(awk 'match($0, /\+ICCID:[ ]*[-0-9]+/) { value=substr($0,RSTART,RLENGTH); sub(/^\+ICCID:[ ]*/,"",value); print substr(value,1,4); exit }')
    fibocom_emit_string "fibocom.iccid" "iccid" "$value"
}

parser_fibocom_gtact()
{
    local line mode
    line=$(awk '/\+GTACT:/ { sub(/\r$/, ""); print; exit }')
    [ -n "$line" ] || { fibocom_parse_failed "$1"; return; }
    mode=$(printf '%s\n' "$line" | awk -F',' '{v=$1; sub(/^.*\+GTACT:[ ]*/,"",v); gsub(/ /,"",v); print v}')
    jq -cnS --arg line "$line" --arg mode "$mode" '{line:$line,mode:$mode}'
}

parser_fibocom_gtstatis()
{
    local values rx tx
    values=$(awk -F',' '/\+GTSTATIS:/ { sub(/^.*\+GTSTATIS:[ ]*/,"",$1); gsub(/\r/,""); print $1 " " $2; exit }')
    set -- $values; rx=$1; tx=$2
    [ -n "$rx" ] && [ -n "$tx" ] || { fibocom_parse_failed "fibocom.gtstatis.rates"; return; }
    jq -cnS --arg rx "$rx" --arg tx "$tx" '{rx_rate:$rx,tx_rate:$tx}'
}

parser_fibocom_temperature()
{
    local parser_id="$1" kind="$2" value
    case "$kind" in
        mtsm) value=$(awk '/\+MTSM:[ ]*/ { sub(/^.*\+MTSM:[ ]*/,""); sub(/\r$/,""); print; exit }') ;;
        gtladc) value=$(awk '/cpu/ { sub(/\r$/,""); print substr($2,1,2); exit }') ;;
        gtsenrdtemp) value=$(awk -F',' '/\+GTSENRDTEMP:/ { gsub(/\r/,"",$2); print substr($2,1,2); exit }') ;;
    esac
    fibocom_emit_string "$parser_id" "temperature" "$value"
}

parser_fibocom_gtccinfo_semantic()
{
    local raw
    raw=$(cat)
    printf '%s' "$raw" | grep -q ',' || { fibocom_parse_failed "fibocom.gtccinfo"; return; }
    jq -cnS --arg raw "$raw" '
      def clean: gsub("\\r"; "") | gsub("^[[:space:]]+|[[:space:]]+$"; "");
      def val($a;$n): ($a[$n] // "" | clean);
      ($raw | split("\n") | map(clean)) as $lines |
      ($lines | map(select(test("service"))) | first // "" | split(" ") | first // "") as $rat |
      {rat:$rat,records:[$lines[] | select(contains(",")) | split(",") as $f | {
        selector:val($f;1),mcc:val($f;2),mnc:val($f;3),tac:val($f;4),
        cell_id:val($f;5),arfcn:val($f;6),pci:val($f;7),band:val($f;8),
        bandwidth:val($f;9),signal_1:val($f;10),rxlev:val($f;11),
        rsrp:val($f;12),rsrq:val($f;13),extra_1:val($f;14)
      }]}'
}

parser_fibocom_gtcainfo_semantic()
{
    local raw
    raw=$(cat)
    printf '%s' "$raw" | grep -qE 'PCC|SCC' || { fibocom_parse_failed "fibocom.gtcainfo"; return; }
    jq -cnS --arg raw "$raw" '
      def clean: gsub("\\r"; "") | gsub("^[[:space:]]+|[[:space:]]+$"; "");
      def val($a;$n): ($a[$n] // "" | clean);
      [$raw | split("\n")[] | clean | select(test("PCC|SCC")) | split(",") as $f | {
        role:(if val($f;0) | contains("PCC") then "pcc" else "scc" end),
        ul_ca:val($f;1),band:val($f;2),pci:val($f;3),arfcn:val($f;4),
        dl_bandwidth:(if val($f;0) | contains("PCC") then val($f;3) else val($f;5) end),
        ul_bandwidth:(if val($f;0) | contains("PCC") then val($f;4) else (if val($f;1)=="1" then val($f;5) else "" end) end)
      }] as $records | {pcc:($records | map(select(.role=="pcc")) | first // {}),scc:($records | map(select(.role=="scc")))}'
}

parser_fibocom_gtdualsim()
{
    local slot
    slot=$(awk -F'"' '/\+GTDUALSIM/ { value=$2; sub(/^SUB/,"",value); print value; exit }')
    fibocom_emit_string "fibocom.gtdualsim.slot" "sim_slot" "$slot"
}

parser_fibocom_gtdualsim_status()
{
    local slot
    slot=$(awk -F',' '/^[[:space:]]*\+GTDUALSIM:/ { value=$1; sub(/^.*\+GTDUALSIM:[ ]*/,"",value); gsub(/[[:space:]\r]/,"",value); print value; exit }')
    fibocom_emit_string "fibocom.gtdualsim.status" "sim_slot" "$slot"
}

parser_fibocom_usage()
{
    local line
    line=$(awk '/\+GTUSAGEREC:/ { sub(/\r$/,""); print; exit }')
    [ -n "$line" ] || { fibocom_parse_failed "fibocom.gtusagerec"; return; }
    qmodem_parser_string "usage_line" "$line"
}
