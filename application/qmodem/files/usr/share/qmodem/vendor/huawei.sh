#!/bin/sh
# Copyright (C) 2025 coolsnowwolf <coolsnowwolf@gmail.com>
_Vendor="huawei"
_Author="Lean"
_Maintainer="Lean <coolsnowwolf@gmail.com>"
. "${QMODEM_HOME:-/usr/share/qmodem}/generic.sh"
debug_subject="huawei_ctrl"

_huawei_parse()
{
    local parser_id="$1" raw="$2" context="$3"
    [ -n "$context" ] || context='{}'
    printf '%s' "$raw" | "${QMODEM_HOME:-/usr/share/qmodem}/parsers/parse.sh" \
        "$parser_id" --platform "${platform:-unknown}" --model "${model:-unknown}" --context-json "$context"
}

vendor_get_disabled_features(){
    case "$platform" in
        *)
            json_add_string "" "LockBand"
            json_add_string "" "NeighborCell"
            ;;
    esac
}

get_imei(){
    local raw parsed
    raw=$(cmd_cgsn "$at_port"); parsed=$(_huawei_parse huawei.cgsn "$raw")
    imei=$(printf '%s' "$parsed" | jq -r '.imei // empty')
    json_add_string imei $imei
}

set_imei(){
    imei=$1
    local raw parsed
    raw=$(cmd_phynum_set_imei "$at_port" "$imei"); parsed=$(_huawei_parse huawei.phynum.set "$raw")
    res=$(printf '%s' "$parsed" | jq -r '.result // empty')
    json_add_string "result" "$res"
}

get_mode(){
    local raw parsed
    raw=$(cmd_setmode_query "$at_port"); parsed=$(_huawei_parse huawei.setmode "$raw")
    cfg=$(printf '%s' "$parsed" | jq -r '.mode_num // empty')
    
    case $platform in
        "unisoc")
            local mode_num="$cfg"
            case $mode_num in
                "0") mode="rndis" ;;
                "1") mode="ecm" ;;
                "2") mode="ncm" ;;
                *) mode="rndis" ;;
            esac
            ;;
        *)
            local mode_num="$cfg"
            case "$mode_num" in
            "0"|"2") mode="ecm" ;;
            "1"|"3"|"4"|"5") mode="ncm" ;;
            "6") mode="rndis" ;;
            "7") mode="mbim" ;;
            "8") mode="ppp" ;;
            *) mode="rndis" ;;
    esac
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

set_mode(){
    local mode=$1
    local mode_num
    case "$platform" in
        "unisoc")
            case $mode in
                "rndis")
                    mode_num="0"
                    ;;
                "ecm")
                    mode_num="1"
                    ;;
                "ncm")
                    mode_num="2"
                    ;;
            esac
            ;;
        *)
            case $mode in
                "ecm")
                    mode_num="0"
                    ;;
                "ncm")
                    mode_num="4"
                    ;;
                *)
                    mode_num="0"
                    ;;
            esac
        ;;
    esac

    local raw parsed
    raw=$(cmd_setmode_set "$at_port" "$mode_num"); parsed=$(_huawei_parse huawei.setmode.set "$raw")
    res=$(printf '%s' "$parsed" | jq -r '.result // empty')
    json_add_string "cmd_result" "$res at $at_port AT^SETMODE=${mode_num}"
}

get_scs()
{
    local scs
    case $1 in
		"0") scs="15" ;;
		"1") scs="30" ;;
    "2") scs="60" ;;
    "3") scs="120" ;;
    "4") scs="240" ;;
    *) scs=$(awk "BEGIN{ print 2^$1 * 15 }") ;;
	esac
    echo "$scs"
}

get_network_prefer(){
    local raw parsed
    raw=$(cmd_syscfgex_query "$at_port"); parsed=$(_huawei_parse huawei.syscfgex "$raw")
    # (RAT index): 
    # • 00 – Automatic 
    # • 01 – UMTS 3G only 
    # • 04 – LTE only 
    # • 05 – 5G only 
    # • 0E – UMTS and LTE only 
    # • 0F – LTE and NR5G only 
    # • 10 – WCDMA and NR5G only 
   local network_type_num=$(printf '%s' "$parsed" | jq -r '.rat_codes // empty')
   
   #获取网络类型
   local network_prefer_3g="0"
   local network_prefer_4g="0"
   local network_prefer_5g="0"
   
   #匹配不同的网络类型
   local auto=$(echo "${network_type_num}" | grep "00")
   
   if [ -n "$auto" ]; then
      network_prefer_2g="1"
      network_prefer_3g="1"
      network_prefer_4g="1"
      network_prefer_5g="1"
   else
        local wcdma=$(echo "${network_type_num}" | grep "02")
        local lte=$(echo "${network_type_num}" | grep "03")
        local nr=$(echo "${network_type_num}" | grep "08")

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
    json_add_string 3G $network_prefer_3g
    json_add_string 4G $network_prefer_4g
    json_add_string 5G $network_prefer_5g
    json_close_array
}

set_network_prefer(){
    local network_prefer_3g=$(echo $1 |jq -r 'contains(["3G"])')
    local network_prefer_4g=$(echo $1 |jq -r 'contains(["4G"])')
    local network_prefer_5g=$(echo $1 |jq -r 'contains(["5G"])')
    count=$(echo $1 | jq -r 'length')
    case "$count" in
        "1")
            if [ "$network_prefer_3g" = "true" ]; then
                code="02"
            elif [ "$network_prefer_4g" = "true" ]; then
                code="03"
            elif [ "$network_prefer_5g" = "true" ]; then
                code="08"
            fi
            ;;
        "2")
            if [ "$network_prefer_3g" = "true" ] && [ "$network_prefer_4g" = "true" ]; then
                code="02"
            elif [ "$network_prefer_4g" = "true" ] && [ "$network_prefer_5g" = "true" ]; then
                code="03"
            elif [ "$network_prefer_3g" = "true" ] && [ "$network_prefer_5g" = "true" ]; then
                code="08"
            fi
            ;;
        "3")
            code="080302"
            ;;
        *)
            code="00"
            ;;
    esac
    
    local raw parsed
    raw=$(cmd_syscfgex_set "$at_port" "$code"); parsed=$(_huawei_parse huawei.syscfgex.set "$raw")
    res=$(printf '%s' "$parsed" | jq -r '.result // empty')
    json_add_string "code" "$code"
    json_add_string "result" "$res"
}

