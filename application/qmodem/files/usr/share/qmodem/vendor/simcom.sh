#!/bin/sh
# Copyright (C) 2025 sfwtw <sfwtw@qq.com>
_Vendor="simcom"
_Author="sfwtw,fujr"
_Maintainer="sfwtw <sfwtw@qq.com>"
source "${QMODEM_HOME:-/usr/share/qmodem}/generic.sh"
debug_subject="quectel_ctrl"

simcom_parse_field()
{
    local parser_id="$1" field="$2" raw="$3" parsed
    parsed=$(printf '%s' "$raw" | "${QMODEM_PARSER:-${QMODEM_HOME:-/usr/share/qmodem}/parsers/parse.sh}" \
        "$parser_id" --platform "${platform:-unknown}" --model "${model:-${QMODEM_TESTCASE_MODEL:-unknown}}" --context-json '{}') || return
    printf '%s' "$parsed" | jq -r --arg field "$field" '.[$field] // empty'
}

simcom_parse_response()
{
    local parser_id="$1" raw="$2"
    printf '%s' "$raw" | "${QMODEM_PARSER:-${QMODEM_HOME:-/usr/share/qmodem}/parsers/parse.sh}" \
        "$parser_id" --platform "${platform:-unknown}" --model "${model:-unknown}" --context-json '{}'
}

simcom_json_field()
{
    printf '%s' "$1" | jq -r --arg field "$2" '.[$field] // empty'
}
#return raw data
get_imei(){
    response=$(cmd_cgsn "$at_port"); imei=$(simcom_parse_field simcom.cgsn imei "$response")
    json_add_string "imei" "$imei"
}

#return raw data
set_imei(){
    local imei="$1"
    res=$(cmd_simei_set "$at_port" "$imei")
    res=$(simcom_parse_field simcom.command.completion result "$res")
    json_select "result"
    json_add_string "set_imei" "$res"
    json_close_object
    get_imei
}

#获取拨号模式
# $1:AT串口
# $2:平台
get_mode()
{
    case "$platform" in
        "qualcomm")
            local response mode_num
            response=$(cmd_cusbcfg_query "$at_port"); mode_num=$(simcom_parse_field simcom.cusbcfg.usbid mode_num "$response")
            local mode
            pcie_cfg=$(cmd_cpciemode_query "$at_port")
            pcie_mode=$(simcom_parse_field simcom.cpciemode pcie_mode "$pcie_cfg")
            if [ "$pcie_mode" = "EP" ] && [ "$mode_num" = "902B" ]; then
                mode_num="9001"
            json_add_int disable_mode_btn 1
            fi
            case "$mode_num" in
                "9001") mode="qmi" ;;
                "9011") mode="rndis" ;;
                *) mode="${mode_num}" ;;
            esac
        ;;
        "lte")
            config=$(cmd_myconfig_query "$at_port")
            config=$(simcom_parse_response simcom.myconfig "$config")
            param1=$(simcom_json_field "$config" usbnet_mode)
            param2=$(simcom_json_field "$config" auxiliary)
            case $param1 in
                "0") mode="rndis" ;;
                "1") mode="ecm" ;;
                "2") mode="auto" ;;
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

#设置拨号模式
set_mode()
{
    #获取拨号模式配置
    local mode=$1
    case "$platform" in
        "qualcomm")
            case "$mode" in
                "qmi") mode_num="9001" ;;
                "rndis") mode_num="9011" ;;
                *) mode_num="0" ;;
            esac
            #设置模组
            res=$(cmd_cusbcfg_set_usbid "$at_port" "$mode_num")
            res=$(simcom_parse_field simcom.command.completion result "$res")
            json_select "result"
            json_add_string "set_mode" "$res"
            json_close_object
        ;;
        "lte")
            case "$mode" in
                "ecm") param1="1" ;;
                "rndis") param1="0" ;;
                "auto") param1="2" ;;
                *) param1="0" ;;
            esac
            res=$(cmd_myconfig_set_usbnetmode "$at_port" "$param1")
            res=$(simcom_parse_field simcom.command.completion result "$res")
            json_select "result"
            json_add_string "set_mode" "$res"
            json_close_object
        ;;
        *)
            mode_num="0"
        ;;
    esac

}

#获取网络偏好
# $1:AT串口
get_network_prefer()
{
    case "$platform" in
        "qualcomm")
            get_network_prefer_nr
        ;;
        *)
            get_network_prefer_nr
        ;;
    esac
    json_add_object network_prefer
    json_add_string 3G $network_prefer_3g
    json_add_string 4G $network_prefer_4g
    case $platform in
        "qualcomm")
            json_add_string 5G $network_prefer_5g
        ;;
    esac
    json_close_array
    
}

get_network_prefer_nr()
{
    local raw response
    raw=$(cmd_cnmp_query "$at_port")
    response=$(simcom_parse_field simcom.cnmp mode "$raw")
    
    network_prefer_3g="0";
    network_prefer_4g="0";
    network_prefer_5g="0";

    #匹配不同的网络类型
    local auto=$(echo "${response}" | grep "2")
    if [ -n "$auto" ]; then
        network_prefer_3g="1"
        network_prefer_4g="1"
        network_prefer_5g="1"
    else
        local wcdma=$(echo "${response}" | grep "14" || echo "${response}" | grep "54" || echo "${response}" | grep "55")
        local lte=$(echo "${response}" | grep "38" || echo "${response}" | grep "54" || echo "${response}" | grep "109")
        local nr=$(echo "${response}" | grep "71" || echo "${response}" | grep "55" || echo "${response}" | grep "109")
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
}

#设置网络偏好
# $1:AT串口
# $2:网络偏好配置
set_network_prefer()
{
    network_prefer_3g=$(echo $1 |jq -r 'contains(["3G"])')
    network_prefer_4g=$(echo $1 |jq -r 'contains(["4G"])')
    network_prefer_5g=$(echo $1 |jq -r 'contains(["5G"])')
    length=$(echo $1 |jq -r 'length')

    case "$platform" in
        "qualcomm")
            set_network_prefer_nr $at_port $network_prefer
        ;;
        *)
            set_network_prefer_nr $at_port $network_prefer
        ;;
    esac
}

set_network_prefer_nr()
{
    case "$length" in
        "1")
            if [ "$network_prefer_3g" = "true" ]; then
                network_prefer_config="14"
            elif [ "$network_prefer_4g" = "true" ]; then
                network_prefer_config="38"
            elif [ "$network_prefer_5g" = "true" ]; then
                network_prefer_config="71"
            fi
        ;;
        "2")
            if [ "$network_prefer_3g" = "true" ] && [ "$network_prefer_4g" = "true" ]; then
                network_prefer_config="54"
            elif [ "$network_prefer_3g" = "true" ] && [ "$network_prefer_5g" = "true" ]; then
                network_prefer_config="55"
            elif [ "$network_prefer_4g" = "true" ] && [ "$network_prefer_5g" = "true" ]; then
                network_prefer_config="109"
            fi
        ;;
        "3") network_prefer_config="2" ;;
        *) network_prefer_config="2" ;;
    esac

    #设置模组
    cmd_cnmp_set "$at_port" "$network_prefer_config"
}

