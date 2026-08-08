#!/bin/sh
# Copyright (C) 2023 Siriling <siriling@qq.com>
# Copyright (C) 2025 sfwtw
_Vendor="meig"
_Author="Siriling,sfwtw"
_Maintainer="sfwtw <unkown>"
source "${QMODEM_HOME:-/usr/share/qmodem}/generic.sh"
debug_subject="meig_ctrl"

_meig_parse()
{
    local parser_id="$1" raw="$2" context="$3"
    [ -n "$context" ] || context='{}'
    printf '%s' "$raw" | "${QMODEM_HOME:-/usr/share/qmodem}/parsers/parse.sh" \
        "$parser_id" --platform "${platform:-unknown}" --model "${model:-unknown}" --context-json "$context"
}

vendor_get_disabled_features(){
    json_add_string "" "NeighborCell"
    json_add_string "" "LockBand"
}

# Return raw data   
get_imei(){
    local raw parsed
    raw=$(cmd_cgsn "$at_port"); parsed=$(_meig_parse meig.cgsn "$raw")
    imei=$(printf '%s' "$parsed"|jq -r '.imei // empty')
    json_add_string "imei" "$imei"
}

set_imei(){
    local imei="$1"
    local raw parsed
    raw=$(cmd_lctsn_set_imei "$at_port" "$imei"); parsed=$(_meig_parse meig.lctsn.set "$raw")
    res=$(printf '%s' "$parsed"|jq -r '.result // empty')
    json_select "result"
    json_add_string "set_imei" "$res"
    json_close_object
    get_imei
}

# Get dial mode
get_mode()
{
    local raw parsed
    raw=$(cmd_ser_query "$at_port"); parsed=$(_meig_parse meig.ser "$raw")
    local mode_num=$(printf '%s' "$parsed"|jq -r '.mode_num // empty')
    local mode
    case "$platform" in
        "qualcomm")
            case "$mode_num" in
                "2") mode="ecm" ;;
                "3") mode="rndis" ;;
                "2") mode="ncm" ;;
                *) mode="${mode_num}" ;;
            esac
        ;;
        "lte12"|"lte")
            case "$mode_num" in
                "2") mode="ecm" ;;
                "3") mode="rndis" ;;
                "2") mode="ncm" ;;
                *) mode="${mode_num}" ;;
            esac
        ;;
        "unisoc")
            case "$mode_num" in
                "2") mode="ecm" ;;
                "3") mode="rndis" ;;
                "1") mode="ncm" ;;
                *) mode="${mode_num}" ;;
            esac
        ;;
        *)
            mode="${mode_num}"
        ;;
    esac
    available_modes=$(uci -q get qmodem.$config_section.modes)
    json_add_object "mode"
    for available_mode in $available_modes; do
        if [ "$mode" = "$available_mode" ]; then
            json_add_string "$available_mode" "1"
        else
            json_add_string "$available_mode" "0"
        fi
    done
    json_close_object
}

# Set dial mode
set_mode()
{
    local mode=$1
    case "$platform" in
        "qualcomm"|"lte12"|"lte")
            case "$mode" in
                "ecm") mode_num="2" ;;
                "rndis") mode_num="3" ;;
                "ncm") mode_num="2" ;;
                *) mode_num="1" ;;
            esac
        ;;
        "unisoc")
            case "$mode" in
                "ecm") mode_num="2" ;;
                "rndis") mode_num="3" ;;
                "ncm") mode_num="1" ;;
                *) mode_num="1" ;;
            esac
        ;;
        *)
            mode_num="1"
        ;;
    esac
    local raw parsed
    raw=$(cmd_ser_set "$at_port" "$mode_num"); parsed=$(_meig_parse meig.ser.set "$raw")
    res=$(printf '%s' "$parsed"|jq -r '.result // empty')
    json_select "result"
    json_add_string "set_mode" "$res"
    json_close_object
}