get_lockband(){
    json_add_object "lockband"
    case $platform in
        *)
            _get_lockband_nr
            ;;
    esac
    json_close_object
}

set_lockband(){
    config=$1
    band_class=$(echo $config | jq -r '.band_class')
    lock_band=$(echo $config | jq -r '.lock_band')
    case $platform in
        *)
            _set_lockband_nr
            ;;
    esac
}

sim_info()
{
    class="SIM Information"
    
    sim_slot=$(cat /tmp/huawei_sim_slot_$config_section)||sim_slot="0"

    #SIM Status（SIM状态）
    local raw parsed
    raw=$(cmd_cpin_query "$at_port"); parsed=$(_huawei_parse huawei.cpin "$raw")
    sim_status=$(printf '%s' "$parsed" | jq -r '.status_line // empty')
    if [[ "$sim_status" == "+CME ERROR:"* ]]; then
        sim_status="not inserted"
    else
        sim_status=${sim_status:7:-1}
        #lowercase
        sim_status=$(echo $sim_status | tr  A-Z a-z)
    fi

    #SIM Number（SIM卡号码，手机号）
    raw=$(cmd_cnum "$at_port"); parsed=$(_huawei_parse huawei.cnum "$raw")
    sim_number=$(printf '%s' "$parsed" | jq -r '.primary_number // empty')
    [ -z "$sim_number" ] && {
      raw=$(cmd_cnum "$at_port"); parsed=$(_huawei_parse huawei.cnum "$raw")
      sim_number=$(printf '%s' "$parsed" | jq -r '.fallback_number // empty')
    }
    
    #IMSI（国际移动用户识别码）
    raw=$(cmd_cimi "$at_port"); parsed=$(_huawei_parse huawei.cimi "$raw")
    imsi=$(printf '%s' "$parsed" | jq -r '.imsi // empty')
    
    #IMEI（国际移动设备识别码）
    raw=$(cmd_cgsn "$at_port"); parsed=$(_huawei_parse huawei.cgsn "$raw")
    imei=$(printf '%s' "$parsed" | jq -r '.imei // empty')
    
    add_plain_info_entry "SIM Status" "$sim_status" "SIM Status" 
    add_plain_info_entry "SIM Slot" "$sim_slot" "SIM Slot"
    add_plain_info_entry "SIM Number" "$sim_number" "SIM Number"
    add_plain_info_entry "IMEI" "$imei" "International Mobile Equipment Identity"
    add_plain_info_entry "IMSI" "$imsi" "International Mobile Subscriber Identity"
}

base_info(){
     #Name（名称）
    local raw parsed
    raw=$(cmd_cgmm "$at_port"); parsed=$(_huawei_parse huawei.cgmm "$raw"); name=$(printf '%s' "$parsed"|jq -r '.name // empty')
    #Manufacturer（制造商）
    raw=$(cmd_cgmi "$at_port"); parsed=$(_huawei_parse huawei.cgmi "$raw"); manufacturer=$(printf '%s' "$parsed"|jq -r '.manufacturer // empty')
    #Revision（固件版本）
    raw=$(cmd_ati "$at_port"); parsed=$(_huawei_parse huawei.ati "$raw"); revision=$(printf '%s' "$parsed"|jq -r '.revision // empty')
    # at_command="AT+CGMR"
    # revision=$(at $at_port $at_command | sed -n '2p' | sed 's/\r//g')
    class="Base Information"
    add_plain_info_entry "name" "$name" "Name"
    add_plain_info_entry "manufacturer" "$manufacturer" "Manufacturer"
    add_plain_info_entry "revision" "$revision" "Revision"
    add_plain_info_entry "at_port" "$at_port" "AT Port"
    get_connect_status
    _get_temperature
}