#获取电压
# $1:AT串口
get_voltage()
{
    local raw voltage
    raw=$(cmd_cbc "$at_port")
    voltage=$(simcom_parse_field simcom.cbc.voltage voltage "$raw" | sed 's/V//g')
    [ -n "$voltage" ] && {
        add_plain_info_entry "voltage" "$voltage V" "Voltage" 
    }
}

#获取温度
#return raw data
get_temperature()
{   
    #Temperature（温度）
    local temp
    local line=1
    QTEMP=$(cmd_cpmutemp "$at_port")
    temp=$(simcom_parse_field simcom.cpmutemp temperature "$QTEMP")
    if [ -n "$temp" ]; then
        temp="${temp}$(printf "\xc2\xb0")C"
    fi
    add_plain_info_entry "temperature" "$temp" "Temperature"
}



#基本信息
base_info()
{
    m_debug  "Quectel base info"

    #Name（名称）
    response=$(cmd_cgmm "$at_port"); name=$(simcom_parse_field simcom.cgmm name "$response")
    #Manufacturer（制造商）
    response=$(cmd_cgmi "$at_port"); manufacturer=$(simcom_parse_field simcom.cgmi manufacturer "$response")
    #Revision（固件版本）
    response=$(cmd_simcomati "$at_port"); revision=$(simcom_parse_field simcom.ati.revision revision "$response")
    # at_command="AT+CGMR"
    # revision=$(at $at_port $at_command | sed -n '2p' | sed 's/\r//g')
    class="Base Information"
    add_plain_info_entry "name" "$name" "Name"
    add_plain_info_entry "manufacturer" "$manufacturer" "Manufacturer"
    add_plain_info_entry "revision" "$revision" "Revision"
    add_plain_info_entry "at_port" "$at_port" "AT Port"
    get_temperature
    get_voltage
    get_connect_status
}