# Get network preference
get_network_prefer()
{
    local raw parsed
    raw=$(cmd_syscfgex_query "$at_port"); parsed=$(_meig_parse meig.syscfgex "$raw")
    local network_type_num=$(printf '%s' "$parsed"|jq -r '.rat_codes // empty')
    
    network_prefer_2g="0"
    network_prefer_3g="0"
    network_prefer_4g="0"
    network_prefer_5g="0"
    
    local auto=$(echo "${network_type_num}" | grep "00")
    if [ -n "$auto" ]; then
        network_prefer_2g="1"
        network_prefer_3g="1"
        network_prefer_4g="1"
        network_prefer_5g="1"
    else
        local gsm=$(echo "${network_type_num}" | grep "01")
        local wcdma=$(echo "${network_type_num}" | grep "02")
        local lte=$(echo "${network_type_num}" | grep "03")
        local nr=$(echo "${network_type_num}" | grep "04")
        if [ -n "$gsm" ]; then
            network_prefer_2g="1"
        fi
        if [ -n "$wcdma" ]; then
            network_prefer_3g="1"
        fi
        if [ -n "$lte" ]; then
            network_prefer_4g="1"
        fi
        if [ -n "$nr" ]; then
            network_prefer_5g="1"
        fi
    fi
    json_add_object network_prefer
    json_add_string 2G "$network_prefer_2g"
    json_add_string 3G "$network_prefer_3g"
    json_add_string 4G "$network_prefer_4g"
    json_add_string 5G "$network_prefer_5g"
    json_close_object
}

# Set network preference
set_network_prefer()
{
    local networks=$1
    local network_prefer_config=""
    network_prefer_3g=$(echo $1 |jq -r 'contains(["3G"])')
    network_prefer_4g=$(echo $1 |jq -r 'contains(["4G"])')
    network_prefer_5g=$(echo $1 |jq -r 'contains(["5G"])')
    if [ "$network_prefer_5g" = "true" ]; then
        network_prefer_config="${network_prefer_config}04"
    fi
    if [ "$network_prefer_4g" = "true" ]; then
        network_prefer_config="${network_prefer_config}03"
    fi
    if [ "$network_prefer_3g" = "true" ]; then
        network_prefer_config="${network_prefer_config}02"
    fi
    if [ -z "$network_prefer_config" ]; then
        network_prefer_config="00"
    fi
    local raw parsed
    raw=$(cmd_syscfgex_set "$at_port" "$network_prefer_config"); parsed=$(_meig_parse meig.syscfgex.set "$raw")
    res=$(printf '%s' "$parsed"|jq -r '.result // empty')
    json_select "result"
    json_add_string "set_network_prefer" "$res"
    json_close_object
}

get_voltage()
{
    # at_command="AT+CBC"
	# local voltage=$(at ${at_port} ${at_command} | grep "+CBC:" | awk -F',' '{print $3}' | sed 's/\r//g')
    [ -n "$voltage" ] && {
        add_plain_info_entry "voltage" "$voltage mV" "Voltage" 
    }
}

# Get temperature
get_temperature()
{   
    local response
    local temp
    local degree_symbol=$(printf "\xc2\xb0")C 

# 根据平台选择不同的AT命令并提取温度值
local raw parsed
raw=$(cmd_temp "$at_port"); parsed=$(_meig_parse meig.temp "$raw")
response=$(printf '%s' "$parsed"|jq -r '.temperature // empty')

# 处理响应值
if [ -n "$response" ]; then
    if [ "$platform" = "unisoc" ]; then
        # Unisoc平台需要将原始值除以1000并保留两位小数
        temp_value=$(echo "scale=2; $response / 1000" | bc)
        temp="${temp_value}${degree_symbol}"
    else
        # 其他平台直接使用原始值
        temp="${response}${degree_symbol}"
    fi
else
    # 无响应时显示NaN
    temp="NaN ${degree_symbol}"
    fi
    add_plain_info_entry "temperature" "$temp" "Temperature"
}