cell_info()
{
    case "$platform" in
        "unisoc")
            local raw parsed
            raw=$(cmd_monsc "$at_port"); parsed=$(_huawei_parse huawei.monsc "$raw")
            monsc_parsed="$parsed"
            raw=$(cmd_cserssi_query "$at_port"); parsed=$(_huawei_parse huawei.cserssi "$raw")
            second_cell_parsed="$parsed"
            raw=$(cmd_hfreqinfo_query "$at_port"); parsed=$(_huawei_parse huawei.hfreqinfo "$raw")
            hfreqinfo_response=$(printf '%s' "$parsed"|jq -r '.text // empty')
            _parse_hfreqinfo "$hfreqinfo_response"
            cell_rat=$(printf '%s' "$monsc_parsed" | jq -r '.rat // empty')
            [ "$(printf '%s' "$second_cell_parsed" | jq -r '.nr != null' 2>/dev/null)" = true ] && cell_rat="LTE-NR"
            case "$cell_rat" in
                "NR"|"NR-5GC")
                    # MCC/MNC.ARFCN/SCS/CellID/PhysicalCellID/TAC/RSRP/RSRQ/SINR
                    network_mode="NR5G-SA Mode"
                    nr_mode="NR-SA"
                    mcc=$(printf '%s' "$monsc_parsed" | jq -r '.mcc // empty')
                    mnc=$(printf '%s' "$monsc_parsed" | jq -r '.mnc // empty')
                    arfcn=$(printf '%s' "$monsc_parsed" | jq -r '.channel // empty')
                    scs_num=$(printf '%s' "$monsc_parsed" | jq -r '.nr.scs_code // empty')
                    scs=$(get_scs ${scs_num})
                    cid_hex=$(printf '%s' "$monsc_parsed" | jq -r '.nr.cell_id_hex // empty')
                    cid=$(echo "ibase=16; $cid_hex" | bc)
                    physical_cell_id_hex=$(printf '%s' "$monsc_parsed" | jq -r '.nr.pci_hex // empty')
                    physical_cell_id=$(echo "ibase=16; $physical_cell_id_hex" | bc)
                    tac=$(printf '%s' "$monsc_parsed" | jq -r '.nr.tac // empty')
                    nr_rsrp=$(printf '%s' "$monsc_parsed" | jq -r '.nr.rsrp // empty')
                    nr_rsrq=$(printf '%s' "$monsc_parsed" | jq -r '.nr.rsrq // empty')
                    nr_sinr=$(printf '%s' "$monsc_parsed" | jq -r '.nr.sinr // empty')
                ;;
                "LTE-NR")
                    network_mode="EN-DC Mode"
                    nr_mode="NR-NSA"
                    lte_mode="LTE"
                    #LTE monsc_response MCC/MNC/EARFCN/CellID/PhysicalCellID/TAC/RSRP/RSRQ/RxLev
                    mcc=$(printf '%s' "$monsc_parsed" | jq -r '.mcc // empty')
                    mnc=$(printf '%s' "$monsc_parsed" | jq -r '.mnc // empty')
                    earfcn=$(printf '%s' "$monsc_parsed" | jq -r '.channel // empty')
                    cell_id_hex=$(printf '%s' "$monsc_parsed" | jq -r '.lte.cell_id_hex // empty')
                    cell_id=$(echo "ibase=16; $cell_id_hex" | bc)
                    physical_cell_id_hex=$(printf '%s' "$monsc_parsed" | jq -r '.lte.pci_hex // empty')
                    physical_cell_id=$(echo "ibase=16; $physical_cell_id_hex" | bc)
                    tac=$(printf '%s' "$monsc_parsed" | jq -r '.lte.tac // empty')
                    lte_rsrp=$(printf '%s' "$monsc_parsed" | jq -r '.lte.rsrp // empty')
                    lte_rsrq=$(printf '%s' "$monsc_parsed" | jq -r '.lte.rsrq // empty')
                    lte_rxlev=$(printf '%s' "$monsc_parsed" | jq -r '.lte.rxlev // empty')
                    #NR second_cell_response RSRP(12)/RSRQ(13)/SINR(14)
                    second_nr_rsrp=$(printf '%s' "$second_cell_parsed" | jq -r '.nr.rsrp // empty')
                    second_nr_rsrq=$(printf '%s' "$second_cell_parsed" | jq -r '.nr.rsrq // empty')
                    second_nr_sinr=$(printf '%s' "$second_cell_parsed" | jq -r '.nr.sinr // empty')
                ;;
                "LTE"|"eMTC"|"NB-IoT")
                    network_mode="LTE Mode"
                    lte_mode="LTE"
                    #LTE monsc_response MCC/MNC/EARFCN/CellID/PhysicalCellID/TAC/RSRP/RSRQ/RxLev
                    mcc=$(printf '%s' "$monsc_parsed" | jq -r '.mcc // empty')
                    mnc=$(printf '%s' "$monsc_parsed" | jq -r '.mnc // empty')
                    earfcn=$(printf '%s' "$monsc_parsed" | jq -r '.channel // empty')
                    cell_id_hex=$(printf '%s' "$monsc_parsed" | jq -r '.lte.cell_id_hex // empty')
                    cell_id=$(echo "ibase=16; $cell_id_hex" | bc)
                    physical_cell_id_hex=$(printf '%s' "$monsc_parsed" | jq -r '.lte.pci_hex // empty')
                    physical_cell_id=$(echo "ibase=16; $physical_cell_id_hex" | bc)
                    tac=$(printf '%s' "$monsc_parsed" | jq -r '.lte.tac // empty')
                    lte_rsrp=$(printf '%s' "$monsc_parsed" | jq -r '.lte.rsrp // empty')
                    lte_rsrq=$(printf '%s' "$monsc_parsed" | jq -r '.lte.rsrq // empty')
                    lte_rxlev=$(printf '%s' "$monsc_parsed" | jq -r '.lte.rxlev // empty')
                ;;
                "WCDMA"|"TD-SCDMA"|"UMTS")
                    network_mode="WCDMA Mode"
                    wcdma_mode="WCDMA"
                    # MCC/MNC/ARFCN/PSC/CellID/LAC/RSCP/RxLev/ECN0/DRX/URA
                    mcc=$(printf '%s' "$monsc_parsed" | jq -r '.mcc // empty')
                    mnc=$(printf '%s' "$monsc_parsed" | jq -r '.mnc // empty')
                    arfcn=$(printf '%s' "$monsc_parsed" | jq -r '.channel // empty')
                    psc=$(printf '%s' "$monsc_parsed" | jq -r '.wcdma.psc // empty')
                    cell_id_hex=$(printf '%s' "$monsc_parsed" | jq -r '.wcdma.cell_id_hex // empty')
                    cell_id=$(echo "ibase=16; $cell_id_hex" | bc)
                    lac=$(printf '%s' "$monsc_parsed" | jq -r '.wcdma.lac // empty')
                    rscp=$(printf '%s' "$monsc_parsed" | jq -r '.wcdma.rscp // empty')
                    wcdma_rxlev=$(printf '%s' "$monsc_parsed" | jq -r '.wcdma.rxlev // empty')
                    ecn0=$(printf '%s' "$monsc_parsed" | jq -r '.wcdma.ecn0 // empty')
                    drx=$(printf '%s' "$monsc_parsed" | jq -r '.wcdma.drx // empty')
                    ura=$(printf '%s' "$monsc_parsed" | jq -r '.wcdma.ura // empty')
                ;;
                "GSM")
                    network_mode="GSM Mode"
                    #Unsupported   
                    ;;
            esac
            class="Cell Information"
            add_plain_info_entry "network_mode" "$network_mode" "Network Mode"
            # add primary serving cell info
            add_plain_info_entry "MCC" "$mcc" "Mobile Country Code"
            add_plain_info_entry "MNC" "$mnc" "Mobile Network Code"
            add_plain_info_entry "Duplex Mode" "$duplex_mode" "Duplex Mode"
            add_plain_info_entry "Cell ID" "$cell_id" "Cell ID"
            add_plain_info_entry "Physical Cell ID" "$physical_cell_id" "Physical Cell ID"
            add_plain_info_entry "TAC" "$tac" "Tracking area code of cell served by neighbor Enb"
            add_plain_info_entry "ARFCN/EARFCN" "$arfcn" "Absolute Radio-Frequency Channel Number"
            add_plain_info_entry "Band" "$band" "Band"
            add_plain_info_entry "DL Bandwidth" "$dl_bandwidth" "DL Bandwidth"
            #WCDMA
            add_plain_info_entry "WCDMA_INFO" "$wcdma_mode" "WCDMA Information"
            add_bar_info_entry "RSCP" "$rscp" "Received Signal Code Power" -120 -25 dBm
            add_bar_info_entry "ECN0" "$ecn0" "Energy per Chip over Noise" -24 0 dBm
            add_bar_info_entry "DRX" "$drx" "Discontinuous Reception" 0 7 dBm
            add_bar_info_entry "RxLev" "$wcdma_rxlev" "Received Signal Level" -120 -25 dBm
            #LTE
            add_plain_info_entry "LTE_INFO" "$lte_mode" "LTE Information"
            add_plain_info_entry "LTE_BAND" "$LTE_INFO_BAND" "LTE Band"
            add_plain_info_entry "LTE_DL" "$LTE_INFO_DL" "LTE DL"
            add_plain_info_entry "LTE_UL" "$LTE_INFO_UL" "LTE UL"
            extra_info="LTE"
            add_bar_info_entry "RSRP" "$lte_rsrp" "Reference Signal Received Power" -140 -44 dBm
            add_bar_info_entry "RSRQ" "$lte_rsrq" "Reference Signal Received Quality" -44 3 dBm
            add_bar_info_entry "SINR" "$nr_sinr" "Signal to Interference plus Noise Ratio Bandwidth" -120 25 dBm
            add_bar_info_entry "RxLev" "$lte_rxlev" "Received Signal Level" -120 -25 dBm
            unset extra_info
            #NR
            extra_info="$nr_mode"
            add_plain_info_entry "${nr_mode}_INFO" "$nr_mode" "Information"
            add_plain_info_entry "${nr_mode}_BAND" "$NR_INFO_BAND" "NR Band"
            add_plain_info_entry "${nr_mode}_DL" "$NR_INFO_DL" "DL"
            add_plain_info_entry "${nr_mode}_UL" "$NR_INFO_UL" "UL"
            add_bar_info_entry "RSRP" "$nr_rsrp" "Reference Signal Received Power" -156 -31 dBm
            add_bar_info_entry "RSRQ" "$nr_rsrq" "Reference Signal Received Quality" -43 20 dBm
            add_bar_info_entry "SINR" "$nr_sinr" "Signal to Interference plus Noise Ratio Bandwidth" -23 40 dBm
            #NR-NSA
            add_bar_info_entry "RSRP" "$second_nr_rsrp" "Reference Signal Received Power" -156 -31 dBm
            add_bar_info_entry "RSRQ" "$second_nr_rsrq" "Reference Signal Received Quality" -43 20 dBm
            add_bar_info_entry "SINR" "$second_nr_sinr" "Signal to Interference plus Noise Ratio Bandwidth" -23 40 dBm
            unset extra_info
            ;;
        *)
            local raw parsed
            raw=$(cmd_monsc "$at_port"); parsed=$(_huawei_parse huawei.monsc "$raw")
            monsc_parsed="$parsed"
            cell_rat=$(printf '%s' "$monsc_parsed" | jq -r '.rat // empty')
            case $cell_rat in
                "NR"|"NR-5GC")
                    network_mode="NR5G-SA Mode"
                    nr_mcc=$(printf '%s' "$monsc_parsed" | jq -r '.mcc // empty')
                    nr_mnc=$(printf '%s' "$monsc_parsed" | jq -r '.mnc // empty')
                    nr_arfcn=$(printf '%s' "$monsc_parsed" | jq -r '.channel // empty')
                    nr_scs_num=$(printf '%s' "$monsc_parsed" | jq -r '.nr.scs_code // empty')
                    nr_scs=$(get_scs ${nr_scs_num})
                    nr_cell_id_hex=$(printf '%s' "$monsc_parsed" | jq -r '.nr.cell_id_hex // empty')
                    nr_cell_id=$(echo "ibase=16; $nr_cell_id_hex" | bc)
                    nr_physical_cell_id_hex=$(printf '%s' "$monsc_parsed" | jq -r '.nr.pci_hex // empty')
                    nr_physical_cell_id=$(echo "ibase=16; $nr_physical_cell_id_hex" | bc)
                    nr_tac=$(printf '%s' "$monsc_parsed" | jq -r '.nr.tac // empty')
                    nr_rsrp=$(printf '%s' "$monsc_parsed" | jq -r '.nr.rsrp // empty')
                    nr_rsrq=$(printf '%s' "$monsc_parsed" | jq -r '.nr.rsrq // empty')
                    nr_sinr=$(printf '%s' "$monsc_parsed" | jq -r '.nr.sinr // empty')
                ;;
                "LTE-NR")
                    raw=$(cmd_cserssi_query "$at_port"); parsed=$(_huawei_parse huawei.cserssi "$raw")
                    nr_parsed="$parsed"
                    network_mode="EN-DC Mode"
                    #LTE
                    endc_lte_mcc=$(printf '%s' "$monsc_parsed" | jq -r '.mcc // empty')
                    endc_lte_mnc=$(printf '%s' "$monsc_parsed" | jq -r '.mnc // empty')
                    endc_lte_earfcn=$(printf '%s' "$monsc_parsed" | jq -r '.channel // empty')
                    endc_lte_cell_id_hex=$(printf '%s' "$monsc_parsed" | jq -r '.lte.cell_id_hex // empty')
                    endc_lte_cell_id=$(echo "ibase=16; $endc_lte_cell_id_hex" | bc)
                    endc_lte_physical_cell_id_hex=$(printf '%s' "$monsc_parsed" | jq -r '.lte.pci_hex // empty')
                    endc_lte_physical_cell_id=$(echo "ibase=16; $endc_lte_physical_cell_id_hex" | bc)
                    endc_lte_tac=$(printf '%s' "$monsc_parsed" | jq -r '.lte.tac // empty')
                    endc_lte_rsrp=$(printf '%s' "$monsc_parsed" | jq -r '.lte.rsrp // empty')
                    endc_lte_rsrq=$(printf '%s' "$monsc_parsed" | jq -r '.lte.rsrq // empty')
                    endc_lte_rxlev=$(printf '%s' "$monsc_parsed" | jq -r '.lte.rxlev // empty')
                    #NR5G-NSA
                    endc_nr_rsrp=$(printf '%s' "$nr_parsed" | jq -r '.nr.rsrp // empty')
                    endc_nr_rsrq=$(printf '%s' "$nr_parsed" | jq -r '.nr.rsrq // empty')
                    endc_nr_sinr=$(printf '%s' "$nr_parsed" | jq -r '.nr.sinr // empty')
                ;;
                "LTE"|"eMTC"|"NB-IoT")
                    network_mode="LTE Mode"
                    lte_mcc=$(printf '%s' "$monsc_parsed" | jq -r '.mcc // empty')
                    lte_mnc=$(printf '%s' "$monsc_parsed" | jq -r '.mnc // empty')
                    lte_earfcn=$(printf '%s' "$monsc_parsed" | jq -r '.channel // empty')
                    lte_cell_id_hex=$(printf '%s' "$monsc_parsed" | jq -r '.lte.cell_id_hex // empty')
                    lte_cell_id=$(echo "ibase=16; $lte_cell_id_hex" | bc)
                    lte_physical_cell_id_hex=$(printf '%s' "$monsc_parsed" | jq -r '.lte.pci_hex // empty')
                    lte_physical_cell_id=$(echo "ibase=16; $lte_physical_cell_id_hex" | bc)
                    lte_tac=$(printf '%s' "$monsc_parsed" | jq -r '.lte.tac // empty')
                    lte_rsrp=$(printf '%s' "$monsc_parsed" | jq -r '.lte.rsrp // empty')
                    lte_rsrq=$(printf '%s' "$monsc_parsed" | jq -r '.lte.rsrq // empty')
                    lte_rxlev=$(printf '%s' "$monsc_parsed" | jq -r '.lte.rxlev // empty')
                ;;
                "WCDMA"|"TD-SCDMA"|"UMTS")
                    network_mode="WCDMA Mode"
                    wcdma_mcc=$(printf '%s' "$monsc_parsed" | jq -r '.mcc // empty')
                    wcdma_mnc=$(printf '%s' "$monsc_parsed" | jq -r '.mnc // empty')
                    wcdma_arfcn=$(printf '%s' "$monsc_parsed" | jq -r '.channel // empty')
                    wcdma_psc=$(printf '%s' "$monsc_parsed" | jq -r '.wcdma.psc // empty')
                    wcdma_cell_id_hex=$(printf '%s' "$monsc_parsed" | jq -r '.wcdma.cell_id_hex // empty')
                    wcdma_cell_id=$(echo "ibase=16; $wcdma_cell_id_hex" | bc)
                    wcdma_lac=$(printf '%s' "$monsc_parsed" | jq -r '.wcdma.lac // empty')
                    wcdma_rscp=$(printf '%s' "$monsc_parsed" | jq -r '.wcdma.rscp // empty')
                    wcdma_rxlev=$(printf '%s' "$monsc_parsed" | jq -r '.wcdma.rxlev // empty')
                    wcdma_ecn0=$(printf '%s' "$monsc_parsed" | jq -r '.wcdma.ecn0 // empty')
                    wcdma_drx=$(printf '%s' "$monsc_parsed" | jq -r '.wcdma.drx // empty')
                    wcdma_ura=$(printf '%s' "$monsc_parsed" | jq -r '.wcdma.ura // empty')
                ;;
                "GSM")
                    network_mode="GSM Mode"
                    gsm_mcc=$(printf '%s' "$monsc_parsed" | jq -r '.mcc // empty')
                    gsm_mnc=$(printf '%s' "$monsc_parsed" | jq -r '.mnc // empty')
                    gsm_band_num=$(printf '%s' "$monsc_parsed" | jq -r '.gsm.band_code // empty')
                    gsm_band=$(tdtech_get_band "GSM" ${gsm_band_num})
                    gsm_arfcn=$(printf '%s' "$monsc_parsed" | jq -r '.gsm.arfcn // empty')
                    gsm_bsic=$(printf '%s' "$monsc_parsed" | jq -r '.gsm.bsic // empty')
                    gsm_cell_id_hex=$(printf '%s' "$monsc_parsed" | jq -r '.gsm.cell_id_hex // empty')
                    gsm_cell_id=$(echo "ibase=16; $gsm_cell_id_hex" | bc)
                    gsm_lac=$(printf '%s' "$monsc_parsed" | jq -r '.gsm.lac // empty')
                    gsm_rxlev=$(printf '%s' "$monsc_parsed" | jq -r '.gsm.rxlev // empty')
                    gsm_rx_quality=$(printf '%s' "$monsc_parsed" | jq -r '.gsm.rx_quality // empty')
                    gsm_ta=$(printf '%s' "$monsc_parsed" | jq -r '.gsm.timing_advance // empty')
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
                add_plain_info_entry "TAC" "$nr_tac" "Tracking area code of cell served by neighbor Enb"
                add_plain_info_entry "ARFCN" "$nr_arfcn" "Absolute Radio-Frequency Channel Number"
                add_plain_info_entry "Band" "$nr_band" "Band"
                add_plain_info_entry "DL Bandwidth" "$nr_dl_bandwidth" "DL Bandwidth"
                add_bar_info_entry "RSRP" "$nr_rsrp" "Reference Signal Received Power" -187 -29 dBm
                add_bar_info_entry "RSRQ" "$nr_rsrq" "Reference Signal Received Quality" -43 20 dBm
                add_bar_info_entry "SINR" "$nr_sinr" "Signal to Interference plus Noise Ratio Bandwidth" -23 40 dB
                add_plain_info_entry "RxLev" "$nr_rxlev" "Received Signal Level"
                add_plain_info_entry "SCS" "$nr_scs" "SCS"
                add_plain_info_entry "Srxlev" "$nr_srxlev" "Serving Cell Receive Level"
                ;;
            "EN-DC Mode")
                add_plain_info_entry "LTE" "LTE" ""
                add_plain_info_entry "MCC" "$endc_lte_mcc" "Mobile Country Code"
                add_plain_info_entry "MNC" "$endc_lte_mnc" "Mobile Network Code"
                add_plain_info_entry "Duplex Mode" "$endc_lte_duplex_mode" "Duplex Mode"
                add_plain_info_entry "Cell ID" "$endc_lte_cell_id" "Cell ID"
                add_plain_info_entry "Physical Cell ID" "$endc_lte_physical_cell_id" "Physical Cell ID"
                add_plain_info_entry "EARFCN" "$endc_lte_earfcn" "E-UTRA Absolute Radio Frequency Channel Number"
                add_plain_info_entry "Freq band indicator" "$endc_lte_freq_band_ind" "Freq band indicator"
                add_plain_info_entry "Band" "$endc_lte_band" "Band"
                add_plain_info_entry "UL Bandwidth" "$endc_lte_ul_bandwidth" "UL Bandwidth"
                add_plain_info_entry "DL Bandwidth" "$endc_lte_dl_bandwidth" "DL Bandwidth"
                add_plain_info_entry "CQI" "$endc_lte_cql" "Channel Quality Indicator"
                add_plain_info_entry "TX Power" "$endc_lte_tx_power" "TX Power"
                add_plain_info_entry "Srxlev" "$endc_lte_srxlev" "Serving Cell Receive Level"
                add_plain_info_entry "TAC" "$endc_lte_tac" "Tracking area code of cell served by neighbor Enb"
                add_bar_info_entry "RSRP" "$endc_lte_rsrp" "Reference Signal Received Power" -140 -44 dBm
                add_bar_info_entry "RSRQ" "$endc_lte_rsrq" "Reference Signal Received Quality" -20 20 dBm
                add_bar_info_entry "SINR" "$endc_lte_sinr" "Signal to Interference plus Noise Ratio Bandwidth" -23 40 dB
                add_plain_info_entry "RxLev" "$endc_lte_rxlev" "Received Signal Level"
                add_plain_info_entry "RSSNR" "$endc_lte_rssnr" "Radio Signal Strength Noise Ratio"
                add_plain_info_entry NR5G-NSA "NR5G-NSA" ""
                add_bar_info_entry "RSRP" "$endc_nr_rsrp" "Reference Signal Received Power" -187 -29 dBm
                add_bar_info_entry "RSRQ" "$endc_nr_rsrq" "Reference Signal Received Quality" -43 20 dBm
                add_bar_info_entry "SINR" "$endc_nr_sinr" "Signal to Interference plus Noise Ratio Bandwidth" -23 40 dB
                ;;
            "LTE Mode")
                add_plain_info_entry "MCC" "$lte_mcc" "Mobile Country Code"
                add_plain_info_entry "MNC" "$lte_mnc" "Mobile Network Code"
                add_plain_info_entry "Duplex Mode" "$lte_duplex_mode" "Duplex Mode"
                add_plain_info_entry "Cell ID" "$lte_cell_id" "Cell ID"
                add_plain_info_entry "Physical Cell ID" "$lte_physical_cell_id" "Physical Cell ID"
                add_plain_info_entry "EARFCN" "$lte_earfcn" "E-UTRA Absolute Radio Frequency Channel Number"
                add_plain_info_entry "Freq band indicator" "$lte_freq_band_ind" "Freq band indicator"
                add_plain_info_entry "Band" "$lte_band" "Band"
                add_plain_info_entry "UL Bandwidth" "$lte_ul_bandwidth" "UL Bandwidth"
                add_plain_info_entry "DL Bandwidth" "$lte_dl_bandwidth" "DL Bandwidth"
                add_plain_info_entry "TAC" "$lte_tac" "Tracking area code of cell served by neighbor Enb"
                add_bar_info_entry "RSRQ" "$lte_rsrq" "Reference Signal Received Quality" -20 20 dBm 
                add_bar_info_entry "RSSI" "$lte_rssi" "Received Signal Strength Indicator" -140 -44 dBm
                add_bar_info_entry "SINR" "$lte_sinr" "Signal to Interference plus Noise Ratio Bandwidth" -23 40 dB
                add_plain_info_entry "RxLev" "$lte_rxlev" "Received Signal Level"
                add_plain_info_entry "RSSNR" "$lte_rssnr" "Radio Signal Strength Noise Ratio"
                add_plain_info_entry "CQI" "$lte_cql" "Channel Quality Indicator"
                add_plain_info_entry "TX Power" "$lte_tx_power" "TX Power"
                add_plain_info_entry "Srxlev" "$lte_srxlev" "Serving Cell Receive Level"
                
                ;;
            "WCDMA Mode")
                add_plain_info_entry "MCC" "$wcdma_mcc" "Mobile Country Code"
                add_plain_info_entry "MNC" "$wcdma_mnc" "Mobile Network Code"
                add_plain_info_entry "LAC" "$wcdma_lac" "Location Area Code"
                add_plain_info_entry "Cell ID" "$wcdma_cell_id" "Cell ID"
                add_plain_info_entry "UARFCN" "$wcdma_uarfcn" "UTRA Absolute Radio Frequency Channel Number"
                add_plain_info_entry "PSC" "$wcdma_psc" "Primary Scrambling Code"
                add_plain_info_entry "RAC" "$wcdma_rac" "Routing Area Code"
                add_plain_info_entry "Band" "$wcdma_band" "Band"
                add_bar_info_entry "RSCP" "$wcdma_rscp" "Received Signal Code Power" -120 -25 dBm
                add_plain_info_entry "Ec/Io" "$wcdma_ecio" "Ec/Io"
                add_plain_info_entry "Ec/No" "$wcdma_ecno" "Ec/No"
                add_plain_info_entry "Physical Channel" "$wcdma_phych" "Physical Channel"
                add_plain_info_entry "Spreading Factor" "$wcdma_sf" "Spreading Factor"
                add_plain_info_entry "Slot" "$wcdma_slot" "Slot"
                add_plain_info_entry "Speech Code" "$wcdma_speech_code" "Speech Code"
                add_plain_info_entry "Compression Mode" "$wcdma_com_mod" "Compression Mode"
                add_plain_info_entry "RxLev" "$wcdma_rxlev" "RxLev"
                
                ;;
            esac
            ;;
    esac
    
}