#SIM卡信息
sim_info()
{
    m_debug  "Quectel sim info"
    
    #SIM Slot（SIM卡卡槽）
    response=$(cmd_smsimcfg_query "$at_port"); sim_slot=$(simcom_parse_field simcom.smsimcfg.slot sim_slot "$response")

    #IMEI（国际移动设备识别码）
    response=$(cmd_cgsn "$at_port"); imei=$(simcom_parse_field simcom.cgsn imei "$response")

    #SIM Status（SIM状态）
    response=$(cmd_cpin_query "$at_port"); sim_status_flag=$(simcom_parse_field simcom.cpin.status status_text "$response")
    sim_status=$(get_sim_status "$sim_status_flag")

    if [ "$sim_status" != "ready" ]; then
        return
    fi

    #ISP（互联网服务提供商）
    response=$(cmd_cops_query "$at_port"); isp=$(simcom_parse_field simcom.cops.operator operator "$response")
    # if [ "$isp" = "CHN-CMCC" ] || [ "$isp" = "CMCC" ]|| [ "$isp" = "46000" ]; then
    #     isp="中国移动"
    # # elif [ "$isp" = "CHN-UNICOM" ] || [ "$isp" = "UNICOM" ] || [ "$isp" = "46001" ]; then
    # elif [ "$isp" = "CHN-UNICOM" ] || [ "$isp" = "CUCC" ] || [ "$isp" = "46001" ]; then
    #     isp="中国联通"
    # # elif [ "$isp" = "CHN-CT" ] || [ "$isp" = "CT" ] || [ "$isp" = "46011" ]; then
    # elif [ "$isp" = "CHN-TELECOM" ] || [ "$isp" = "CTCC" ] || [ "$isp" = "46011" ]; then
    #     isp="中国电信"
    # fi

    #SIM Number（SIM卡号码，手机号）
    response=$(cmd_cnum "$at_port"); sim_number=$(simcom_parse_field simcom.cnum number "$response")

    #IMSI（国际移动用户识别码）
    response=$(cmd_cimi "$at_port"); imsi=$(simcom_parse_field simcom.cimi imsi "$response")

    #ICCID（集成电路卡识别码）
    response=$(cmd_iccid "$at_port"); iccid=$(simcom_parse_field simcom.iccid iccid "$response")
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

#网络信息
network_info()
{
    m_debug  "Simcom network info"

    response=$(cmd_cpsi_query "$at_port"); network_type=$(simcom_parse_field simcom.cpsi.type network_type "$response")

    [ -z "$network_type" ] && {
        response=$(cmd_cops_query "$at_port"); local rat_num=$(simcom_parse_field simcom.cops.rat rat_code "$response")
        network_type=$(get_rat ${rat_num})
    }

    class="Network Information"
    add_plain_info_entry "Network Type" "$network_type" "Network Type"
}

#获取频段
# $1:网络类型
# $2:频段数字
get_band()
{
    local band
    band=$(echo $1 | sed 's/^0-9//g')
    echo "$band"
}

normalize_hex_width()
{
    local value="$1"
    local width="$2"
    local hex

    value=$(echo "$value" | tr -d '\r' | xargs)
    [ -z "$value" ] && value="0"

    case "$value" in
        0x*|0X*) hex=${value#0x}; hex=${hex#0X} ;;
        *) hex=$value ;;
    esac

    hex=$(echo "$hex" | tr 'a-f' 'A-F')
    hex=$(echo "$hex" | grep -o '^[0-9A-F]\+$')
    [ -z "$hex" ] && hex="0"

    if [ ${#hex} -lt "$width" ]; then
        hex=$(printf "%0${width}s" "$hex" | tr ' ' '0')
    fi

    echo "0x$hex"
}

get_lockband_nr()
{
    local at_port="$1"
    m_debug  "Quectel sdx55 get lockband info"
    wcdma_avalible_band="1,2,3,4,5,6,8,9,19"
    lte_avalible_band="1,2,3,4,5,7,8,12,13,14,17,18,19,20,25,26,28,29,30,32,34,38,39,40,41,42,43,48,66,71"
    nsa_nr_avalible_band="1,2,3,5,7,8,12,20,28,38,40,41,48,66,71,77,78,79"
    sa_nr_avalible_band="1,2,3,5,7,8,12,20,28,38,40,41,48,66,71,77,78,79"
    [ -n $(uci -q get qmodem.$config_section.sa_band) ] && sa_nr_avalible_band=$(uci -q get qmodem.$config_section.sa_band | tr '/' ',')
    [ -n $(uci -q get qmodem.$config_section.nsa_band) ] && nsa_nr_avalible_band=$(uci -q get qmodem.$config_section.nsa_band | tr '/' ',')
    [ -n $(uci -q get qmodem.$config_section.lte_band) ] && lte_avalible_band=$(uci -q get qmodem.$config_section.lte_band | tr '/' ',')
    [ -n $(uci -q get qmodem.$config_section.wcdma_band) ] && wcdma_avalible_band=$(uci -q get qmodem.$config_section.wcdma_band | tr '/' ',')
    gw_band=$(cmd_csyssel_query "$at_port" w_band); gw_band=$(simcom_parse_response simcom.csyssel "$gw_band")
    lte_band=$(cmd_csyssel_query "$at_port" lte_band); lte_band=$(simcom_parse_response simcom.csyssel "$lte_band")
    nsa_nr_band=$(cmd_csyssel_query "$at_port" nsa_nr5g_band); nsa_nr_band=$(simcom_parse_response simcom.csyssel "$nsa_nr_band")
    sa_nr_band=$(cmd_csyssel_query "$at_port" nr5g_band); sa_nr_band=$(simcom_parse_response simcom.csyssel "$sa_nr_band")
    json_add_object "UMTS"
    json_add_array "available_band"
    json_close_array
    json_add_array "lock_band"
    json_close_object
    json_close_object
    json_add_object "LTE"
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
    json_add_object "NR_NSA"
    json_add_array "available_band"
    json_close_array
    json_add_array "lock_band"
    json_close_array
    json_close_object
    for i in $(echo "$wcdma_avalible_band" | awk -F"," '{for(j=1; j<=NF; j++) print $j}'); do
        json_select "UMTS"
        json_select "available_band"
        add_avalible_band_entry  "$i" "UMTS_$i"
        json_select ..
        json_select ..
    done
    for i in $(echo "$lte_avalible_band" | awk -F"," '{for(j=1; j<=NF; j++) print $j}'); do
        json_select "LTE"
        json_select "available_band"
        add_avalible_band_entry  "$i" "LTE_B$i"
        json_select ..
        json_select ..
    done
    for i in $(echo "$nsa_nr_avalible_band" | awk -F"," '{for(j=1; j<=NF; j++) print $j}'); do
        json_select "NR_NSA"
        json_select "available_band"
        add_avalible_band_entry  "$i" "NSA_NR_N$i"
        json_select ..
        json_select ..
    done
    for i in $(echo "$sa_nr_avalible_band" | awk -F"," '{for(j=1; j<=NF; j++) print $j}'); do
        json_select "NR"
        json_select "available_band"
        add_avalible_band_entry  "$i" "SA_NR_N$i"
        json_select ..
        json_select ..
    done
    #+QNWPREFCFG: "nr5g_band",1:3:7:20:28:40:41:71:77:78:79
    for i in $(printf '%s' "$gw_band" | jq -r '.bands[]'); do
        if [ -n "$i" ]; then
            json_select "UMTS"
            json_select "lock_band"
            json_add_string "" "$i"
            json_select ..
            json_select ..
        fi
    done
    for i in $(printf '%s' "$lte_band" | jq -r '.bands[]'); do
        if [ -n "$i" ]; then
            json_select "LTE"
            json_select "lock_band"
            json_add_string "" "$i"
            json_select ..
            json_select ..
        fi
    done
    for i in $(printf '%s' "$nsa_nr_band" | jq -r '.bands[]'); do
        if [ -n "$i" ]; then
            json_select "NR_NSA"
            json_select "lock_band"
            json_add_string "" "$i"
            json_select ..
            json_select ..
        fi
    done
    for i in $(printf '%s' "$sa_nr_band" | jq -r '.bands[]'); do
        if [ -n "$i" ]; then
            json_select "NR"
            json_select "lock_band"
            json_add_string "" "$i"
            json_select ..
            json_select ..
        fi
    done
    json_close_array
}

convert2band()
{
    local hex_band="$1"
    local hex

    hex=$(echo "$hex_band" | tr -d '\r' | tr 'a-f' 'A-F' | sed 's/^0X//')
    hex=$(echo "$hex" | grep -o "^[0-9A-F]\{1,16\}$")
    [ -z "$hex" ] && return

    local band_list=""
    local bin
    bin=$(echo "ibase=16;obase=2;$hex" | bc)
    local len=${#bin}
    local i
    for i in $(seq 1 ${#bin}); do
        if [ "${bin:$((i-1)):1}" = "1" ]; then
            band_list="$band_list $((len - i + 1))"
        fi
    done

    echo "$band_list" | tr ' ' '\n' | sort -n | tr '\n' ' '
}

convert2hex_lte()
{
    local band_list="$1"
    local hex="0"
    local band

    band_list=$(echo "$band_list" | tr ', ' '\n' | grep -E '^[0-9]+$' | sort -n | uniq)
    for band in $band_list; do
        [ "$band" -le 0 ] && continue
        local add_hex
        add_hex=$(echo "obase=16;2^($band - 1)" | bc)
        hex=$(echo "obase=16;ibase=16;$hex + $add_hex" | bc)
    done

    hex=$(echo "$hex" | tr 'a-f' 'A-F')
    echo "0x$hex"
}

convert2hex_lte_ext()
{
    local band_list="$1"
    local hex="0"
    local band
    local ext_band

    band_list=$(echo "$band_list" | tr ', ' '\n' | grep -E '^[0-9]+$' | sort -n | uniq)
    for band in $band_list; do
        [ "$band" -le 32 ] && continue
        ext_band=$((band - 32))
        [ "$ext_band" -le 0 ] && continue
        local add_hex
        add_hex=$(echo "obase=16;2^($ext_band - 1)" | bc)
        hex=$(echo "obase=16;ibase=16;$hex + $add_hex" | bc)
    done

    hex=$(echo "$hex" | tr 'a-f' 'A-F')
    echo "0x$hex"
}

get_wcdma_band_name_lte()
{
    #手册是傻逼，实际计算的bitmap频段和手册上标注的频段不一样，实际频段=标注频段+1
    band_num=$(($1))
    case "$1" in
        "8") echo "GSM_DCS_1800" ;;
        "9") echo "GSM_EGSM_900" ;;
        "10") echo "GSM_PGSM_900" ;;
        "17") echo "GSM_450" ;;
        "18") echo "GSM_480" ;;
        "19") echo "GSM_750" ;;
        "20") echo "GSM_850" ;;
        "21") echo "GSM_RGSM_900" ;;
        "22") echo "GSM_PCS_1900" ;;
        "23") echo "WCDMA_IMT_2000" ;;
        "24") echo "WCDMA_PCS_1900" ;;
        "25") echo "WCDMA_III_1700" ;;
        "26") echo "WCDMA_IV_1700" ;;
        "27") echo "WCDMA_850" ;;
        "28") echo "WCDMA_800" ;;
        "49") echo "WCDMA_VII_2600" ;;
        "50") echo "WCDMA_VIII_900" ;;
        "51") echo "WCDMA_IX_1700" ;;
        *) echo "UMTS_B$1" ;;
    esac
}

