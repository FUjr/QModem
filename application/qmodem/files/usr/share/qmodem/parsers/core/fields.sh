#!/bin/sh

parser_core_gtdns()
{
    local values
    values=$(awk -F'"' '/^[[:space:]]*\+GTDNS:/ {
        split($2, first, ","); split($4, second, ",")
        printf "%s\t%s\t%s\t%s\n", first[1], second[1], first[2], second[2]
        exit
    }')
    [ -n "$values" ] || { qmodem_parser_error core.gtdns parse_failed; return 1; }
    IFS="$(printf '\t')" read -r ipv4_dns1 ipv4_dns2 ipv6_dns1 ipv6_dns2 <<EOF
$values
EOF
    jq -cnS --arg ipv4_dns1 "$ipv4_dns1" --arg ipv4_dns2 "$ipv4_dns2" \
        --arg ipv6_dns1 "$ipv6_dns1" --arg ipv6_dns2 "$ipv6_dns2" \
        '{ipv4_dns1:$ipv4_dns1,ipv4_dns2:$ipv4_dns2,
          ipv6_dns1:$ipv6_dns1,ipv6_dns2:$ipv6_dns2}'
}

parser_core_cgact()
{
    local cids
    cids=$(awk -F'[,:]' '/^[[:space:]]*\+CGACT:/ {
        gsub(/[[:space:]\r]/, "", $2); gsub(/[[:space:]\r]/, "", $3)
        if ($3 == "1" && $2 ~ /^[0-9]+$/) print $2
    }')
    [ -n "$cids" ] || { qmodem_parser_error core.cgact.active_contexts parse_failed; return 1; }
    printf '%s\n' "$cids" | jq -RscS '{active_cids:[splits("\n") | select(length > 0)]}'
}

parser_core_cgpaddr()
{
    local response ipv4 ipv6
    response=$(cat)
    ipv4=$(printf '%s\n' "$response" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '^0\.0\.0\.0$' | head -n 1)
    ipv6=$(printf '%s\n' "$response" | sed 's/IPV6://g; s/ipv6://g' | \
        grep -oE '([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}' | head -n 1)
    [ -n "$ipv4$ipv6" ] || { qmodem_parser_error core.cgpaddr.addresses parse_failed; return 1; }
    jq -cnS --arg ipv4 "$ipv4" --arg ipv6 "$ipv6" \
        '{ipv4:$ipv4,ipv6:$ipv6}'
}

parser_core_cpms()
{
    local response values
    response=$(cat)
    values=$(printf '%s\n' "$response" | awk -F'[:,]' '/\+CPMS:/ {
        for (i=2; i<=10; i++) gsub(/[[:space:]\r"]/, "", $i)
        if (NF >= 10) printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
            $2,$3,$4,$5,$6,$7,$8,$9,$10
        exit
    }')
    [ -n "$values" ] || { qmodem_parser_error core.cpms parse_failed; return 1; }
    IFS="$(printf '\t')" read -r m1 u1 t1 m2 u2 t2 m3 u3 t3 <<EOF
$values
EOF
    jq -cnS --arg m1 "$m1" --arg u1 "$u1" --arg t1 "$t1" \
        --arg m2 "$m2" --arg u2 "$u2" --arg t2 "$t2" \
        --arg m3 "$m3" --arg u3 "$u3" --arg t3 "$t3" \
        '{storages:[{memory:$m1,used:$u1,total:$t1},
                    {memory:$m2,used:$u2,total:$t2},
                    {memory:$m3,used:$u3,total:$t3}]}'
}

parser_core_cpin()
{
    local response status_text has_error=false
    response=$(cat)
    status_text=$(printf '%s\n' "$response" | awk '/^[[:space:]]*\+(CPIN|CME ERROR):/ {
        sub(/\r$/, ""); sub(/^[[:space:]]+/, ""); print; exit
    }')
    printf '%s\n' "$response" | grep -q 'ERROR' && has_error=true
    [ -n "$status_text" ] || { qmodem_parser_error core.cpin parse_failed; return 1; }
    jq -cnS --arg status_text "$status_text" --argjson has_error "$has_error" \
        '{status_text:$status_text,has_error:$has_error}'
}

