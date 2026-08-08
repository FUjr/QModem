#!/bin/sh
# Copyright (C) 2025 sfwtw <sfwtw@qq.com>
_Vendor="telit"
_Author="sfwtw"
_Maintainer="sfwtw <sfwtw@qq.com>"
source "${QMODEM_HOME:-/usr/share/qmodem}/generic.sh"
debug_subject="telit_ctrl"

telit_parse_response()
{
    local parser_id="$1" raw="$2"
    printf '%s' "$raw" | "${QMODEM_PARSER:-${QMODEM_HOME:-/usr/share/qmodem}/parsers/parse.sh}" \
        "$parser_id" --platform "${platform:-unknown}" --model "${model:-${QMODEM_TESTCASE_MODEL:-unknown}}" --context-json '{}'
}

telit_parse_field()
{
    local parser_id="$1" field="$2" raw="$3" parsed
    parsed=$(telit_parse_response "$parser_id" "$raw") || return
    printf '%s' "$parsed" | jq -r --arg field "$field" '.[$field] // empty'
}

vendor_get_disabled_features()
{
    json_add_string "" "IMEI"
    json_add_string "" "NeighborCell"
}

get_mode()
{
    local raw mode_num
    raw=$(cmd_usbcfg_query "$at_port")
    mode_num=$(telit_parse_field telit.usbcfg legacy_mode_num "$raw")
    case "$mode_num" in
        "0") mode="rndis" ;;
        "1") mode="qmi" ;;
        "2") mode="mbim" ;;
        "3") mode="ecm" ;;
        *) mode="${mode_num}" ;;
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

set_mode()
{
    local mode=$1
    case $mode in
        "rndis") mode="0" ;;
        "qmi") mode="1" ;;
        "mbim") mode="2" ;;
        "ecm") mode="3" ;;
        *) echo "Invalid mode" && return 1;;
    esac
    raw=$(cmd_usbcfg_set "$at_port" "$mode")
    res=$(telit_parse_field telit.command.completion command_output "$raw")
    json_select "result"
    json_add_string "set_mode" "$res"
    json_close_object
}

get_network_prefer()
{
    local raw parsed
    raw=$(cmd_ws46_query "$at_port")
    parsed=$(telit_parse_response telit.ws46 "$raw") || return
    network_prefer_3g=$(printf '%s' "$parsed" | jq -r 'if .enabled["3G"] then "1" else "0" end')
    network_prefer_4g=$(printf '%s' "$parsed" | jq -r 'if .enabled["4G"] then "1" else "0" end')
    network_prefer_5g=$(printf '%s' "$parsed" | jq -r 'if .enabled["5G"] then "1" else "0" end')
    json_add_object network_prefer
    json_add_string 3G $network_prefer_3g
    json_add_string 4G $network_prefer_4g
    json_add_string 5G $network_prefer_5g
    json_close_object
}

set_network_prefer()
{
    network_prefer_3g=$(echo $1 |jq -r 'contains(["3G"])')
    network_prefer_4g=$(echo $1 |jq -r 'contains(["4G"])')
    network_prefer_5g=$(echo $1 |jq -r 'contains(["5G"])')
    length=$(echo $1 |jq -r 'length')

    case "$length" in
        "1")
            if [ "$network_prefer_3g" = "true" ]; then
                network_prefer_config="22"
            elif [ "$network_prefer_4g" = "true" ]; then
                network_prefer_config="28"
            elif [ "$network_prefer_5g" = "true" ]; then
                network_prefer_config="36"
            fi
        ;;
        "2")
            if [ "$network_prefer_3g" = "true" ] && [ "$network_prefer_4g" = "true" ]; then
                network_prefer_config="31"
            elif [ "$network_prefer_3g" = "true" ] && [ "$network_prefer_5g" = "true" ]; then
                network_prefer_config="40"
            elif [ "$network_prefer_4g" = "true" ] && [ "$network_prefer_5g" = "true" ]; then
                network_prefer_config="37"
            fi
        ;;
        "3") network_prefer_config="38" ;;
        *) network_prefer_config="38" ;;
    esac

    raw=$(cmd_ws46_set "$at_port" "$network_prefer_config")
    telit_parse_field telit.command.completion command_output "$raw"
}