get_lockband_lte(){
    local at_port="$1"
    m_debug "SimCom LTE platform get lockband info"
    
    # WCDMA available bands
    local gsm_available_band="7,8,9,16,17,18,19,20,21"
    local wcdma_available_band="22,23,24,25,26,27,48,49,50"
    [ -n "$(uci -q get qmodem.$config_section.wcdma_band)" ] && wcdma_available_band=$(uci -q get qmodem.$config_section.wcdma_band | tr '/' ',')
    
    # LTE available bands  
    local lte_available_band="1,2,3,4,5,7,8,12,13,14,17,18,19,20,25,26,28,29,30,32,34,38,39,40,41,42,43,48,66,71"
    [ -n "$(uci -q get qmodem.$config_section.lte_band)" ] && lte_available_band=$(uci -q get qmodem.$config_section.lte_band | tr '/' ',')
    
    # Get current modem settings
    local response=$(cmd_cnbp_query "$at_port")
    
    # Parse response: +CNBP:<mode>[,<lte_mode>][,<lte_modeExt>][,<saveMode>]
    local mode=$(simcom_parse_field simcom.cnbp mode "$response")
    local lte_mode=$(simcom_parse_field simcom.cnbp lte_mode "$response")
    local lte_modeext=$(simcom_parse_field simcom.cnbp lte_modeext "$response")
    
    # Parse WCDMA locked bands from mode
    local wcdma_locked_bands=""
    if [ -n "$mode" ] && [ "$mode" != "0" ]; then
        wcdma_locked_bands=$(convert2band "$mode")
    fi
    
    # Parse LTE locked bands from lte_mode
    local lte_locked_bands=""
    if [ -n "$lte_mode" ] && [ "$lte_mode" != "0" ]; then
        lte_locked_bands=$(convert2band "$lte_mode")
    fi
    
    # Parse extended LTE bands from lte_modeext
    local lte_locked_bands_ext=""
    if [ -n "$lte_modeext" ] && [ "$lte_modeext" != "0" ]; then
        lte_locked_bands_ext=$(convert2band "$lte_modeext")
    fi
    
    # Combine all LTE bands
    [ -n "$lte_locked_bands_ext" ] && lte_locked_bands="$lte_locked_bands $lte_locked_bands_ext"
    lte_locked_bands=$(echo "$lte_locked_bands" | xargs -n1 | sort -n | uniq | tr '\n' ' ' | xargs)
    
    # Output JSON
    json_add_object "UMTS"
    json_add_array "available_band"
    for i in $(echo "$wcdma_available_band" | tr ',' ' '); do
        add_avalible_band_entry "$i" "$(get_wcdma_band_name_lte "$i")"
    done
    json_close_array
    json_add_array "lock_band"
    for i in $wcdma_locked_bands; do
        json_add_string "" "$i"
    done
    json_close_array
    json_close_object
    
    json_add_object "LTE"
    json_add_array "available_band"
    for i in $(echo "$lte_available_band" | tr ',' ' '); do
        add_avalible_band_entry "$i" "LTE_B$i"
    done
    json_close_array
    json_add_array "lock_band"
    for i in $lte_locked_bands; do
        json_add_string "" "$i"
    done
    json_close_array
    json_close_object
}

get_lockband()
{
    json_add_object "lockband"
    case "$platform" in
        "qualcomm")
            get_lockband_nr $at_port
        ;;
        "lte")
            get_lockband_lte $at_port
            ;;
        *)
            get_lockband_nr $at_port
        ;;
    esac
    json_close_object
}

set_lockband_nr(){
    lock_band=$(echo $lock_band | tr ',' ':')
    case "$band_class" in
        "UMTS") 
            res=$(cmd_csyssel_set "$at_port" w_band "$lock_band")
            res=$(simcom_parse_field simcom.command.completion result "$res")
            ;;
        "LTE") 
            res=$(cmd_csyssel_set "$at_port" lte_band "$lock_band")
            res=$(simcom_parse_field simcom.command.completion result "$res")
            ;;
        "NR_NSA")
            res=$(cmd_csyssel_set "$at_port" nsa_nr5g_band "$lock_band")
            res=$(simcom_parse_field simcom.command.completion result "$res")
            ;;
        "NR")
            res=$(cmd_csyssel_set "$at_port" nr5g_band "$lock_band")
            res=$(simcom_parse_field simcom.command.completion result "$res")
            ;;
    esac
}

set_lockband_lte(){
    m_debug "SimCom LTE platform set lockband info"
    case "$band_class" in
        "UMTS")
            # Convert WCDMA band list to hex format using bitmap
            local wcdma_hex=$(convert2hex_lte "$lock_band")
            wcdma_hex=$(normalize_hex_width "$wcdma_hex" 16)
            res=$(cmd_cnbp_set "$at_port" "$wcdma_hex")
            res=$(simcom_parse_field simcom.command.completion result "$res")
            ;;
        "LTE")
            # Convert LTE band list to hex format using bitmap
            local lte_bands=$(echo $lock_band | cut -d' ' -f1-32 | tr ' ' ',')
            local lte_ext_bands=$(echo $lock_band | awk '{for(i=1;i<=NF;i++) if($i>32) print $i}' | tr '\n' ',')
            
            local lte_hex=$(convert2hex_lte "$lte_bands")
            local lte_ext_hex="0x0"
            [ -n "$lte_ext_bands" ] && lte_ext_hex=$(convert2hex_lte_ext "$lte_ext_bands")
                lte_hex=$(normalize_hex_width "$lte_hex" 16)
                lte_ext_hex=$(normalize_hex_width "$lte_ext_hex" 4)
            
            # Set bands: mode format is 0x<wcdma_hex>
            # Get current WCDMA bands first by reading
            local response=$(cmd_cnbp_query "$at_port")
            local current_mode=$(simcom_parse_field simcom.cnbp mode "$response")
            [ -z "$current_mode" ] && current_mode="0x0"
                current_mode=$(normalize_hex_width "$current_mode" 16)
            
            res=$(cmd_cnbp_set "$at_port" "$current_mode,$lte_hex,$lte_ext_hex,0")
            res=$(simcom_parse_field simcom.command.completion result "$res")
            ;;
    esac
}