parser_core_simslot()
{
    local context="$1" vendor_name value
    vendor_name=$(printf '%s' "$context" | jq -r '.vendor // empty')
    case "$vendor_name" in
        quectel) value=$(awk -F':' '/\+(QUIMSLOT|QUSIMSLOT):/ {gsub(/[^0-9]/,"",$2); print $2; exit}') ;;
        fibocom) value=$(awk -F':' '/\+GTDUALSIM:/ {gsub(/[[:space:]\r]/,"",$2); print $2; exit}') ;;
        simcom) value=$(awk -F',' '/\+SMSIMCFG:/ {gsub(/[[:space:]\r]/,"",$2); print $2; exit}') ;;
        meig) value=$(awk -F'[:,]' '/\^SIMSLOT:/ {gsub(/[[:space:]\r]/,"",$3); print $3; exit}') ;;
        neoway) value=$(awk -F'[ ,]' '/\+SIMCROSS:/ {gsub(/[[:space:]\r]/,"",$2); print $2; exit}') ;;
        telit) value=$(awk -F',' '/#QSS:/ {gsub(/[[:space:]\r]/,"",$3); print $3; exit}') ;;
        qsimdet) value=$(awk -F':' '/\+QSIMDET:/ {gsub(/[[:space:]\r]/,"",$2); print $2; exit}') ;;
        gtdualsim) value=$(awk -F':' '/\+GTDUALSIM:/ {gsub(/[[:space:]\r]/,"",$2); print $2; exit}') ;;
        *) value=$(awk -F':' '/\+(QSIMDET|GTDUALSIM):/ {gsub(/[[:space:]\r]/,"",$2); print $2; exit}') ;;
    esac
    [ -n "$value" ] || { qmodem_parser_error core.simslot parse_failed; return 1; }
    qmodem_parser_string slot_code "$value"
}

parser_core_error_status()
{
    local response has_error=false
    response=$(cat)
    printf '%s\n' "$response" | grep -q 'ERROR' && has_error=true
    jq -cnS --argjson has_error "$has_error" '{has_error:$has_error}'
}

parser_core_cops_numeric()
{
    local code
    code=$(awk -F',' '/^[[:space:]]*\+COPS:/ {
        gsub(/[[:space:]\r"]/, "", $3)
        if ($3 ~ /^[0-9]{5,6}$/) { print substr($3, 1, 5); exit }
    }')
    [ -n "$code" ] || { qmodem_parser_error core.cops.numeric parse_failed; return 1; }
    qmodem_parser_string plmn "$code"
}

parser_core_cnmp()
{
    local mode
    mode=$(awk -F':' '/^[[:space:]]*\+CNMP:/ {
        gsub(/[[:space:]\r]/, "", $2); print $2; exit
    }')
    [ -n "$mode" ] || { qmodem_parser_error core.cnmp parse_failed; return 1; }
    qmodem_parser_string mode "$mode"
}

parser_core_setautodial()
{
    local values status mode
    values=$(awk -F':' '/SETAUTO/ {gsub(/[[:space:]\r]/, "", $2); print $2; exit}')
    [ -n "$values" ] || { qmodem_parser_error core.setautodial parse_failed; return 1; }
    status=${values%%,*}
    mode=${values#*,}
    [ "$mode" = "$values" ] && mode=
    jq -cnS --arg status "$status" --arg mode "$mode" '{enabled:$status,mode:$mode}'
}

parser_core_quectel_ethernet()
{
    local context="$1" kind enabled=false response
    response=$(cat)
    kind=$(printf '%s' "$context" | jq -r '.kind // empty')
    case "$kind" in
        ethernet) printf '%s\n' "$response" | grep -q '"ethernet",1' && enabled=true ;;
        eth_driver) printf '%s\n' "$response" | grep -q '"r8125",1' && enabled=true ;;
        data_interface) printf '%s\n' "$response" | grep -q '"data_interface",1' && enabled=true ;;
        *) qmodem_parser_error core.quectel.ethernet invalid_context; return 1 ;;
    esac
    jq -cnS --argjson enabled "$enabled" '{enabled:$enabled}'
}
