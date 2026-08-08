#!/bin/sh
# Copyright (C) 2025 Fujr <fjrcn@outlook.com>
_Vendor="Gosuncn"
_Author="Fujr"
_Maintainer="Fujr <fjrcn@outlook.com>"
source "${QMODEM_HOME:-/usr/share/qmodem}/generic.sh"
debug_subject="gosuncn_ctrl"
_gosuncn_parse(){ local id="$1" raw="$2" context="$3"; [ -n "$context" ]||context='{}'; printf '%s' "$raw"|"${QMODEM_HOME:-/usr/share/qmodem}/parsers/parse.sh" "$id" --platform "${platform:-unknown}" --model "${model:-unknown}" --context-json "$context"; }
_gosuncn_set(){ local id="$1" raw="$2" parsed; parsed=$(_gosuncn_parse "$id" "$raw"); printf '%s' "$parsed"|jq -r '.result//empty'; }

#获取LTE带宽
# $1:带宽数字
get_lte_bw() {
    local bw_num="$1"
    local bw
    case "$bw_num" in
        "0") bw="1.4" ;;
        "1") bw="3" ;;
        "2"|"3"|"4"|"5") bw="$(((bw_num - 1) * 5))" ;;
        *) bw="" ;;
    esac
    echo "$bw"
}

#将十六进制频段掩码转换为频段号列表
convert2band()
{
    local hex_band="$1"
    local hex=$(echo "$hex_band" | grep -o "[0-9A-Fa-f]\{1,16\}" | tr 'a-f' 'A-F')
    if [ -z "$hex" ]; then
        return
    fi
    local band_list=""
    local bin=$(echo "ibase=16;obase=2;$hex" | bc)
    local len=${#bin}
    local i
    for i in $(seq 1 ${#bin}); do
        if [ "${bin:$((i-1)):1}" = "1" ]; then
            band_list="$band_list $((len - i + 1))"
        fi
    done
    echo "$band_list" | tr ' ' '\n' | sort -n | tr '\n' ' '
}

#将频段号列表转换为十六进制掩码
convert2hex()
{
    local band_list="$1"
    band_list=$(echo "$band_list" | tr ',' '\n' | sort -n | uniq)
    local hex="0"
    local band
    for band in $band_list; do
        local add_hex=$(echo "obase=16;2^($band - 1)" | bc)
        hex=$(echo "obase=16;ibase=16;$hex + $add_hex" | bc)
    done
    if [ -n "$hex" ]; then
        echo "$hex"
    fi
}

get_imei(){
    local raw parsed; raw=$(cmd_cgsn "$at_port"); parsed=$(_gosuncn_parse gosuncn.cgsn "$raw"); imei=$(printf '%s' "$parsed"|jq -r '.imei//empty')
    json_add_string imei "$imei"
}

set_imei(){
    local imei="$1"
    local raw; raw=$(cmd_egmr_set_imei "$at_port" "$imei"); _gosuncn_set gosuncn.egmr.set "$raw"
}

#获取拨号模式
get_mode()
{
    case "$platform" in
        "qualcomm")
            local raw parsed; raw=$(cmd_zswitch_query "$at_port"); parsed=$(_gosuncn_parse gosuncn.zswitch "$raw"); local mode_raw=$(printf '%s' "$parsed"|jq -r '.mode//empty')
            case "$mode_raw" in
                "e") mode="mbim" ;;
                "x") mode="rmnet" ;;
                "r") mode="rndis" ;;
                "E") mode="ecm" ;;
                *) mode="$mode_raw" ;;
            esac
        ;;
        "lte")
            local raw parsed; raw=$(cmd_zswitch_query "$at_port"); parsed=$(_gosuncn_parse gosuncn.zswitch "$raw"); local mode_raw=$(printf '%s' "$parsed"|jq -r '.mode//empty')
            case "$mode_raw" in
                "e") mode="mbim" ;;
                "x") mode="rmnet" ;;
                "r") mode="rndis" ;;
                "l") mode="ecm" ;;
                *) mode="$mode_raw" ;;
            esac
        ;;
        *)
            local raw parsed; raw=$(cmd_zswitch_query "$at_port"); parsed=$(_gosuncn_parse gosuncn.zswitch "$raw"); local mode_raw=$(printf '%s' "$parsed"|jq -r '.mode//empty')
            case "$mode_raw" in
                "e") mode="mbim" ;;
                "x") mode="rmnet" ;;
                "r") mode="rndis" ;;
                "E") mode="ecm" ;;
                *) mode="$mode_raw" ;;
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