#设置锁频
set_lockband()
{
    m_debug "simcom set lockband info"
    config=$1
    #{"band_class":"UMTS","lock_band":"1,2,3"} or {"band_class":"LTE","lock_band":"1,2,3"}
    band_class=$(echo $config | jq -r '.band_class')
    lock_band=$(echo $config | jq -r '.lock_band')
    case "$platform" in
        "lte")
            set_lockband_lte
            ;;
        *)
            set_lockband_nr
        ;;
    esac
    json_select "result"
    json_add_string "set_lockband" "$res"
    json_add_string "config" "$config"
    json_add_string "band_class" "$band_class"
    json_add_string "lock_band" "$lock_band"
    json_close_object
}

get_neighborcell_qualcomm(){
    lte_status=$(cmd_ccellcfg_query "$at_port"); lte_status=$(simcom_parse_response simcom.ccellcfg "$lte_status")
    if [ "$(simcom_json_field "$lte_status" locked)" = "true" ]; then
        lte_lock_status="locked"
    else
        lte_lock_status=""
    fi
    lte_lock_freq=$(simcom_json_field "$lte_status" arfcn)
    lte_lock_pci=$(simcom_json_field "$lte_status" pci)
    nr_status=$(cmd_c5gcellcfg_query "$at_port"); nr_status=$(simcom_parse_response simcom.c5gcellcfg "$nr_status")
    nr_lock_pci=$(simcom_json_field "$nr_status" pci)
    nr_lock_freq=$(simcom_json_field "$nr_status" arfcn)
    nr_lock_scs=$(simcom_json_field "$nr_status" scs)
    nr_lock_band=$(simcom_json_field "$nr_status" band)
    if [ "$(simcom_json_field "$nr_status" locked)" = "true" ]; then
        nr_lock_status="locked"
    else
        nr_lock_status=""
    fi

    modem_status=$(cmd_cpsi_query "$at_port")
    modem_status=$(simcom_parse_response simcom.cpsi "$modem_status")
    modem_status_net=$(printf '%s' "$modem_status" | jq -r '.records[0].rat // empty')
    modem_status_band=$(printf '%s' "$modem_status" | jq -r '.records[0].band_code // empty' | sed 's/.*BAND//')
    if [ "$modem_status_net" = "NR5G_SA" ];then
        scans=$(cmd_cnwsearch_query "$at_port" "nr5g")
        sleep 10
        cmd_cnwsearch_scan "$at_port" "nr5g" 3 > /tmp/neighborcell
    elif [ "$modem_status_net" = "LTE" ];then
        cmd_cnwsearch_scan "$at_port" "lte" 1 > /tmp/neighborcell
        sleep 5
    fi
    json_add_object "Feature"
    json_add_string "Unlock" "2"
    json_add_string "Lock PCI" "1"
    json_add_string "Reboot Modem" "4"
    json_add_string "Manually Search" "3"
    json_close_object
    json_add_array "NR"
    json_close_array
    json_add_array "LTE"
    json_close_array
    json_add_object "lockcell_status"
    if [ -n "$lte_lock_status" ]; then
        json_add_string "LTE" "$lte_lock_status"
        json_add_string "LTE_Freq" "$lte_lock_freq"
        json_add_string "LTE_PCI" "$lte_lock_pci"
    else
        json_add_string "LTE" "unlock"
    fi
    if [ -n "$nr_lock_status" ]; then
        json_add_string "NR" "$nr_lock_status"
        json_add_string "NR_Freq" "$nr_lock_freq"
        json_add_string "NR_PCI" "$nr_lock_pci"
        json_add_string "NR_SCS" "$nr_lock_scs"
        json_add_string "NR_Band" "$nr_lock_band"
    else
        json_add_string "NR" "unlock"
    fi
    json_close_object
    simcom_parse_response simcom.cnwsearch "$(cat /tmp/neighborcell)" | jq -r '.cells[] | [.rat,.mnc,.arfcn,.pci,.rscp,.ecno,.rsrp,.rsrq,.band] | @tsv' > /tmp/neighborcell.semantic
    while IFS="$(printf '\t')" read -r type mnc arfcn pci rscp ecno rsrp rsrq band; do
            [ "$type" = "NR" ] && band=$modem_status_band
            json_select $type
            json_add_object ""
        json_add_string "mnc" "$mnc"
            json_add_string "arfcn" "$arfcn"
            json_add_string "pci" "$pci"
            json_add_string "rscp" "$rscp"
            json_add_string "ecno" "$ecno"
            json_add_string "rsrp" "$rsrp"
            json_add_string "rsrq" "$rsrq"
            json_add_string "band" "$band"
            json_close_object
            json_select ".."
    done < /tmp/neighborcell.semantic
    rm -f /tmp/neighborcell.semantic
}

get_neighborcell(){
    m_debug  "quectel set lockband info"
    json_add_object "neighborcell"
    case "$platform" in
        "qualcomm")
            get_neighborcell_qualcomm
        ;;
    esac
    qmodem_lockcell_boot_hook_add_json "$config_section"
    json_close_object
}

set_neighborcell(){
    #at_port,func,celltype,arfcn,pci,scs,nrband
    #  "lockpci" "1"
    #  "unlockcell" "2"
    #  "manually search" "3"
    #  "reboot modem" "4"
    json_param=$1
# {\"rat\":1,\"pci\":\"113\",\"arfcn\":\"627264\",\"band\":\"\",\"scs\":0}"
    rat=$(echo $json_param | jq -r '.rat')
    pci=$(echo $json_param | jq -r '.pci')
    arfcn=$(echo $json_param | jq -r '.arfcn')
    band=$(echo $json_param | jq -r '.band')
    scs=$(echo $json_param | jq -r '.scs')
    en_boot_hook=$(echo $json_param | jq -r '.en_boot_hook // empty')
    case $platform in
        "qualcomm")
            lockcell_qualcomm
            ;;
    esac
    json_select "result"
    json_add_string "setlockcell" "$res"
    json_add_string "rat" "$rat"
    json_add_string "pci" "$pci"
    json_add_string "arfcn" "$arfcn"
    json_add_string "band" "$band"
    json_add_string "scs" "$scs"
    if qmodem_bool_enabled "$(uci -q get "qmodem.${config_section}.lockcell_boot_hook_enabled")"; then
        json_add_boolean "boot_hook_enabled" 1
    else
        json_add_boolean "boot_hook_enabled" 0
    fi
    json_close_object
}