# Basic information
base_info()
{
    m_debug  "Meig base info"

    local raw parsed
    raw=$(cmd_cgmm "$at_port"); parsed=$(_meig_parse meig.cgmm "$raw"); name=$(printf '%s' "$parsed"|jq -r '.name // empty')
    raw=$(cmd_cgmi "$at_port"); parsed=$(_meig_parse meig.cgmi "$raw"); manufacturer=$(printf '%s' "$parsed"|jq -r '.manufacturer // empty')
    raw=$(cmd_cgmr "$at_port"); parsed=$(_meig_parse meig.cgmr "$raw"); revision=$(printf '%s' "$parsed"|jq -r '.revision // empty')
    class="Base Information"
    add_plain_info_entry "name" "$name" "Name"
    add_plain_info_entry "manufacturer" "$manufacturer" "Manufacturer"
    add_plain_info_entry "revision" "$revision" "Revision"
    add_plain_info_entry "at_port" "$at_port" "AT Port"
    get_temperature
    get_voltage
    get_connect_status
}

# SIM card information
sim_info()
{
    m_debug  "Meig sim info"
    
    local raw parsed
    raw=$(cmd_sims_slot_query "$at_port"); parsed=$(_meig_parse meig.simslot "$raw"); response=$(printf '%s' "$parsed"|jq -r '.slot_flag // empty')
    if [ "$response" != "0" ]; then
        sim_slot="1"
    else
        sim_slot="2"
    fi

    raw=$(cmd_cgsn "$at_port"); parsed=$(_meig_parse meig.cgsn "$raw"); imei=$(printf '%s' "$parsed"|jq -r '.imei // empty')

    raw=$(cmd_cpin_query "$at_port"); parsed=$(_meig_parse meig.cpin "$raw"); sim_status_flag=$(printf '%s' "$parsed"|jq -r '.status_line // empty')
    sim_status=$(get_sim_status "$sim_status_flag")

    if [ "$sim_status" != "ready" ]; then
        return
    fi

    raw=$(cmd_cops_query "$at_port"); parsed=$(_meig_parse meig.cops "$raw"); isp=$(printf '%s' "$parsed"|jq -r '.operator // empty')

    raw=$(cmd_cnum "$at_port"); parsed=$(_meig_parse meig.cnum "$raw"); sim_number=$(printf '%s' "$parsed"|jq -r '.number // empty')

    raw=$(cmd_cimi "$at_port"); parsed=$(_meig_parse meig.cimi "$raw"); imsi=$(printf '%s' "$parsed"|jq -r '.imsi // empty')

    raw=$(cmd_iccid "$at_port"); parsed=$(_meig_parse meig.iccid "$raw"); iccid=$(printf '%s' "$parsed"|jq -r '.iccid // empty')
    class="SIM Information"
    case "$sim_status" in
        "ready")
            add_plain_info_entry "SIM Status" "$sim_status" "SIM Status" 
            add_plain_info_entry "ISP" "$isp" "Internet Service Provider"
            add_plain_info_entry "SIM Slot" "$sim_slot" "SIM Slot"
            add_plain_info_entry "SIM Number" "$sim_number" "SIM Number"
            add_plain_info_entry "IMEI" "$imei" "International Mobile Equipment Identity" 
            add_plain_info_entry "IMSI" "$imsi" "International Mobile Subscriber Identity" 
            add_plain_info_entry "ICCID" "$iccid" "Integrate Circuit Card Identity" 
        ;;
        "miss")
            add_plain_info_entry "SIM Status" "$sim_status" "SIM Status" 
            add_plain_info_entry "IMEI" "$imei" "International Mobile Equipment Identity" 
        ;;
        "unknown")
            add_plain_info_entry "SIM Status" "$sim_status" "SIM Status" 
        ;;
        *)
            add_plain_info_entry "SIM Status" "$sim_status" "SIM Status" 
            add_plain_info_entry "SIM Slot" "$sim_slot" "SIM Slot" 
            add_plain_info_entry "IMEI" "$imei" "International Mobile Equipment Identity" 
            add_plain_info_entry "IMSI" "$imsi" "International Mobile Subscriber Identity" 
            add_plain_info_entry "ICCID" "$iccid" "Integrate Circuit Card Identity" 
        ;;
    esac
}