#设置拨号模式
set_mode()
{
    local mode=$1
    case $mode in
        "mbim")
            local raw; raw=$(cmd_zswitch_set "$at_port" "e"); _gosuncn_set gosuncn.zswitch.set "$raw"
            ;;
        "rmnet")
            local raw; raw=$(cmd_zswitch_set "$at_port" "x"); _gosuncn_set gosuncn.zswitch.set "$raw"
            ;;
        "rndis")
            local raw; raw=$(cmd_zswitch_set "$at_port" "r"); _gosuncn_set gosuncn.zswitch.set "$raw"
            ;;
        "ecm")
            local raw; raw=$(cmd_zswitch_set "$at_port" "E"); _gosuncn_set gosuncn.zswitch.set "$raw"
            ;;
        *)
            echo "Invalid mode"
            return 1
            ;;
    esac
}

#获取网络偏好
get_network_prefer()
{
    case "$platform" in
        "qualcomm")
            get_network_prefer_qualcomm
        ;;
        "lte")
            get_network_prefer_lte
        ;;
        *)
            get_network_prefer_lte
        ;;
    esac
}

get_network_prefer_lte()
{
    # AT+ZSNT? 返回格式: +ZSNT: cm_mode,net_sel_mode,pref_acq
    # cm_mode: 0=自动, 2=WCDMA, 6=LTE
    local raw parsed; raw=$(cmd_zsnt_query "$at_port"); parsed=$(_gosuncn_parse gosuncn.zsnt "$raw"); local cm_mode=$(printf '%s' "$parsed"|jq -r '.cm_mode//empty')

    network_prefer_3g="0"
    network_prefer_4g="0"

    case "$cm_mode" in
        "0") network_prefer_3g="1"; network_prefer_4g="1" ;;
        "2") network_prefer_3g="1" ;;
        "6") network_prefer_4g="1" ;;
    esac

    json_add_object network_prefer
    json_add_string 3G "$network_prefer_3g"
    json_add_string 4G "$network_prefer_4g"
    json_close_object
}

get_network_prefer_qualcomm()
{
    local raw parsed; raw=$(cmd_zsnt_query "$at_port"); parsed=$(_gosuncn_parse gosuncn.zsnt "$raw"); local cm_mode=$(printf '%s' "$parsed"|jq -r '.cm_mode//empty')

    network_prefer_3g="0"
    network_prefer_4g="0"
    network_prefer_5g="0"

    case "$cm_mode" in
        "0") network_prefer_3g="1"; network_prefer_4g="1"; network_prefer_5g="1" ;;
        "2") network_prefer_3g="1" ;;
        "6") network_prefer_4g="1" ;;
    esac

    json_add_object network_prefer
    json_add_string 3G "$network_prefer_3g"
    json_add_string 4G "$network_prefer_4g"
    json_add_string 5G "$network_prefer_5g"
    json_close_object
}

#设置网络偏好
set_network_prefer()
{
    network_prefer_3g=$(echo $1 | jq -r 'contains(["3G"])')
    network_prefer_4g=$(echo $1 | jq -r 'contains(["4G"])')
    network_prefer_5g=$(echo $1 | jq -r 'contains(["5G"])')
    local length=$(echo $1 | jq -r 'length')

    case "$platform" in
        "qualcomm")
            set_network_prefer_qualcomm "$length"
        ;;
        "lte")
            set_network_prefer_lte "$length"
        ;;
        *)
            set_network_prefer_lte "$length"
        ;;
    esac
}