lockcell_qualcomm(){
    if [ -z "$pci" ] && [ -z "$arfcn" ]; then
        res1=$(cmd_c5gcellcfg_unlock "$at_port")
        res2=$(cmd_ccellcfg_unlock "$at_port")
        res1=$(simcom_parse_field simcom.command.completion result "$res1")
        res2=$(simcom_parse_field simcom.command.completion result "$res2")
        res=$res1,$res2
        qmodem_lockcell_boot_hook_clear "$config_section"
    else
        lock4g="AT+CCELLCFG=1,$pci,$arfcn;+CNMP=38"
        locknr="AT+C5GCELLCFG=\"pci\",$pci,$arfcn,$scs,$band;+CNMP=71"
        if [ $rat = "1" ]; then
            lockcell_boot_cmd="$locknr"
            res=$(cmd_c5gcellcfg_lock "$at_port" "$pci" "$arfcn" "$scs" "$band")
            res=$(simcom_parse_field simcom.command.completion result "$res")
        else
            lockcell_boot_cmd="$lock4g"
            res=$(cmd_ccellcfg_lock "$at_port" "$pci" "$arfcn")
            res=$(simcom_parse_field simcom.command.completion result "$res")
        fi
        qmodem_lockcell_boot_hook_sync "$config_section" "$en_boot_hook" "$lockcell_boot_cmd"
    fi
   
}

unlockcell(){
    res2=$(cmd_c5gcellcfg_unlock "$1")
    res3=$(cmd_ccellcfg_unlock "$1")
    res2=$(simcom_parse_field simcom.command.completion result "$res2")
    res3=$(simcom_parse_field simcom.command.completion result "$res3")
}
#UL_bandwidth
# $1:上行带宽数字
get_bandwidth()
{
    local network_type="$1"
    local bandwidth_num="$2"

    local bandwidth
    case $network_type in
        "LTE")
            case $bandwidth_num in
                "0") bandwidth="1.4" ;;
                "1") bandwidth="3" ;;
                "2"|"3"|"4"|"5") bandwidth=$((($bandwidth_num - 1) * 5)) ;;
            esac
        ;;
        "NR")
            case $bandwidth_num in
                "0"|"1"|"2"|"3"|"4"|"5") bandwidth=$((($bandwidth_num + 1) * 5)) ;;
                "6"|"7"|"8"|"9"|"10"|"11"|"12") bandwidth=$((($bandwidth_num - 2) * 10)) ;;
                "13") bandwidth="200" ;;
                "14") bandwidth="400" ;;
            esac
        ;;
    esac
    echo "$bandwidth"
}

#获取NR子载波间隔
# $1:NR子载波间隔数字
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

#获取物理信道
# $1:物理信道数字
get_phych()
{
    local phych
    case $1 in
        "0") phych="DPCH" ;;
        "1") phych="FDPCH" ;;
    esac
    echo "$phych"
}

#获取扩频因子
# $1:扩频因子数字
get_sf()
{
    local sf
    case $1 in
        "0"|"1"|"2"|"3"|"4"|"5"|"6"|"7") sf=$(awk "BEGIN{ print 2^$(($1+2)) }") ;;
        "8") sf="UNKNOWN" ;;
    esac
    echo "$sf"
}

#获取插槽格式
# $1:插槽格式数字
get_slot()
{
    local slot=$1
    # case $1 in
        # "0"|"1"|"2"|"3"|"4"|"5"|"6"|"7"|"8"|"9"|"10"|"11"|"12"|"13"|"14"|"15"|"16") slot=$1 ;;
        # "0"|"1"|"2"|"3"|"4"|"5"|"6"|"7"|"8"|"9") slot=$1 ;;
    # esac
    echo "$slot"
}