network_info() {
    return 0
}

_get_lockband_nr(){
    local raw parsed
    raw=$(cmd_band_query "$at_port"); parsed=$(_huawei_parse huawei.band.config "$raw")
    local bandcfg="$parsed"
    raw=$(cmd_band_list_query "$at_port"); parsed=$(_huawei_parse huawei.band.list "$raw")
    local bandtemplate="$parsed"
    local type band_name band_hex band_bin band_id low_band high_band entry
    for type in $(printf '%s' "$bandtemplate" | jq -r '.bands[].type' | awk '!seen[$0]++'); do
            json_add_object "$type"
            json_add_array "available_band"
            json_close_array
            json_add_array "lock_band"
            json_close_array
            json_close_object
    done
    while IFS= read -r entry; do
            type=$(printf '%s' "$entry" | jq -r '.type')
            band_name=$(printf '%s' "$entry" | jq -r '.name')
            case $type in
            "GW")
                band_hex=$(printf '%s' "$entry" | jq -r '.mask')
                band_bin=$(echo "obase=2; ibase=16; $band_hex" | bc)
                band_id=$(echo $band_bin | wc -c)
                band_id=$(($band_id - 1))
                ;;
            *)
                band_id=$(echo $band_name |grep -o '^[BbNn][0-9]*' | grep -o '[0-9]*')
                ;;
            esac
            json_select $type
            json_select "available_band"
            add_avalible_band_entry $band_id  ${type}_${band_name} 
            json_close_array
            json_close_object
    done <<EOF