set_network_prefer_lte()
{
    local length="$1"
    local zsnt_mode

    case "$length" in
        "1")
            if [ "$network_prefer_3g" = "true" ]; then
                zsnt_mode="2,0,0"
            elif [ "$network_prefer_4g" = "true" ]; then
                zsnt_mode="6,0,0"
            fi
            ;;
        "2")
            zsnt_mode="0,0,0"
            ;;
        *)
            zsnt_mode="0,0,0"
            ;;
    esac

    local raw; raw=$(cmd_zsnt_set "$at_port" "$zsnt_mode"); _gosuncn_set gosuncn.zsnt.set "$raw"
}

set_network_prefer_qualcomm()
{
    local length="$1"
    local zsnt_mode

    case "$length" in
        "1")
            if [ "$network_prefer_3g" = "true" ]; then
                zsnt_mode="2,0,0"
            elif [ "$network_prefer_4g" = "true" ]; then
                zsnt_mode="6,0,0"
            fi
            ;;
        *)
            zsnt_mode="0,0,0"
            ;;
    esac

    local raw; raw=$(cmd_zsnt_set "$at_port" "$zsnt_mode"); _gosuncn_set gosuncn.zsnt.set "$raw"
}

#获取温度
get_temperature()
{
    local raw parsed; raw=$(cmd_mtsm "$at_port"); parsed=$(_gosuncn_parse gosuncn.mtsm "$raw"); local temp=$(printf '%s' "$parsed"|jq -r '.temperature//empty')
    if [ -n "$temp" ]; then
        temp="${temp}$(printf "\xc2\xb0")C"
    fi
    add_plain_info_entry "temperature" "$temp" "Temperature"
}

#获取锁频信息
get_lockband()
{
    json_add_object "lockband"
    case "$platform" in
        "qualcomm")
            get_lockband_qualcomm
        ;;
        "lte")
            get_lockband_lte
        ;;
        *)
            get_lockband_lte
        ;;
    esac
    json_close_object
}

get_lockband_lte()
{
    m_debug "Gosuncn LTE get lockband info"
    # AT+ZBAND? 返回当前锁定的LTE频段
    # AT+ZBAND=? 返回支持的LTE频段
    local raw parsed; raw=$(cmd_zband_query "$at_port"); parsed=$(_gosuncn_parse gosuncn.zband "$raw"); local modem_info=$(printf '%s' "$parsed"|jq -r '.lte//empty')
    raw=$(cmd_zband_list_query "$at_port"); parsed=$(_gosuncn_parse gosuncn.zband.list "$raw"); local LTE_LOCK_SUPPORTBAND=$(printf '%s' "$parsed"|jq -r '.lte//empty')

    local lte_avalible_band=""
    [ -n "$(uci -q get qmodem.$config_section.lte_band)" ] && lte_avalible_band=$(uci -q get qmodem.$config_section.lte_band | tr '/' ',')

    json_add_object "LTE"
    json_add_array "available_band"
    if [ -n "$lte_avalible_band" ]; then
        for band in $(echo "$lte_avalible_band" | tr ',' '\n' | sort -n | uniq); do
            add_avalible_band_entry "$band" "LTE_B$band"
        done
    elif [ -n "$LTE_LOCK_SUPPORTBAND" ]; then
        for band in $(echo "$LTE_LOCK_SUPPORTBAND" | tr ',' '\n' | sort -n | uniq); do
            add_avalible_band_entry "$band" "LTE_B$band"
        done
    fi
    json_close_array

    json_add_array "lock_band"
    if [ -n "$modem_info" ]; then
        for band in $(echo "$modem_info" | tr ',' '\n' | sort -n | uniq); do
            json_add_string "" "$band"
        done
    fi
    json_close_array
    json_close_object
}