process_signal_value() {
    local value="$1"
    echo "scale=1; $value / 10" | bc | awk '{printf("%g", $0)}'
}
#小区信息
cell_info()
{
    m_debug  "Quectel cell info"

    response1=$(cmd_cpsi_query "$at_port")
    response2=$(cmd_cnwinfo_query "$at_port")
    response1=$(simcom_parse_response simcom.cpsi "$response1")
    response2=$(simcom_parse_response simcom.cnwinfo "$response2")

    local lte=$(printf '%s' "$response1" | jq -c '.records[] | select(.rat == "LTE")' | head -n1)
    local nr5g_nsa=$(printf '%s' "$response1" | jq -c '.records[] | select(.rat == "NR5G_NSA")' | head -n1)
    local CNWINFO="$response2"
    if [ -n "$lte" ] && [ -n "$nr5g_nsa" ] ; then
        #EN-DC模式
        network_mode="EN-DC Mode"
        #LTE
        # +CPSI: LTE,Online,460-01,0x7496,251941991,203,EUTRAN-BAND8,3740,3,3,-92,-672,-418,14
        # +CPSI: LTE,<OperationMode>[,<MCC>-<MNC>,<TAC>,<SCellID>,<PCellID>,<FrequencyBand>,<earfcn>,<dlbw>,<ulbw>,<RSRQ>,<RSRP>,<RSSI>,<RSSNR>]
        endc_lte_duplex_mode=""
        endc_lte_mcc=$(simcom_json_field "$lte" plmn | cut -d- -f1)
        endc_lte_mnc=$(simcom_json_field "$lte" plmn | cut -d- -f2)
        endc_lte_cell_id=$(simcom_json_field "$lte" cell_id)
        endc_lte_physical_cell_id=$(simcom_json_field "$lte" pci)
        endc_lte_earfcn=$(simcom_json_field "$lte" arfcn)
        endc_lte_freq_band_ind_num=$(simcom_json_field "$lte" band_code)
        endc_lte_freq_band_ind=$(get_band $endc_lte_freq_band_ind_num)
        ul_bandwidth_num=$(simcom_json_field "$lte" ul_bandwidth_code)
        endc_lte_ul_bandwidth=$(get_bandwidth "LTE" $ul_bandwidth_num)
        dl_bandwidth_num=$(simcom_json_field "$lte" dl_bandwidth_code)
        endc_lte_dl_bandwidth=$(get_bandwidth "LTE" $dl_bandwidth_num)
        endc_lte_tac=$(simcom_json_field "$lte" tac)
        endc_lte_rsrp=$(simcom_json_field "$lte" rsrp_tenth)
        endc_lte_rsrp=$(process_signal_value $endc_lte_rsrp)
        endc_lte_rsrq=$(simcom_json_field "$lte" rsrq_tenth)
        endc_lte_rsrq=$(process_signal_value $endc_lte_rsrq)
        endc_lte_rssi=$(simcom_json_field "$lte" rssi_tenth)
        endc_lte_rssi=$(process_signal_value $endc_lte_rssi)
        endc_lte_sinr=$(simcom_json_field "$lte" sinr)
        endc_lte_cql=$(simcom_json_field "$CNWINFO" cqi_or_dlmod)
        endc_lte_tx_power=""
        endc_lte_srxlev=""
        #NR5G-NSA
        # +CPSI: NR5G_NSA,[<PCellID>,<FrequencyBand>,<earfcn/ssb>,<RSRP>,<RSRQ>,<SNR>,<scs>,<NR_dl_bw>]
        endc_nr_mcc=""
        endc_nr_mnc=""
        endc_nr_physical_cell_id=$(simcom_json_field "$nr5g_nsa" pci)
        endc_nr_rsrp=$(simcom_json_field "$nr5g_nsa" rsrp_tenth)
        endc_nr_rsrp=$(process_signal_value $endc_nr_rsrp)
        endc_nr_sinr=$(simcom_json_field "$nr5g_nsa" sinr_tenth)
        endc_nr_sinr=$(process_signal_value $endc_nr_sinr)
        endc_nr_rsrq=$(simcom_json_field "$nr5g_nsa" rsrq_tenth)
        endc_nr_rsrq=$(process_signal_value $endc_nr_rsrq)
        endc_nr_arfcn=$(simcom_json_field "$nr5g_nsa" arfcn)
        endc_nr_band_num=$(simcom_json_field "$nr5g_nsa" band_code)
        endc_nr_band=$(get_band $endc_nr_band_num)
        nr_dl_bandwidth_num=$(simcom_json_field "$nr5g_nsa" dl_bandwidth_code)
        endc_nr_dl_bandwidth=$(get_bandwidth "NR" $nr_dl_bandwidth_num)
        scs_num=$(simcom_json_field "$nr5g_nsa" scs_code)
        endc_nr_scs=$(get_scs $scs_num)
    else
        #SA，LTE，WCDMA模式
        #+CPSI: NR5G_SA,<OperationMode>[,<MCC>-<MNC>,<TAC>,<SCellID>,<PCellID>,<FrequencyBand>,<earfcn>,<RSRP>,<RSRQ>,<SNR>]
        response=$(printf '%s' "$response1" | jq -c '.records[0]')
        local rat=$(simcom_json_field "$response" rat)
        case $rat in
            "NR5G_SA")
                network_mode="NR5G-SA Mode"
                nr_duplex_mode=$(simcom_json_field "$response" operation_mode)
                nr_mcc=$(simcom_json_field "$response" plmn | cut -d- -f1)
                nr_mnc=$(simcom_json_field "$response" plmn | cut -d- -f2)
                nr_cell_id=$(simcom_json_field "$response" cell_id)
                nr_physical_cell_id=$(simcom_json_field "$response" pci)
                nr_tac=$(simcom_json_field "$response" tac)
                nr_arfcn=$(simcom_json_field "$response" arfcn)
                nr_band_num=$(simcom_json_field "$response" band_code)
                nr_band=$(get_band $nr_band_num)
                nr_dl_bandwidth=$(simcom_json_field "$CNWINFO" dl_bandwidth)
                nr_rsrp=$(simcom_json_field "$response" rsrp_tenth)
                nr_rsrp=$(process_signal_value $nr_rsrp)
                nr_rsrq=$(simcom_json_field "$response" rsrq_tenth)
                nr_rsrq=$(process_signal_value $nr_rsrq)
                nr_sinr=$(simcom_json_field "$response" sinr)
                nr_scs_num=""
                nr_scs=$(get_scs $nr_scs_num)
                nr_rxlev=$(simcom_json_field "$CNWINFO" rxlev)
                nr_cql=$(simcom_json_field "$CNWINFO" cqi)
                nr_dlmod=$(simcom_json_field "$CNWINFO" cqi_or_dlmod)
                nr_ulmod=$(simcom_json_field "$CNWINFO" tx_power_or_ulmod)
                nr_tx_power=$(simcom_json_field "$CNWINFO" tx_power)
                nr_rssi=$(simcom_json_field "$CNWINFO" rssi_tenth)
                nr_rssi=$(process_signal_value $nr_rssi)
            ;;
            "LTE")
                # +CPSI: LTE,Online,460-01,0x7496,251941991,203,EUTRAN-BAND8,3740,3,3,-92,-672,-418,14
                # +CPSI: LTE,<OperationMode>[,<MCC>-<MNC>,<TAC>,<SCellID>,<PCellID>,<FrequencyBand>,<earfcn>,<dlbw>,<ulbw>,<RSRQ>,<RSRP>,<RSSI>,<RSSNR>]
                network_mode="LTE Mode"
                lte_mcc=$(simcom_json_field "$response" plmn | cut -d- -f1)
                lte_mnc=$(simcom_json_field "$response" plmn | cut -d- -f2)
                lte_cell_id=$(simcom_json_field "$response" cell_id)
                lte_physical_cell_id=$(simcom_json_field "$response" pci)
                lte_earfcn=$(simcom_json_field "$response" arfcn)
                lte_freq_band_ind_num=$(simcom_json_field "$response" band_code)
                lte_freq_band_ind=$(get_band $lte_freq_band_ind_num)
                ul_bandwidth_num=$(simcom_json_field "$response" ul_bandwidth_code)
                lte_ul_bandwidth=$(get_bandwidth "LTE" $ul_bandwidth_num)
                dl_bandwidth_num=$(simcom_json_field "$response" dl_bandwidth_code)
                lte_dl_bandwidth=$(get_bandwidth "LTE" $dl_bandwidth_num)
                lte_tac=$(simcom_json_field "$response" tac)
                lte_rsrp=$(simcom_json_field "$response" rsrp_tenth)
                lte_rsrp=$(process_signal_value $lte_rsrp)
                lte_rsrq=$(simcom_json_field "$response" rsrq_tenth)
                lte_rsrq=$(process_signal_value $lte_rsrq)
                lte_rssi=$(simcom_json_field "$response" rssi_tenth)
                lte_rssi=$(process_signal_value $lte_rssi)
                lte_sinr=$(simcom_json_field "$response" sinr)
                lte_cql=$(simcom_json_field "$CNWINFO" cqi_or_dlmod)
                lte_tx_power=$(simcom_json_field "$CNWINFO" tx_power_or_ulmod)
                lte_srxlev=$(simcom_json_field "$CNWINFO" srxlev)
            ;;
            "WCDMA")
                # +CPSI: <SystemMode>,<OperationMode>,<MCC>-<MNC>,<LAC>,<Cell ID>,<FrequencyBand>,<PSC>,<Freq>,<SSC>,<EC/IO>,<RSCP>,<Qual>,<RxLev>,<TXPWR>
                # +CPSI: WCDMA,Online,460-01,0xA809,11122855,WCDMAIMT2000,279,10663,0,1.5,62,33,52,500
                network_mode="WCDMA Mode"
                wcdma_mcc=$(simcom_json_field "$response" plmn | cut -d- -f1)
                wcdma_mnc=$(simcom_json_field "$response" plmn | cut -d- -f2)
                wcdma_lac=$(simcom_json_field "$response" lac)
                wcdma_cell_id=$(simcom_json_field "$response" cell_id)
                wcdma_uarfcn=$(simcom_json_field "$response" uarfcn)
                wcdma_psc=$(simcom_json_field "$response" psc)
                wcdma_rscp=$(simcom_json_field "$response" rscp_tenth)
                wcdma_rscp=$(process_signal_value $wcdma_rscp)
                wcdma_ecio=$(simcom_json_field "$response" ecio)
                wcdma_tx_power=$(simcom_json_field "$response" tx_power)
                wcdma_rxlev=$(simcom_json_field "$CNWINFO" rssi_tenth)
            ;;
        esac
    fi
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
        add_plain_info_entry "CQI" "$nr_cql" "Channel Quality Indicator"
        add_plain_info_entry "TX Power" "$nr_tx_power" "TX Power"
        add_plain_info_entry "DL/UL MOD" "$nr_dlmod / $nr_ulmod" "DL/UL MOD"
        add_bar_info_entry "RSRP" "$nr_rsrp" "Reference Signal Received Power" -140 -44 dBm
        add_bar_info_entry "RSRQ" "$nr_rsrq" "Reference Signal Received Quality" -19.5 -3 dB
        add_bar_info_entry "RSSI" "$nr_rssi" "Received Signal Strength Indicator" -120 -20 dBm
        add_bar_info_entry "SINR" "$nr_sinr" "Signal to Interference plus Noise Ratio Bandwidth" 0 30 dB
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
        add_plain_info_entry "TAC" "$endc_lte_tac" "Tracking area code of cell served by neighbor Enb"
        add_bar_info_entry "RSRP" "$endc_lte_rsrp" "Reference Signal Received Power" -140 -44 dBm
        add_bar_info_entry "RSRQ" "$endc_lte_rsrq" "Reference Signal Received Quality" -19.5 -3 dB
        add_bar_info_entry "RSSI" "$endc_lte_rssi" "Received Signal Strength Indicator" -120 -20 dBm
        add_bar_info_entry "SINR" "$endc_lte_sinr" "Signal to Interference plus Noise Ratio Bandwidth" 0 30 dB
        add_plain_info_entry "RxLev" "$endc_lte_rxlev" "Received Signal Level"
        add_plain_info_entry "RSSNR" "$endc_lte_rssnr" "Radio Signal Strength Noise Ratio"
        add_plain_info_entry "CQI" "$endc_lte_cql" "Channel Quality Indicator"
        add_plain_info_entry "TX Power" "$endc_lte_tx_power" "TX Power"
        add_plain_info_entry "Srxlev" "$endc_lte_srxlev" "Serving Cell Receive Level"
        add_plain_info_entry NR5G-NSA "NR5G-NSA" ""
        add_plain_info_entry "MCC" "$endc_nr_mcc" "Mobile Country Code"
        add_plain_info_entry "MNC" "$endc_nr_mnc" "Mobile Network Code"
        add_plain_info_entry "Physical Cell ID" "$endc_nr_physical_cell_id" "Physical Cell ID"
        add_plain_info_entry "ARFCN" "$endc_nr_arfcn" "Absolute Radio-Frequency Channel Number"
        add_plain_info_entry "Band" "$endc_nr_band" "Band"
        add_plain_info_entry "DL Bandwidth" "$endc_nr_dl_bandwidth" "DL Bandwidth"
        add_bar_info_entry "RSRP" "$endc_nr_rsrp" "Reference Signal Received Power" -140 -44 dBm
        add_bar_info_entry "RSRQ" "$endc_nr_rsrq" "Reference Signal Received Quality" -19.5 -3 dB
        add_bar_info_entry "SINR" "$endc_nr_sinr" "Signal to Interference plus Noise Ratio Bandwidth" 0 30 dB
        add_plain_info_entry "SCS" "$endc_nr_scs" "SCS"
        ;;
    "LTE Mode")
        add_plain_info_entry "MCC" "$lte_mcc" "Mobile Country Code"
        add_plain_info_entry "MNC" "$lte_mnc" "Mobile Network Code"
        add_plain_info_entry "Duplex Mode" "$lte_duplex_mode" "Duplex Mode"
        add_plain_info_entry "Cell ID" "$lte_cell_id" "Cell ID"
        add_plain_info_entry "Physical Cell ID" "$lte_physical_cell_id" "Physical Cell ID"
        add_plain_info_entry "EARFCN" "$lte_earfcn" "E-UTRA Absolute Radio Frequency Channel Number"
        add_plain_info_entry "Freq band indicator" "$lte_freq_band_ind" "Freq band indicator"
        add_plain_info_entry "UL Bandwidth" "$lte_ul_bandwidth" "UL Bandwidth"
        add_plain_info_entry "DL Bandwidth" "$lte_dl_bandwidth" "DL Bandwidth"
        add_plain_info_entry "TAC" "$lte_tac" "Tracking area code of cell served by neighbor Enb"
        add_bar_info_entry "RSRP" "$lte_rsrp" "Reference Signal Received Power" -140 -44 dBm
        add_bar_info_entry "RSRQ" "$lte_rsrq" "Reference Signal Received Quality" -19.5 -3 dB
        add_bar_info_entry "RSSI" "$lte_rssi" "Received Signal Strength Indicator" -120 -22 dBm
        add_bar_info_entry "SINR" "$lte_sinr" "Signal to Interference plus Noise Ratio Bandwidth" 0 30 dB
        add_plain_info_entry "CQI" "$lte_cql" "Channel Quality Indicator"
        add_plain_info_entry "TX Power" "$lte_tx_power" "TX Power"
        add_plain_info_entry "Srxlev" "$lte_srxlev" "Serving Cell Receive Level"
        ;;
    "WCDMA Mode")
        add_plain_info_entry "MCC" "$wcdma_mcc" "Mobile Country Code"
        add_plain_info_entry "MNC" "$wcdma_mnc" "Mobile Network Code"
        add_plain_info_entry "LAC" "$wcdma_lac" "Location Area Code"
        add_plain_info_entry "Cell ID" "$wcdma_cell_id" "Cell ID"
        add_plain_info_entry "UARFCN" "$wcdma_uarfcn" "Uplink Absolute Radio Frequency Channel Number"
        add_plain_info_entry "PSC" "$wcdma_psc" "Primary Scrambling Code"
        add_bar_info_entry "RSCP" "$wcdma_rscp" "Received Signal Code Power" -120 -24 dBm
        add_bar_info_entry "EC/IO" "$wcdma_ecio" "Ec/Io" -30 -5 dB
        add_plain_info_entry "Tx Power" "$wcdma_tx_power" "Tx Power"
        add_plain_info_entry "RxLev" "$wcdma_rxlev" "Received Signal Level"
        ;;
    esac
}

vendor_get_disabled_features(){
    case $platform in
        "lte")
            json_add_string "" "NeighborCell"
            ;;
    esac
}