$(printf '%s' "$bandtemplate" | jq -c '.bands[]')
EOF
    while IFS= read -r entry; do
            type=$(printf '%s' "$entry" | jq -r '.type')
            low_band=$(printf '%s' "$entry" | jq -r '.low_mask')
            high_band=$(printf '%s' "$entry" | jq -r '.high_mask')
            json_select $type
            json_select "lock_band"
            _mask_to_band _add_lock_band  $low_band $high_band
            json_select ".."
            json_select ".."
    done <<EOF
$(printf '%s' "$bandcfg" | jq -c '.configurations[]')
EOF
}

_set_lockband_nr(){
    case $band_class in
        "GW")
            band_class=0
            ;;
        "LTE")
            band_class=1
            ;;
        "NRNSA")
            band_class=3
            ;;
        "NRSA")
            band_class=4
            ;;
    esac
    bandlist=$(_band_list_to_mask $lock_band)
    [ "$band_class" -eq 0 ] && bandlist=${bandlist:0:16}
    cmd="AT!BAND=0F,1,\"Custom\",$band_class,${bandlist}"
    local raw parsed
    raw=$(cmd_band_set_custom "$at_port" "$band_class" "$bandlist"); parsed=$(_huawei_parse huawei.band.set "$raw")
    res=$(printf '%s' "$parsed"|jq -r '.result // empty'|xargs)
    if [ "$res" == "OK" ]; then
        raw=$(cmd_band_reset "$at_port" "0F"); _huawei_parse huawei.band.reset "$raw" >/dev/null
    else
        raw=$(cmd_band_reset "$at_port" "00"); _huawei_parse huawei.band.reset "$raw" >/dev/null
    fi
    json_add_string "result" "$res"
    json_add_string "cmd" "$cmd"
}