get_lockband_qualcomm()
{
    m_debug "Gosuncn qualcomm get lockband info"
    local raw parsed; raw=$(cmd_zband_query "$at_port"); parsed=$(_gosuncn_parse gosuncn.zband "$raw"); local modem_info=$(printf '%s' "$parsed"|jq -r '.lte//empty')
    raw=$(cmd_zband_list_query "$at_port"); parsed=$(_gosuncn_parse gosuncn.zband.list "$raw"); local LTE_LOCK_SUPPORTBAND=$(printf '%s' "$parsed"|jq -r '.lte//empty')

    local lte_avalible_band=""
    [ -n "$(uci -q get qmodem.$config_section.lte_band)" ] && lte_avalible_band=$(uci -q get qmodem.$config_section.lte_band | tr '/' ',')

    json_add_object "LTE"
    json_add_array "available_band"
    if [ -n "$lte_avalible_band" ]; then
        for band in $(echo "$lte_avalible_band" | tr ',' '\n' | sort -n | uniq); do
            add_avalible_band_entry "$band" "LTE_B$band"
        done
    elif [ -n "$LTE_LOCK_SUPPORTBAND" ]; then
        for band in $(echo "$LTE_LOCK_SUPPORTBAND" | tr ',' '\n' | sort -n | uniq); do
            add_avalible_band_entry "$band" "LTE_B$band"
        done
    fi
    json_close_array

    json_add_array "lock_band"
    if [ -n "$modem_info" ]; then
        for band in $(echo "$modem_info" | tr ',' '\n' | sort -n | uniq); do
            json_add_string "" "$band"
        done
    fi
    json_close_array
    json_close_object
}

#设置锁频
set_lockband()
{
    m_debug "Gosuncn set lockband info"
    local config="$1"
    local band_class=$(echo "$config" | jq -r '.band_class')
    local lock_band=$(echo "$config" | jq -r '.lock_band')

    case "$platform" in
        "qualcomm")
            set_lockband_qualcomm "$band_class" "$lock_band"
        ;;
        "lte")
            set_lockband_lte "$band_class" "$lock_band"
        ;;
        *)
            set_lockband_lte "$band_class" "$lock_band"
        ;;
    esac

    json_select "result"
    json_add_string "set_lockband" "$res"
    json_add_string "config" "$config"
    json_add_string "band_class" "$band_class"
    json_add_string "lock_band" "$lock_band"
    json_close_object
}

set_lockband_lte()
{
    local band_class="$1"
    local lock_band="$2"

    if [ -z "$lock_band" ] || [ "$lock_band" = "null" ]; then
        # 解锁所有频段
        local raw parsed; raw=$(cmd_zband_reset_all "$at_port"); parsed=$(_gosuncn_parse gosuncn.zband.reset "$raw"); res=$(printf '%s' "$parsed"|jq -r '.result//empty')
    else
        local hex=$(convert2hex "$lock_band")
        m_debug "Lock LTE band hex: $hex"
        local raw parsed; raw=$(cmd_zband_set_nr "$at_port" "$hex"); parsed=$(_gosuncn_parse gosuncn.zband.set "$raw"); res=$(printf '%s' "$parsed"|jq -r '.result//empty')
    fi
}

set_lockband_qualcomm()
{
    local band_class="$1"
    local lock_band="$2"

    if [ -z "$lock_band" ] || [ "$lock_band" = "null" ]; then
        local raw parsed; raw=$(cmd_zband_reset_all "$at_port"); parsed=$(_gosuncn_parse gosuncn.zband.reset "$raw"); res=$(printf '%s' "$parsed"|jq -r '.result//empty')
    else
        local hex=$(convert2hex "$lock_band")
        m_debug "Lock LTE band hex: $hex"
        local raw parsed; raw=$(cmd_zband_set_nr "$at_port" "$hex"); parsed=$(_gosuncn_parse gosuncn.zband.set "$raw"); res=$(printf '%s' "$parsed"|jq -r '.result//empty')
    fi
}