# Network information
network_info()
{
    m_debug  "Meig network info"

    local raw parsed response_path
    raw=$(cmd_sysinfoex "$at_port"); parsed=$(_meig_parse meig.sysinfoex "$raw"); network_type=$(printf '%s' "$parsed"|jq -r '.network_type // empty')

    [ -z "$network_type" ] && {
        raw=$(cmd_cops_query "$at_port"); parsed=$(_meig_parse meig.cops "$raw")
        local rat_num=$(printf '%s' "$parsed"|jq -r '.rat_code // empty')
        network_type=$(get_rat ${rat_num})
    }

    raw=$(cmd_csq "$at_port"); parsed=$(_meig_parse meig.csq "$raw"); response=$(printf '%s' "$parsed"|jq -r '.value // empty')

    raw=$(cmd_dsambr "$at_port" "${pdp_index:-1}"); parsed=$(_meig_parse meig.dsambr "$raw")
    case "$network_type" in
        "NR") response_path='.nr' ;;
        *) response_path='.lte' ;;
    esac
    ambr_ul_tmp=$(printf '%s' "$parsed"|jq -r "$response_path.uplink_kbps // \"0\"")
    ambr_dl_tmp=$(printf '%s' "$parsed"|jq -r "$response_path.downlink_kbps // \"0\"")

    [ -z "$ambr_ul_tmp" ] || [ "$ambr_ul_tmp" = "0" ] || ! echo "$ambr_ul_tmp" | grep -q '^[0-9.]*$' && ambr_ul_tmp="0"
    [ -z "$ambr_dl_tmp" ] || [ "$ambr_dl_tmp" = "0" ] || ! echo "$ambr_dl_tmp" | grep -q '^[0-9.]*$' && ambr_dl_tmp="0"
    
    if [ "$ambr_ul_tmp" = "0" ]; then
        ambr_ul="0"
    else
        ambr_ul=$(awk "BEGIN{ printf \"%.2f\", $ambr_ul_tmp / 1024 }" 2>/dev/null || echo "0")
        ambr_ul=$(echo "$ambr_ul" | sed 's/\.*0*$//')
        [ -z "$ambr_ul" ] && ambr_ul="0"
    fi
    
    if [ "$ambr_dl_tmp" = "0" ]; then
        ambr_dl="0"
    else
        ambr_dl=$(awk "BEGIN{ printf \"%.2f\", $ambr_dl_tmp / 1024 }" 2>/dev/null || echo "0")
        ambr_dl=$(echo "$ambr_dl" | sed 's/\.*0*$//')
        [ -z "$ambr_dl" ] && ambr_dl="0"
    fi

    raw=$(cmd_dsflowqry "$at_port"); parsed=$(_meig_parse meig.dsflowqry "$raw")
    tx_rate=$(printf '%s' "$parsed"|jq -r '.tx_rate // "0"')
    rx_rate=$(printf '%s' "$parsed"|jq -r '.rx_rate // "0"')
    
    [ -z "$tx_rate" ] || ! echo "$tx_rate" | grep -q '^[0-9]*$' && tx_rate="0"
    [ -z "$rx_rate" ] || ! echo "$rx_rate" | grep -q '^[0-9]*$' && rx_rate="0"
    
    class="Network Information"
    add_plain_info_entry "Network Type" "$network_type" "Network Type"
    add_plain_info_entry "AMBR UL" "$ambr_ul" "Access Maximum Bit Rate for Uplink"
    add_plain_info_entry "AMBR DL" "$ambr_dl" "Access Maximum Bit Rate for Downlink"
    add_speed_entry rx $rx_rate
    add_speed_entry tx $tx_rate
}