_get_temperature(){
    local raw parsed
    raw=$(cmd_chiptemp_query "$at_port"); parsed=$(_huawei_parse huawei.chiptemp "$raw")
    response=$(printf '%s' "$parsed"|jq -r '.temperature // empty')
    
    local temperature
    case $platform in
        "unisoc")
            [ -n "$response" ] && {
                response=$(awk "BEGIN{ printf \"%.2f\", $response }" | sed 's/\.*0*$//')
                add_plain_info_entry "temperature" "$response $(printf "\xc2\xb0")C" "Temperature" 
            }
            ;;
        *)
            [ -n "$response" ] && {
                response=$(awk "BEGIN{ printf \"%.2f\", $response / 10 }" | sed 's/\.*0*$//')
                add_plain_info_entry "temperature" "$response $(printf "\xc2\xb0")C" "Temperature" 
            }
            ;;
    esac

}

_add_avalible_band(){
    add_avalible_band_entry $1 $1
}

_add_lock_band(){
    json_add_string "" $1
}

_mask_to_band()
{
    func=$1
    low_band=$2
    high_band=$3
    low_band=$(echo "obase=2; ibase=16; $low_band" | bc)
    low_band=$(printf "%064s" $low_band)
    for i in $(seq 1 64); do
        if [ "${low_band: -$i:1}" = "1" ]; then
            band=$i
            $func $band
        fi
    done
    [ -z "$high_band" ] && return
    high_band=$(echo "obase=2; ibase=16; $high_band" | bc)
    high_band=$(printf "%064s" $high_band)
    for i in $(seq 1 64); do
        if [ "${high_band: -$i:1}" = "1" ]; then
            band=$((64+i))
            $func $band
        fi
    done

}