#SIM卡信息
sim_info()
{
    m_debug "Gosuncn sim info"
    class="SIM Information"

    #IMEI
    local raw parsed; raw=$(cmd_cgsn "$at_port"); parsed=$(_gosuncn_parse gosuncn.cgsn "$raw"); imei=$(printf '%s' "$parsed"|jq -r '.imei//empty')

    #SIM Status
    raw=$(cmd_cpin_query "$at_port"); parsed=$(_gosuncn_parse gosuncn.cpin "$raw"); sim_status_flag=$(printf '%s' "$parsed"|jq -r '.status_line//empty')
    sim_status=$(get_sim_status "$sim_status_flag")

    if [ "$sim_status" != "ready" ]; then
        add_plain_info_entry "SIM Status" "$sim_status" "SIM Status"
        add_plain_info_entry "IMEI" "$imei" "International Mobile Equipment Identity"
        return
    fi

    #ISP
    raw=$(cmd_cops_numeric "$at_port"); _gosuncn_parse gosuncn.cops.numeric "$raw" >/dev/null 2>&1
    raw=$(cmd_cops_query "$at_port"); parsed=$(_gosuncn_parse gosuncn.cops "$raw"); isp=$(printf '%s' "$parsed"|jq -r '.operator//empty')

    #SIM Number
    raw=$(cmd_cnum "$at_port"); parsed=$(_gosuncn_parse gosuncn.cnum "$raw"); sim_number=$(printf '%s' "$parsed"|jq -r '.number//empty')

    #IMSI
    raw=$(cmd_cimi "$at_port"); parsed=$(_gosuncn_parse gosuncn.cimi "$raw"); imsi=$(printf '%s' "$parsed"|jq -r '.imsi//empty')

    #ICCID
    raw=$(cmd_iccid "$at_port"); parsed=$(_gosuncn_parse gosuncn.iccid "$raw"); iccid=$(printf '%s' "$parsed"|jq -r '.iccid//empty')

    add_plain_info_entry "SIM Status" "$sim_status" "SIM Status"
    add_plain_info_entry "ISP" "$isp" "Internet Service Provider"
    add_plain_info_entry "SIM Slot" "$sim_slot" "SIM Slot"
    add_plain_info_entry "SIM Number" "$sim_number" "SIM Number"
    add_plain_info_entry "IMEI" "$imei" "International Mobile Equipment Identity"
    add_plain_info_entry "IMSI" "$imsi" "International Mobile Subscriber Identity"
    add_plain_info_entry "ICCID" "$iccid" "Integrate Circuit Card Identity"
}

#基本信息
base_info()
{
    m_debug "Gosuncn base info"
    class="Base Information"

    #Name
    local raw parsed; raw=$(cmd_cgmm "$at_port"); parsed=$(_gosuncn_parse gosuncn.cgmm "$raw"); name=$(printf '%s' "$parsed"|jq -r '.name//empty')

    #Manufacturer
    raw=$(cmd_cgmi "$at_port"); parsed=$(_gosuncn_parse gosuncn.cgmi "$raw"); manufacturer=$(printf '%s' "$parsed"|jq -r '.manufacturer//empty')

    #Revision
    raw=$(cmd_cgmr "$at_port"); parsed=$(_gosuncn_parse gosuncn.cgmr "$raw"); revision=$(printf '%s' "$parsed"|jq -r '.revision//empty')

    add_plain_info_entry "name" "$name" "Name"
    add_plain_info_entry "manufacturer" "$manufacturer" "Manufacturer"
    add_plain_info_entry "revision" "$revision" "Revision"
    add_plain_info_entry "at_port" "$at_port" "AT Port"
    get_temperature
    get_connect_status
}