get_voltage()
{
    local raw voltage
    raw=$(cmd_cbc "$at_port")
    voltage=$(telit_parse_field telit.cbc millivolts "$raw")
    [ -n "$voltage" ] && {
        voltage=$(awk "BEGIN {printf \"%.2f\", $voltage / 100}")
        add_plain_info_entry "voltage" "$voltage V" "Voltage" 
    }
}

get_temperature()
{   
    local temp
    QTEMP=$(cmd_tempsens "$at_port")
    temp=$(telit_parse_field telit.tempsens temperature "$QTEMP")
    if [ -n "$temp" ]; then
        temp="${temp}$(printf "\xc2\xb0")C"
    fi
    add_plain_info_entry "temperature" "$temp" "Temperature"
}

base_info()
{
    m_debug  "Telit base info"

    #Name（名称）
    raw=$(cmd_cgmm "$at_port"); name=$(telit_parse_field telit.cgmm name "$raw")
    #Manufacturer（制造商）
    raw=$(cmd_cgmi "$at_port"); manufacturer=$(telit_parse_field telit.cgmi manufacturer "$raw")
    #Revision（固件版本）
    raw=$(cmd_cgmr "$at_port"); revision=$(telit_parse_field telit.cgmr revision "$raw")
    class="Base Information"
    add_plain_info_entry "name" "$name" "Name"
    add_plain_info_entry "manufacturer" "$manufacturer" "Manufacturer"
    add_plain_info_entry "revision" "$revision" "Revision"
    add_plain_info_entry "at_port" "$at_port" "AT Port"
    get_temperature
    get_voltage
    get_connect_status
}

sim_info()
{
    m_debug  "Telit sim info"
    
    #SIM Slot（SIM卡卡槽）
    raw=$(cmd_qss_query "$at_port"); sim_slot=$(telit_parse_field telit.qss sim_slot "$raw")
    #IMEI（国际移动设备识别码）
    raw=$(cmd_cgsn "$at_port"); imei=$(telit_parse_field telit.cgsn imei "$raw")

    #SIM Status（SIM状态）
    raw=$(cmd_cpin_query "$at_port"); sim_status_flag=$(telit_parse_field telit.cpin status_text "$raw")
    sim_status=$(get_sim_status "$sim_status_flag")

    if [ "$sim_status" != "ready" ]; then
        return
    fi

    #ISP（互联网服务提供商）
    raw=$(cmd_cops_query "$at_port"); isp=$(telit_parse_field telit.cops operator "$raw")
    # if [ "$isp" = "CHN-CMCC" ] || [ "$isp" = "CMCC" ]|| [ "$isp" = "46000" ]; then
    #     isp="中国移动"
    # # elif [ "$isp" = "CHN-UNICOM" ] || [ "$isp" = "UNICOM" ] || [ "$isp" = "46001" ]; then
    # elif [ "$isp" = "CHN-UNICOM" ] || [ "$isp" = "CUCC" ] || [ "$isp" = "46001" ]; then
    #     isp="中国联通"
    # # elif [ "$isp" = "CHN-CT" ] || [ "$isp" = "CT" ] || [ "$isp" = "46011" ]; then
    # elif [ "$isp" = "CHN-TELECOM" ] || [ "$isp" = "CTCC" ] || [ "$isp" = "46011" ]; then
    #     isp="中国电信"
    # fi

    #IMSI（国际移动用户识别码）
    raw=$(cmd_cimi "$at_port"); imsi=$(telit_parse_field telit.cimi imsi "$raw")

    #ICCID（集成电路卡识别码）
    raw=$(cmd_iccid "$at_port")
    parsed=$(telit_parse_response telit.iccid "$raw") || return
    iccid=$(printf '%s' "$parsed" | jq -r '.iccid_chunks | join("\n")')
    class="SIM Information"
    case "$sim_status" in
        "ready")
            add_plain_info_entry "SIM Status" "$sim_status" "SIM Status" 
            add_plain_info_entry "ISP" "$isp" "Internet Service Provider"
            add_plain_info_entry "SIM Slot" "$sim_slot" "SIM Slot"
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