_band_list_to_mask()
{
    local band_list=$1
    local low=0
    local high=0
    #以逗号分隔
    IFS=","
    for band in $band_list;do
        if [ "$band" -le 64 ]; then
            #使用bc计算2的band次方
            res=$(echo "2^($band-1)" | bc)
            low=$(echo "$low+$res" | bc)

        else
            tmp_band=$((band-64))
            res=$(echo "2^($tmp_band-1)" | bc)
            high=$(echo "$high+$res" | bc)
        fi
    done
    #十六进制输出，padding到16位
    low=$(printf "%016x" $low)
    high=$(printf "%016x" $high)
    echo "$low,$high"
}

_parse_hfreqinfo(){
    local hfreqinfo="$1"
    IFS=$'\n'
    for line in $hfreqinfo; do
        #$2 为制式 1为GSM 2为CDMA 3为WCDMA 4为TD-SCDMA 6为LTE 7为NR
        #$3 为频段 
        #$4 为dl频点
        #$5 为dl频率(KHz)
        #$6 为dl带宽(KHz)
        #$7 为ul频点
        #$8 为ul频率(KHz)
        #$9 为ul带宽(KHz)
        rat=$(echo $line | awk -F ',' '{print $2}')
        case $rat in
            1) rat_name="GSM" ;;
            2) rat_name="CDMA" ;;
            3) rat_name="WCDMA" ;;
            4) rat_name="TD-SCDMA" ;;
            6) rat_name="LTE" ;;
            7) rat_name="NR" ;;
        esac
        #KHz to MHz
        band=$(echo $line | awk -F ',' '{print $3}')
        dl_fcn=$(echo $line | awk -F ',' '{print $4}' )
        dl_freqN=$(echo $line | awk -F ',' '{print $5}')
        dl_freq=${dl_freqN: 0:-1}
        dl_N=${dl_freqN: -1}
        dl_bw=$(echo $line | awk -F ',' '{print $6}' | awk '{printf "%.1f", $1/1000}')
        up_fcn=$(echo $line | awk -F ',' '{print $7}')
        up_freqN=$(echo $line | awk -F ',' '{print $8}')
        #去除最后一位
        up_freq=${up_freqN: 0:-1}
        #获取最后一位
        up_N=${up_freqN: -1}
        up_bw=$(echo $line | awk -F ',' '{print $9}'| awk '{printf "%.1f", $1/1000}')
        

        case $rat in
            6) 
                band_prefix="B"
                LTE_INFO_BAND="${band_prefix}${band}"
                LTE_INFO_DL="${dl_freq} @ ${dl_bw}MHz"
                LTE_INFO_UL="${up_freq} @ ${up_bw}MHz"
                ;;
            7) 
                band_prefix="N"
                NR_INFO_BAND="${band_prefix}${band}"
                NR_INFO_DL="${dl_freq} @ ${dl_bw}MHz"
                NR_INFO_UL="${up_freq} @ ${up_bw}MHz"
                ;;
            *) 
                band_prefix=""
                OTHER_INFO_BAND="${band_prefix}${band}"
                OTHER_INFO_DL="${dl_freq} @ ${dl_bw}MHz"
                OTHER_INFO_UL="${up_freq} @ ${up_bw}MHz"
                ;;
        esac
    done
    unset IFS
}