# Cell information
cell_info()
{
    m_debug  "Meig cell info"

    local raw parsed
    raw=$(cmd_cellinfo "$at_port" "${pdp_index:-1}"); parsed=$(_meig_parse meig.cellinfo "$raw")
    local rat
    network_mode="Unknown Mode"
    rat=$(printf '%s' "$parsed"|jq -r '.rat // empty')
    
    case $rat in
        "5G")
            network_mode="NR5G-SA Mode"
            nr_duplex_mode=$(printf '%s' "$parsed"|jq -r '.nr.duplex_mode')
            nr_mcc=$(printf '%s' "$parsed"|jq -r '.nr.mcc')
            nr_mnc=$(printf '%s' "$parsed"|jq -r '.nr.mnc')
            nr_cell_id=$(printf '%s' "$parsed"|jq -r '.nr.cell_id')
            nr_physical_cell_id=$(printf '%s' "$parsed"|jq -r '.nr.physical_cell_id')
            nr_tac=$(printf '%s' "$parsed"|jq -r '.nr.tac')
            nr_band_num=$(printf '%s' "$parsed"|jq -r '.nr.band_num')
            nr_band=$(get_band "NR" "$nr_band_num")
            nr_dl_bandwidth_num=$(printf '%s' "$parsed"|jq -r '.nr.dl_bandwidth_num')
            nr_dl_bandwidth=$(get_bandwidth "NR" "$nr_dl_bandwidth_num")
            nr_scs=$(printf '%s' "$parsed"|jq -r '.nr.scs')
            nr_rsrp=$(printf '%s' "$parsed"|jq -r '.nr.rsrp')
            nr_rsrq=$(printf '%s' "$parsed"|jq -r '.nr.rsrq')
            nr_sinr_num=$(printf '%s' "$parsed"|jq -r '.nr.sinr_tenths')
            
            if [ -n "$nr_sinr_num" ] && echo "$nr_sinr_num" | grep -q '^[0-9.-]*$'; then
                nr_sinr=$(awk "BEGIN{ print $nr_sinr_num / 10 }" 2>/dev/null || echo "0")
            else
                nr_sinr="0"
            fi
        ;;
        "LTE-NR")
            network_mode="EN-DC Mode"
            endc_lte_duplex_mode=$(printf '%s' "$parsed"|jq -r '.endc.lte.duplex_mode')
            endc_lte_mcc=$(printf '%s' "$parsed"|jq -r '.endc.lte.mcc')
            endc_lte_mnc=$(printf '%s' "$parsed"|jq -r '.endc.lte.mnc')
            endc_lte_physical_cell_id=$(printf '%s' "$parsed"|jq -r '.endc.lte.physical_cell_id')
            endc_lte_cell_id=$(printf '%s' "$parsed"|jq -r '.endc.lte.cell_id')
            endc_lte_tac=$(printf '%s' "$parsed"|jq -r '.endc.lte.tac')
            endc_lte_band_num=$(printf '%s' "$parsed"|jq -r '.endc.lte.band_num')
            endc_lte_band=$(get_band "LTE" "$endc_lte_band_num")
            ul_bandwidth_num=$(printf '%s' "$parsed"|jq -r '.endc.lte.ul_bandwidth_num')
            endc_lte_ul_bandwidth=$(get_bandwidth "LTE" "$ul_bandwidth_num")
            endc_lte_dl_bandwidth="$endc_lte_ul_bandwidth"
            endc_lte_rsrp=$(printf '%s' "$parsed"|jq -r '.endc.lte.rsrp')
            endc_lte_rsrq=$(printf '%s' "$parsed"|jq -r '.endc.lte.rsrq')
            endc_lte_sinr_num=$(printf '%s' "$parsed"|jq -r '.endc.lte.sinr_tenths')
            
            if [ -n "$endc_lte_sinr_num" ] && echo "$endc_lte_sinr_num" | grep -q '^[0-9.-]*$'; then
                endc_lte_sinr=$(awk "BEGIN{ print $endc_lte_sinr_num / 10 }" 2>/dev/null || echo "0")
            else
                endc_lte_sinr="0"
            fi
            
            endc_lte_tx_power=$(printf '%s' "$parsed"|jq -r '.endc.lte.tx_power')
            endc_nr_mcc="$endc_lte_mcc"
            endc_nr_mnc="$endc_lte_mnc"
            endc_nr_physical_cell_id=$(printf '%s' "$parsed"|jq -r '.endc.nr.physical_cell_id')
            endc_nr_rsrp=$(printf '%s' "$parsed"|jq -r '.endc.nr.rsrp')
            endc_nr_rsrq=$(printf '%s' "$parsed"|jq -r '.endc.nr.rsrq')
            endc_nr_sinr_num=$(printf '%s' "$parsed"|jq -r '.endc.nr.sinr_tenths')
            if [ -n "$endc_nr_sinr_num" ]; then
                if [ -n "$endc_nr_sinr_num" ] && echo "$endc_nr_sinr_num" | grep -q '^[0-9.-]*$'; then
                    endc_nr_sinr=$(awk "BEGIN{ print $endc_nr_sinr_num / 10 }" 2>/dev/null || echo "0")
                else
                    endc_nr_sinr="0"
                fi
            else
                endc_nr_sinr="0"
            fi
            
            endc_nr_band_num=$(printf '%s' "$parsed"|jq -r '.endc.nr.band_num')
            if [ -n "$endc_nr_band_num" ]; then
                endc_nr_band=$(get_band "NR" "$endc_nr_band_num")
            else
                endc_nr_band=""
            fi
            
            nr_dl_bandwidth_num=$(printf '%s' "$parsed"|jq -r '.endc.nr.dl_bandwidth_num')
            if [ -n "$nr_dl_bandwidth_num" ]; then
                endc_nr_dl_bandwidth=$(get_bandwidth "NR" "$nr_dl_bandwidth_num")
            else
                endc_nr_dl_bandwidth=""
            fi
            
            endc_nr_scs=$(printf '%s' "$parsed"|jq -r '.endc.nr.scs')
        ;;
        "LTE"|"eMTC"|"NB-IoT")
            network_mode="LTE Mode"
            lte_duplex_mode=$(printf '%s' "$parsed"|jq -r '.lte.duplex_mode')
            lte_mcc=$(printf '%s' "$parsed"|jq -r '.lte.mcc')
            lte_mnc=$(printf '%s' "$parsed"|jq -r '.lte.mnc')
            lte_physical_cell_id=$(printf '%s' "$parsed"|jq -r '.lte.physical_cell_id')
            lte_cell_id=$(printf '%s' "$parsed"|jq -r '.lte.cell_id')
            lte_tac=$(printf '%s' "$parsed"|jq -r '.lte.tac')
            lte_band_num=$(printf '%s' "$parsed"|jq -r '.lte.band_num')
            lte_band=$(get_band "LTE" "$lte_band_num")
            ul_bandwidth_num=$(printf '%s' "$parsed"|jq -r '.lte.ul_bandwidth_num')
            lte_ul_bandwidth=$(get_bandwidth "LTE" "$ul_bandwidth_num")
            lte_dl_bandwidth="$lte_ul_bandwidth"
            lte_rsrp=$(printf '%s' "$parsed"|jq -r '.lte.rsrp')
            lte_rsrq=$(printf '%s' "$parsed"|jq -r '.lte.rsrq')
            lte_sinr_num=$(printf '%s' "$parsed"|jq -r '.lte.sinr_tenths')
            
            if [ -n "$lte_sinr_num" ] && echo "$lte_sinr_num" | grep -q '^[0-9.-]*$'; then
                lte_sinr=$(awk "BEGIN{ print $lte_sinr_num / 10 }" 2>/dev/null || echo "0")
            else
                lte_sinr="0"
            fi
            
            lte_tx_power=$(printf '%s' "$parsed"|jq -r '.lte.tx_power')
        ;;
        "WCDMA"|"UMTS")
            network_mode="WCDMA Mode"
            wcdma_mcc=$(printf '%s' "$parsed"|jq -r '.wcdma.mcc')
            wcdma_mnc=$(printf '%s' "$parsed"|jq -r '.wcdma.mnc')
            wcdma_psc=$(printf '%s' "$parsed"|jq -r '.wcdma.psc')
            wcdma_cell_id=$(printf '%s' "$parsed"|jq -r '.wcdma.cell_id')
            wcdma_lac=$(printf '%s' "$parsed"|jq -r '.wcdma.lac')
            wcdma_band_num=$(printf '%s' "$parsed"|jq -r '.wcdma.band_num')
            wcdma_band=$(get_band "WCDMA" "$wcdma_band_num")
            
            wcdma_ecio=$(printf '%s' "$parsed"|jq -r '.wcdma.ecio')
            wcdma_rscp=$(printf '%s' "$parsed"|jq -r '.wcdma.rscp')
        ;;
    esac
    
    class="Cell Information"
    add_plain_info_entry "network_mode" "$network_mode" "Network Mode"
    case $network_mode in
    "NR5G-SA Mode")
        add_plain_info_entry "MMC" "$nr_mcc" "Mobile Country Code"
        add_plain_info_entry "MNC" "$nr_mnc" "Mobile Network Code"
        add_plain_info_entry "Duplex Mode" "$nr_duplex_mode" "Duplex Mode"
        add_plain_info_entry "Cell ID" "$nr_cell_id" "Cell ID"
        add_plain_info_entry "Physical Cell ID" "$nr_physical_cell_id" "Physical Cell ID"
        add_plain_info_entry "TAC" "$nr_tac" "Tracking area code"
        add_plain_info_entry "Band" "$nr_band" "Band"
        add_plain_info_entry "DL Bandwidth" "$nr_dl_bandwidth" "DL Bandwidth"
        add_bar_info_entry "RSRP" "$nr_rsrp" "Reference Signal Received Power" -140 -44 dBm
        add_bar_info_entry "RSRQ" "$nr_rsrq" "Reference Signal Received Quality" -19.5 -3 dB
        add_bar_info_entry "SINR" "$nr_sinr" "Signal to Interference plus Noise Ratio" 0 30 dB
        add_plain_info_entry "SCS" "$nr_scs" "SCS"
        ;;
    "EN-DC Mode")
        add_plain_info_entry "LTE" "LTE" ""
        add_plain_info_entry "MCC" "$endc_lte_mcc" "Mobile Country Code"
        add_plain_info_entry "MNC" "$endc_lte_mnc" "Mobile Network Code"
        add_plain_info_entry "Duplex Mode" "$endc_lte_duplex_mode" "Duplex Mode"
        add_plain_info_entry "Cell ID" "$endc_lte_cell_id" "Cell ID"
        add_plain_info_entry "Physical Cell ID" "$endc_lte_physical_cell_id" "Physical Cell ID"
        add_plain_info_entry "TAC" "$endc_lte_tac" "Tracking area code"
        add_plain_info_entry "Band" "$endc_lte_band" "Band"
        add_plain_info_entry "UL Bandwidth" "$endc_lte_ul_bandwidth" "UL Bandwidth"
        add_plain_info_entry "DL Bandwidth" "$endc_lte_dl_bandwidth" "DL Bandwidth"
        add_bar_info_entry "RSRP" "$endc_lte_rsrp" "Reference Signal Received Power" -140 -44 dBm
        add_bar_info_entry "RSRQ" "$endc_lte_rsrq" "Reference Signal Received Quality" -19.5 -3 dB
        add_bar_info_entry "SINR" "$endc_lte_sinr" "Signal to Interference plus Noise Ratio" 0 30 dB
        add_plain_info_entry "TX Power" "$endc_lte_tx_power" "TX Power"
        if [ -n "$endc_nr_physical_cell_id" ] || [ -n "$endc_nr_band" ]; then
            add_plain_info_entry "NR5G-NSA" "NR5G-NSA" ""
            add_plain_info_entry "MCC" "$endc_nr_mcc" "Mobile Country Code"
            add_plain_info_entry "MNC" "$endc_nr_mnc" "Mobile Network Code"
            [ -n "$endc_nr_physical_cell_id" ] && add_plain_info_entry "Physical Cell ID" "$endc_nr_physical_cell_id" "Physical Cell ID"
            [ -n "$endc_nr_band" ] && add_plain_info_entry "Band" "$endc_nr_band" "Band"
            [ -n "$endc_nr_dl_bandwidth" ] && add_plain_info_entry "DL Bandwidth" "$endc_nr_dl_bandwidth" "DL Bandwidth"
            [ -n "$endc_nr_rsrp" ] && add_bar_info_entry "RSRP" "$endc_nr_rsrp" "Reference Signal Received Power" -140 -44 dBm
            [ -n "$endc_nr_rsrq" ] && add_bar_info_entry "RSRQ" "$endc_nr_rsrq" "Reference Signal Received Quality" -19.5 -3 dB
            [ -n "$endc_nr_sinr" ] && add_bar_info_entry "SINR" "$endc_nr_sinr" "Signal to Interference plus Noise Ratio" 0 30 dB
            [ -n "$endc_nr_scs" ] && add_plain_info_entry "SCS" "$endc_nr_scs" "SCS"
        fi
        ;;
    "LTE Mode")
        add_plain_info_entry "MCC" "$lte_mcc" "Mobile Country Code"
        add_plain_info_entry "MNC" "$lte_mnc" "Mobile Network Code"
        add_plain_info_entry "Duplex Mode" "$lte_duplex_mode" "Duplex Mode"
        add_plain_info_entry "Cell ID" "$lte_cell_id" "Cell ID"
        add_plain_info_entry "Physical Cell ID" "$lte_physical_cell_id" "Physical Cell ID"
        add_plain_info_entry "TAC" "$lte_tac" "Tracking area code"
        add_plain_info_entry "Band" "$lte_band" "Band"
        add_plain_info_entry "UL Bandwidth" "$lte_ul_bandwidth" "UL Bandwidth"
        add_plain_info_entry "DL Bandwidth" "$lte_dl_bandwidth" "DL Bandwidth"
        add_bar_info_entry "RSRP" "$lte_rsrp" "Reference Signal Received Power" -140 -44 dBm
        add_bar_info_entry "RSRQ" "$lte_rsrq" "Reference Signal Received Quality" -19.5 -3 dB
        add_bar_info_entry "SINR" "$lte_sinr" "Signal to Interference plus Noise Ratio" 0 30 dB
        [ -n "$lte_tx_power" ] && add_plain_info_entry "TX Power" "$lte_tx_power" "TX Power"
        ;;
    "WCDMA Mode")
        add_plain_info_entry "MCC" "$wcdma_mcc" "Mobile Country Code"
        add_plain_info_entry "MNC" "$wcdma_mnc" "Mobile Network Code"
        add_plain_info_entry "LAC" "$wcdma_lac" "Location Area Code"
        add_plain_info_entry "Cell ID" "$wcdma_cell_id" "Cell ID"
        add_plain_info_entry "PSC" "$wcdma_psc" "Primary Scrambling Code"
        add_plain_info_entry "Band" "$wcdma_band" "Band"
        [ -n "$wcdma_rscp" ] && add_bar_info_entry "RSCP" "$wcdma_rscp" "Received Signal Code Power" -120 -25 dBm
        [ -n "$wcdma_ecio" ] && add_plain_info_entry "Ec/Io" "$wcdma_ecio" "Ec/Io"
        ;;
    esac
}

get_band()
{
    local network_type="$1"
    local band_num="$2"
    local band="0"
    
    if [ -z "$band_num" ] || ! echo "$band_num" | grep -q '^[0-9]*$'; then
        band="0"
    else
        case $network_type in
            "WCDMA"|"LTE"|"NR") band="$band_num" ;;
            *) band="0" ;;
        esac
    fi
    
    echo "$band"
}

get_bandwidth()
{
    local network_type="$1"
    local bandwidth_num="$2"
    local bandwidth="0"
    
    if [ -z "$bandwidth_num" ] || ! echo "$bandwidth_num" | grep -q '^[0-9]*$'; then
        bandwidth="0"
    else
        case $network_type in
            "LTE") 
                if [ "$bandwidth_num" -gt 0 ]; then
                    bandwidth=$((bandwidth_num / 5))
                fi
                ;;
            "NR") bandwidth="$bandwidth_num" ;;
            *) bandwidth="0" ;;
        esac
    fi
    
    echo "$bandwidth"
}