network_info()
{
    m_debug  "Telit network info"

    raw=$(cmd_cametrics "$at_port"); network_type=$(telit_parse_field telit.cametrics network_type "$raw")
    raw=$(cmd_cqi "$at_port"); cqi=$(telit_parse_field telit.cqi downlink_cqi "$raw")

    class="Network Information"
    add_plain_info_entry "Network Type" "$network_type" "Network Type"
    add_plain_info_entry "CQI DL" "$cqi" "Channel Quality Indicator for Downlink"
}

lte_hex_to_bands() {
    local hex_value="$1"
    local result=""
    hex_value=$(echo "$hex_value" | tr 'a-z' 'A-Z')
    local decimal=$(echo "ibase=16; $hex_value" | bc)
    local i=1
    while [ "$decimal" != "0" ]; do
        local bit=$(echo "$decimal % 2" | bc)
        if [ "$bit" -eq 1 ]; then
            result="$result B$i"
        fi
        decimal=$(echo "$decimal / 2" | bc)
        i=$(expr $i + 1)
    done
    result=$(echo "$result" | tr -s ' ' | sed -e 's/^ *//' -e 's/ *$//')
    echo "$result"
}

lte_bands_to_hex() {
    local bands="$1"
    local decimal_value=0
    for band in $bands; do
        local band_num=$(echo "$band" | sed 's/^B//')
        local bit_value=$(echo "2^($band_num-1)" | bc)
        decimal_value=$(echo "$decimal_value + $bit_value" | bc)
    done
    local hex_value=$(echo "obase=16; $decimal_value" | bc)
    echo "$hex_value"
}

nr_hex_to_bands() {
    local hex_value="$1"
    local result=""
    hex_value=$(echo "$hex_value" | tr 'a-z' 'A-Z')
    local decimal=$(echo "ibase=16; $hex_value" | bc)
    local j=1
    [ "$2" = "65_128" ] && j=65
    while [ "$decimal" != "0" ]; do
        local bit=$(echo "$decimal % 2" | bc)
        if [ "$bit" -eq 1 ]; then
            result="$result N$j"
        fi
        decimal=$(echo "$decimal / 2" | bc)
        j=$(expr $j + 1)
    done
    result=$(echo "$result" | tr -s ' ' | sed -e 's/^ *//' -e 's/ *$//')
    echo "$result"
}

nr_bands_to_hex() {
    local bands="$1"
    local decimal_value=0
    local decimal_value_ext=0
    for band in $bands; do
        local band_num=$(echo "$band" | sed 's/^N//')
        if expr "$band_num" : '[0-9][0-9]*$' >/dev/null; then
            if [ $band_num -lt 65 ]; then
                local bit_value=$(echo "2^($band_num-1)" | bc)
                decimal_value=$(echo "$decimal_value + $bit_value" | bc)
            else
                local bit_value=$(echo "2^($band_num-65)" | bc)
                decimal_value_ext=$(echo "$decimal_value_ext + $bit_value" | bc)
            fi
        fi
    done
    local hex_value=$(echo "obase=16; $decimal_value" | bc)
    if [ "$decimal_value_ext" != "0" ]; then
        local hex_value_ext=$(echo "obase=16; $decimal_value_ext" | bc)
        echo "${hex_value_ext}"
    else
        echo "$hex_value"
    fi
}