# get sim switch capabilities
sim_switch_capabilities(){
    json_add_string "supportSwitch" "1"
    json_add_string "ExtraInfo" "Huawei Modem does not support querying SIM slot capabilities via AT commands.Slot display may be incorrect."
    json_add_array "simSlots"
    json_add_string "" "0"
    json_add_string "" "1"
    json_close_array
}

get_sim_slot(){
    #local at_command="AT^HVSST?"
	#sim_slot=$(at $at_port $at_command | grep "HVSST:" | awk -F',' '{print $3}' | xargs)
    sim_slot=$(cat /tmp/huawei_sim_slot_$config_section)||sim_slot="0" && echo "$sim_slot" > /tmp/huawei_sim_slot_$config_section
    json_add_string "sim_slot" "$sim_slot"
}

set_sim_slot(){
    local sim_slot=$1
    echo "$sim_slot" > /tmp/huawei_sim_slot_$config_section
    case $platform in
        "unisoc")
            local raw parsed
            raw=$(cmd_simswitch_set "$at_port" "$sim_slot"); parsed=$(_huawei_parse huawei.simswitch.set "$raw")
            response=$(printf '%s' "$parsed"|jq -r '.result // empty'|xargs)
            ;;
        "hisilicon")
            case $sim_slot in
                "0")
                    raw=$(cmd_scichg "$at_port" 0 1); parsed=$(_huawei_parse huawei.scichg.set "$raw")
                    response=$(printf '%s' "$parsed"|jq -r '.result // empty'|xargs)
                    ;;
                "1")
                    raw=$(cmd_scichg "$at_port" 1 0); parsed=$(_huawei_parse huawei.scichg.set "$raw")
                    response=$(printf '%s' "$parsed"|jq -r '.result // empty'|xargs)
                    ;;
            esac
            ;;
    esac
    json_add_string "result" "$response"
}