#网络信息
network_info()
{
    m_debug "Gosuncn network info"

    #Network Type（网络类型）
    local raw parsed; raw=$(cmd_cops_query "$at_port"); parsed=$(_gosuncn_parse gosuncn.cops "$raw"); local carrier=$(printf '%s' "$parsed"|jq -r '.operator//empty'); local rat_num=$(printf '%s' "$parsed"|jq -r '.rat_code//empty')
    local network_type=$(get_rat $rat_num)

    #CSQ
    raw=$(cmd_csq "$at_port"); parsed=$(_gosuncn_parse gosuncn.csq "$raw"); response=$(printf '%s' "$parsed"|jq -r '.rssi_code//empty')

    class="Network Information"
    add_plain_info_entry "Network Type" "$network_type" "Network Type"
    add_plain_info_entry "Carrier" "$carrier" "Carrier"
}

#小区信息
cell_info()
{
    m_debug "Gosuncn cell info"

    case "$platform" in
        "qualcomm")
            cell_info_qualcomm
        ;;
        "lte")
            cell_info_lte
        ;;
        *)
            cell_info_lte
        ;;
    esac
}

cell_info_lte()
{
    # AT+ZCELLINFO? 返回 +ZCELLINFO: <TAC>,cellid:<CellID>,pci:<PCI>,band:<Band>
    local raw parsed; raw=$(cmd_zcellinfo_query "$at_port"); parsed=$(_gosuncn_parse gosuncn.zcellinfo "$raw"); local zcellinfo=$parsed
    raw=$(cmd_cops_query "$at_port"); parsed=$(_gosuncn_parse gosuncn.cops "$raw"); local rat_num=$(printf '%s' "$parsed"|jq -r '.rat_code//empty')
    local network_type=$(get_rat $rat_num)

    if [ -z "$zcellinfo" ]; then
        return
    fi

    # 解析 ZCELLINFO 字段
    local tac=$(printf '%s' "$zcellinfo"|jq -r '.tac//empty')
    local cell_id=$(printf '%s' "$zcellinfo"|jq -r '.cell_id//empty')
    local pci=$(printf '%s' "$zcellinfo"|jq -r '.pci//empty')
    local lband=$(printf '%s' "$zcellinfo"|jq -r '.band//empty')

    # 获取信号质量
    raw=$(cmd_cesq "$at_port"); parsed=$(_gosuncn_parse gosuncn.cesq "$raw"); local cesq_response=$(printf '%s' "$parsed"|jq -r '.rssi_code//empty')
    local rsrp="" rsrq="" sinr=""
    if [ -n "$cesq_response" ]; then
        # +CESQ: rxlev,ber,rscp,ecno,rsrq,rsrp
        rsrq=$(echo "$cesq_response" | awk -F',' '{print $5}' | tr -d ' ')
        rsrp=$(echo "$cesq_response" | awk -F',' '{print $6}' | tr -d ' \r')
        # 转换 RSRP: 实际值 = 报告值 - 141
        if [ -n "$rsrp" ] && [ "$rsrp" != "255" ]; then
            rsrp=$(($rsrp - 141))
        else
            rsrp=""
        fi
        # 转换 RSRQ: 实际值 = (报告值 / 2) - 19.5
        if [ -n "$rsrq" ] && [ "$rsrq" != "255" ]; then
            rsrq=$(echo "$rsrq" | awk '{printf "%.1f", ($1 / 2) - 19.5}')
        else
            rsrq=""
        fi
    fi

    # 获取 RSSI/SINR（通过CSQ）
    raw=$(cmd_csq "$at_port"); parsed=$(_gosuncn_parse gosuncn.csq "$raw"); local csq_response="+CSQ: $(printf '%s' "$parsed"|jq -r '.rssi_code//empty' 2>/dev/null)"
    local rssi=""
    if [ -n "$csq_response" ]; then
        local csq_num=$(echo "$csq_response" | awk -F'[:,]' '{print $2}' | tr -d ' ')
        if [ "$csq_num" != "99" ] && [ -n "$csq_num" ]; then
            rssi="$((2 * csq_num - 113))"
        fi
    fi

    # 获取MCC/MNC
    raw=$(cmd_cops_numeric "$at_port"); _gosuncn_parse gosuncn.cops.numeric "$raw" >/dev/null 2>&1
    raw=$(cmd_cops_query "$at_port"); parsed=$(_gosuncn_parse gosuncn.cops "$raw"); local cops_num=$(printf '%s' "$parsed"|jq -r '.operator//empty')
    local mcc="" mnc=""
    if [ -n "$cops_num" ] && [ ${#cops_num} -ge 5 ]; then
        mcc=${cops_num:0:3}
        mnc=${cops_num:3}
    fi

    class="Cell Information"
    case "$network_type" in
        "LTE")
            network_mode="LTE Mode"
            add_plain_info_entry "network_mode" "$network_mode" "Network Mode"
            set_4g_cell_info "$mcc" "$mnc" "$tac" "$cell_id" "" "$pci" "$lband" "" "" "$rsrp" "$rsrq" "" "" ""
            add_bar_info_entry "RSSI" "$rssi" "Received Signal Strength Indicator" -120 -20 dBm
            ;;
        "WCDMA")
            network_mode="WCDMA Mode"
            add_plain_info_entry "network_mode" "$network_mode" "Network Mode"
            add_plain_info_entry "LAC" "$tac" "Location Area Code"
            add_plain_info_entry "Cell ID" "$cell_id" "Cell ID"
            add_plain_info_entry "PSC" "$pci" "Primary Scrambling Code"
            add_plain_info_entry "Band" "$lband" "Band"
            add_bar_info_entry "RSSI" "$rssi" "Received Signal Strength Indicator" -120 -20 dBm
            ;;
        *)
            network_mode="${network_type} Mode"
            add_plain_info_entry "network_mode" "$network_mode" "Network Mode"
            add_plain_info_entry "TAC" "$tac" "Tracking Area Code"
            add_plain_info_entry "Cell ID" "$cell_id" "Cell ID"
            add_plain_info_entry "PCI" "$pci" "Physical Cell ID"
            add_plain_info_entry "Band" "$lband" "Band"
            add_bar_info_entry "RSSI" "$rssi" "Received Signal Strength Indicator" -120 -20 dBm
            ;;
    esac
}