get_lockband()
{
    json_add_object "lockband"
    m_debug "Telit get lockband info"
    get_lockband_config_res=$(cmd_bnd_query "$at_port")
    get_available_band_res=$(cmd_bnd_list_query "$at_port")
    lock_parsed=$(telit_parse_response telit.bnd.config "$get_lockband_config_res") || return
    available_parsed=$(telit_parse_response telit.bnd.available "$get_available_band_res") || return
    json_add_object "LTE"
    json_add_array "available_band"
    json_close_array
    json_add_array "lock_band"
    json_close_array
    json_close_object
    json_add_object "NR_NSA"
    json_add_array "available_band"
    json_close_array
    json_add_array "lock_band"
    json_close_array
    json_close_object
    json_add_object "NR"
    json_add_array "available_band"
    json_close_array
    json_add_array "lock_band"
    json_close_array
    json_close_object
    for i in $(printf '%s' "$available_parsed" | jq -r '.bands.lte[]'); do
        json_select "LTE"
        json_select "available_band"
        add_avalible_band_entry  "$i" "$i"
        json_select ..
        json_select ..
    done
    for i in $(printf '%s' "$available_parsed" | jq -r '.bands.nsa[]'); do
        json_select "NR_NSA"
        json_select "available_band"
        add_avalible_band_entry  "$i" "$i"
        json_select ..
        json_select ..
    done
    for i in $(printf '%s' "$available_parsed" | jq -r '.bands.sa[]'); do
        json_select "NR"
        json_select "available_band"
        add_avalible_band_entry  "$i" "$i"
        json_select ..
        json_select ..
    done

    for i in $(printf '%s' "$lock_parsed" | jq -r '.bands.lte[]'); do
        if [ -n "$i" ]; then
            json_select "LTE"
            json_select "lock_band"
            json_add_string "" "$i"
            json_select ..
            json_select ..
        fi
    done
    for i in $(printf '%s' "$lock_parsed" | jq -r '.bands.nsa[]'); do
        if [ -n "$i" ]; then
            json_select "NR_NSA"
            json_select "lock_band"
            json_add_string "" "$i"
            json_select ..
            json_select ..
        fi
    done
    for i in $(printf '%s' "$lock_parsed" | jq -r '.bands.sa[]'); do
        if [ -n "$i" ]; then
            json_select "NR"
            json_select "lock_band"
            json_add_string "" "$i"
            json_select ..
            json_select ..
        fi
    done
    json_close_array
    json_close_object
}

set_lockband()
{
    m_debug  "telit set lockband info"
    config=$1
    #{"band_class":"NR","lock_band":"41,78,79"}
    band_class=$(echo $config | jq -r '.band_class')
    lock_band=$(echo $config | jq -r '.lock_band')
    lock_band=$(echo $lock_band | tr ',' ' ')
    case "$band_class" in
        "LTE") 
            lock_band=$(lte_bands_to_hex "$lock_band")
            raw=$(cmd_bnd_set "$at_port" "$lock_band")
            res=$(telit_parse_field telit.command.completion command_output "$raw")
            ;;
        "NR_NSA")
            orig=$(cmd_bnd_query "$at_port")
            orig_parsed=$(telit_parse_response telit.bnd.config "$orig") || return
            orig_lte=$(printf '%s' "$orig_parsed" | jq -r '.masks.lte')
            orig_lte_ext=$(printf '%s' "$orig_parsed" | jq -r '.masks.lte_ext')
            orig_nsa_nr_1_64=$(printf '%s' "$orig_parsed" | jq -r '.masks.nsa_1_64')
            orig_nsa_nr_65_128=$(printf '%s' "$orig_parsed" | jq -r '.masks.nsa_65_128')

            nr_bands_1_64=""
            nr_bands_65_128=""
            for band in $lock_band; do
                band_num=$(echo "$band" | sed 's/^N//')
                if [ "$band_num" -lt 65 ]; then
                    nr_bands_1_64="$nr_bands_1_64 N$band_num"
                else
                    nr_bands_65_128="$nr_bands_65_128 N$band_num"
                fi
            done

            nsa_nr_1_64=$(nr_bands_to_hex "$nr_bands_1_64" | cut -d',' -f1)
            nsa_nr_65_128=$(nr_bands_to_hex "$nr_bands_65_128" | cut -d',' -f2)

            [ -z "$nsa_nr_1_64" ] && nsa_nr_1_64=$orig_nsa_nr_1_64
            [ -z "$nsa_nr_65_128" ] && nsa_nr_65_128=$orig_nsa_nr_65_128
            
            raw=$(cmd_bnd_set "$at_port" "$orig_lte,$orig_lte_ext,$nsa_nr_1_64,$nsa_nr_65_128")
            res=$(telit_parse_field telit.command.completion command_output "$raw")
            ;;
        "NR")
            orig=$(cmd_bnd_query "$at_port")
            orig_parsed=$(telit_parse_response telit.bnd.config "$orig") || return
            orig_lte=$(printf '%s' "$orig_parsed" | jq -r '.masks.lte')
            orig_lte_ext=$(printf '%s' "$orig_parsed" | jq -r '.masks.lte_ext')
            orig_nsa_nr_1_64=$(printf '%s' "$orig_parsed" | jq -r '.masks.nsa_1_64')
            orig_nsa_nr_65_128=$(printf '%s' "$orig_parsed" | jq -r '.masks.nsa_65_128')
            orig_sa_nr_1_64=$(printf '%s' "$orig_parsed" | jq -r '.masks.sa_1_64')
            orig_sa_nr_65_128=$(printf '%s' "$orig_parsed" | jq -r '.masks.sa_65_128')
            nr_bands_1_64=""
            nr_bands_65_128=""
            for band in $lock_band; do
                band_num=$(echo "$band" | sed 's/^N//')
                if [ "$band_num" -lt 65 ]; then
                    nr_bands_1_64="$nr_bands_1_64 N$band_num"
                else
                    nr_bands_65_128="$nr_bands_65_128 N$band_num"
                fi
            done

            nr_1_64=$(nr_bands_to_hex "$nr_bands_1_64")
            nr_65_128=$(nr_bands_to_hex "$nr_bands_65_128")

            [ -z "$nr_1_64" ] && nr_1_64=$orig_sa_nr_1_64
            [ -z "$nr_65_128" ] && nr_65_128=$orig_sa_nr_65_128
            raw=$(cmd_bnd_set "$at_port" "$orig_lte,$orig_lte_ext,$orig_nsa_nr_1_64,$orig_nsa_nr_65_128,$nr_1_64,$nr_65_128")
            res=$(telit_parse_field telit.command.completion command_output "$raw")
            ;;
    esac
    json_select "result"
    json_add_string "set_lockband" "$res"
    json_add_string "config" "$config"
    json_add_string "band_class" "$band_class"
    json_add_string "lock_band" "$lock_band"
    json_close_object
}

calc_average() {
    local values="$1"
    local sum=0
    local count=0
    
    for val in $values; do
        if [ -n "$val" ] && [ "$val" != "NA" ]; then
            sum=$(echo "$sum + $val" | bc -l)
            count=$((count + 1))
        fi
    done
    
    if [ $count -gt 0 ]; then
        printf "%.1f" $(echo "$sum / $count" | bc -l)
    else
        echo "NA"
    fi
}

convert_band_number() {
    local band_num=$1
    case "$band_num" in
        120) echo "B1" ;;
        121) echo "B2" ;;
        122) echo "B3" ;;
        123) echo "B4" ;;
        124) echo "B5" ;;
        125) echo "B6" ;;
        126) echo "B7" ;;
        127) echo "B8" ;;
        128) echo "B9" ;;
        129) echo "B10" ;;
        130) echo "B11" ;;
        131) echo "B12" ;;
        132) echo "B13" ;;
        133) echo "B14" ;;
        134) echo "B17" ;;
        135) echo "B33" ;;
        136) echo "B34" ;;
        137) echo "B35" ;;
        138) echo "B36" ;;
        139) echo "B37" ;;
        140) echo "B38" ;;
        141) echo "B39" ;;
        142) echo "B40" ;;
        143) echo "B18" ;;
        144) echo "B19" ;;
        145) echo "B20" ;;
        146) echo "B21" ;;
        147) echo "B24" ;;
        148) echo "B25" ;;
        149) echo "B41" ;;
        150) echo "B42" ;;
        151) echo "B43" ;;
        152) echo "B23" ;;
        153) echo "B26" ;;
        154) echo "B32" ;;
        155) echo "B125" ;;
        156) echo "B126" ;;
        157) echo "B127" ;;
        158) echo "B28" ;;
        159) echo "B29" ;;
        160) echo "B30" ;;
        161) echo "B66" ;;
        162) echo "B250" ;;
        163) echo "B46" ;;
        166) echo "B71" ;;
        167) echo "B47" ;;
        168) echo "B48" ;;
        250) echo "N1" ;;
        251) echo "N2" ;;
        252) echo "N3" ;;
        253) echo "N5" ;;
        254) echo "N7" ;;
        255) echo "N8" ;;
        256) echo "N20" ;;
        257) echo "N28" ;;
        258) echo "N38" ;;
        259) echo "N41" ;;
        260) echo "N50" ;;
        261) echo "N51" ;;
        262) echo "N66" ;;
        263) echo "N70" ;;
        264) echo "N71" ;;
        265) echo "N74" ;;
        266) echo "N75" ;;
        267) echo "N76" ;;
        268) echo "N77" ;;
        269) echo "N78" ;;
        270) echo "N79" ;;
        271) echo "N80" ;;
        272) echo "N81" ;;
        273) echo "N82" ;;
        274) echo "N83" ;;
        275) echo "N84" ;;
        276) echo "N85" ;;
        277) echo "N257" ;;
        278) echo "N258" ;;
        279) echo "N259" ;;
        280) echo "N260" ;;
        281) echo "N261" ;;
        282) echo "N12" ;;
        283) echo "N25" ;;
        284) echo "N34" ;;
        285) echo "N39" ;;
        286) echo "N40" ;;
        287) echo "N65" ;;
        288) echo "N86" ;;
        289) echo "N48" ;;
        290) echo "N14" ;;
        291) echo "N13" ;;
        292) echo "N18" ;;
        293) echo "N26" ;;
        294) echo "N30" ;;
        295) echo "N29" ;;
        296) echo "N53" ;;
        *) echo "$band_num" ;;
    esac
}