cell_info_qualcomm()
{
    local raw parsed; raw=$(cmd_zcellinfo_query "$at_port"); parsed=$(_gosuncn_parse gosuncn.zcellinfo "$raw"); local zcellinfo=$parsed
    raw=$(cmd_cops_query "$at_port"); parsed=$(_gosuncn_parse gosuncn.cops "$raw"); local rat_num=$(printf '%s' "$parsed"|jq -r '.rat_code//empty')
    local network_type=$(get_rat $rat_num)

    if [ -z "$zcellinfo" ]; then
        return
    fi

    local tac=$(printf '%s' "$zcellinfo"|jq -r '.tac//empty')
    local cell_id=$(printf '%s' "$zcellinfo"|jq -r '.cell_id//empty')
    local pci=$(printf '%s' "$zcellinfo"|jq -r '.pci//empty')
    local lband=$(printf '%s' "$zcellinfo"|jq -r '.band//empty')

    raw=$(cmd_cesq "$at_port"); parsed=$(_gosuncn_parse gosuncn.cesq "$raw"); local cesq_response=$(printf '%s' "$parsed"|jq -r '.rssi_code//empty')
    local rsrp="" rsrq=""
    if [ -n "$cesq_response" ]; then
        rsrq=$(echo "$cesq_response" | awk -F',' '{print $5}' | tr -d ' ')
        rsrp=$(echo "$cesq_response" | awk -F',' '{print $6}' | tr -d ' \r')
        if [ -n "$rsrp" ] && [ "$rsrp" != "255" ]; then
            rsrp=$(($rsrp - 141))
        else
            rsrp=""
        fi
        if [ -n "$rsrq" ] && [ "$rsrq" != "255" ]; then
            rsrq=$(echo "$rsrq" | awk '{printf "%.1f", ($1 / 2) - 19.5}')
        else
            rsrq=""
        fi
    fi

    raw=$(cmd_csq "$at_port"); parsed=$(_gosuncn_parse gosuncn.csq "$raw"); local csq_response="+CSQ: $(printf '%s' "$parsed"|jq -r '.rssi_code//empty' 2>/dev/null)"
    local rssi=""
    if [ -n "$csq_response" ]; then
        local csq_num=$(echo "$csq_response" | awk -F'[:,]' '{print $2}' | tr -d ' ')
        if [ "$csq_num" != "99" ] && [ -n "$csq_num" ]; then
            rssi="$((2 * csq_num - 113))"
        fi
    fi

    raw=$(cmd_cops_numeric "$at_port"); _gosuncn_parse gosuncn.cops.numeric "$raw" >/dev/null 2>&1
    raw=$(cmd_cops_query "$at_port"); parsed=$(_gosuncn_parse gosuncn.cops "$raw"); local cops_num=$(printf '%s' "$parsed"|jq -r '.operator//empty')
    local mcc="" mnc=""
    if [ -n "$cops_num" ] && [ ${#cops_num} -ge 5 ]; then
        mcc=${cops_num:0:3}
        mnc=${cops_num:3}
    fi

    class="Cell Information"
    case "$network_type" in
        "LTE")
            network_mode="LTE Mode"
            add_plain_info_entry "network_mode" "$network_mode" "Network Mode"
            set_4g_cell_info "$mcc" "$mnc" "$tac" "$cell_id" "" "$pci" "$lband" "" "" "$rsrp" "$rsrq" "" "" ""
            add_bar_info_entry "RSSI" "$rssi" "Received Signal Strength Indicator" -120 -20 dBm
            ;;
        "WCDMA")
            network_mode="WCDMA Mode"
            add_plain_info_entry "network_mode" "$network_mode" "Network Mode"
            add_plain_info_entry "LAC" "$tac" "Location Area Code"
            add_plain_info_entry "Cell ID" "$cell_id" "Cell ID"
            add_plain_info_entry "PSC" "$pci" "Primary Scrambling Code"
            add_plain_info_entry "Band" "$lband" "Band"
            add_bar_info_entry "RSSI" "$rssi" "Received Signal Strength Indicator" -120 -20 dBm
            ;;
        *)
            network_mode="${network_type} Mode"
            add_plain_info_entry "network_mode" "$network_mode" "Network Mode"
            add_plain_info_entry "TAC" "$tac" "Tracking Area Code"
            add_plain_info_entry "Cell ID" "$cell_id" "Cell ID"
            add_plain_info_entry "PCI" "$pci" "Physical Cell ID"
            add_plain_info_entry "Band" "$lband" "Band"
            add_bar_info_entry "RSSI" "$rssi" "Received Signal Strength Indicator" -120 -20 dBm
            ;;
    esac
}

#邻区信息（Gosuncn LTE平台暂不支持）
get_neighborcell()
{
    json_add_object "neighborcell"
    json_add_array "LTE"
    json_close_array
    json_add_object "lockcell_status"
    json_add_string "LTE" "unlock"
    json_close_object
    qmodem_lockcell_boot_hook_add_json "$config_section"
    json_close_object
}

set_neighborcell()
{
    json_select "result"
    json_add_string "setlockcell" "not supported"
    json_close_object
}

vendor_get_disabled_features()
{
    json_add_string "" "NeighborCell"
}

#重启模组
soft_reboot()
{
    cmd_cfun_soft_reboot "$at_port"
}

#重置模组
reset_module()
{
    cmd_zsnt_reset "$at_port" 2>&1 > /dev/null
    cmd_zband_reset_all "$at_port" 2>&1 > /dev/null
    cmd_atf_factory "$at_port" 2>&1 > /dev/null
}