cell_info()
{
    m_debug  "Telit cell info"

    ca_response=$(cmd_cainfoext_query "$at_port")

    parsed=$(telit_parse_response telit.cainfoext "$ca_response") || return
    network_mode=$(printf "%s" "$parsed" | jq -r .network_mode)
    band=$(printf "%s" "$parsed" | jq -r .band)
    bw=$(printf "%s" "$parsed" | jq -r .bandwidth)
    arfcn=$(printf "%s" "$parsed" | jq -r .arfcn)
    pci=$(printf "%s" "$parsed" | jq -r .pci)
    rsrp=$(printf "%s" "$parsed" | jq -r .rsrp)
    rsrq=$(printf "%s" "$parsed" | jq -r .rsrq)
    rssi=$(printf "%s" "$parsed" | jq -r .rssi)
    sinr=$(printf "%s" "$parsed" | jq -r .sinr)
    tac=$(printf "%s" "$parsed" | jq -r .tac)
    tx_power=$(printf "%s" "$parsed" | jq -r .tx_power)
    ul_mod=$(printf "%s" "$parsed" | jq -r .ul_mod)
    dl_mod=$(printf "%s" "$parsed" | jq -r .dl_mod)

    class="Cell Information"
    add_plain_info_entry "network_mode" "$network_mode" "Network Mode"
    add_plain_info_entry "Band" "$band" "Band"
    add_plain_info_entry "Bandwidth" "$bw" "Bandwidth"
    add_plain_info_entry "ARFCN" "$arfcn" "Absolute Radio-Frequency Channel Number"
    add_plain_info_entry "Physical Cell ID" "$pci" "Physical Cell ID"
    add_plain_info_entry "TAC" "$tac" "Tracking Area Code"
    add_plain_info_entry "DL/UL MOD" "$dl_mod / $ul_mod" "DL/UL MOD"
    add_plain_info_entry "TX Power" "$tx_power" "TX Power"
    add_bar_info_entry "RSRP" "$rsrp" "Reference Signal Received Power" -140 -44 dBm
    add_bar_info_entry "RSRQ" "$rsrq" "Reference Signal Received Quality" -19.5 -3 dB
    add_bar_info_entry "RSSI" "$rssi" "Received Signal Strength Indicator" -120 -20 dBm
    add_bar_info_entry "SINR" "$sinr" "Signal to Interference plus Noise Ratio Bandwidth" 0 30 dB
}
