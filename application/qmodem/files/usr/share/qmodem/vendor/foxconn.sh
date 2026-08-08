#!/bin/sh
# Copyright (C) 2025 x-shark
_Vendor="foxconn"
_Author="x-shark"
_Maintainer="x-shark <unknown>"
source "${QMODEM_HOME:-/usr/share/qmodem}/generic.sh"
debug_subject="foxconn_ctrl"
_foxconn_parse(){ local id="$1" raw="$2" context="$3"; [ -n "$context" ]||context='{}'; printf '%s' "$raw"|"${QMODEM_HOME:-/usr/share/qmodem}/parsers/parse.sh" "$id" --platform "${platform:-unknown}" --model "${model:-unknown}" --context-json "$context"; }

name=$(uci -q get qmodem.$config_section.name)
case "$name" in
    "t99w640")
        at_pre="AT+"
    ;;
    *)
        at_pre="AT^"
    ;;
esac

get_imei(){
    local raw parsed; raw=$(cmd_ati "$at_port"); parsed=$(_foxconn_parse foxconn.ati "$raw"); imei=$(printf '%s' "$parsed"|jq -r '.imei//empty')
    json_add_string imei $imei
}

set_imei(){
    imei=$1
    # 添加 80A 前缀
    extended="80A${imei}"
    swapped=""
    len=${#extended}
    i=0
    while [ $i -lt $len ]; do
        pair=$(echo "$extended" | cut -c$((i+1))-$((i+2)))
        if [ ${#pair} -eq 2 ]; then
            swapped="${swapped}${pair:1:1}${pair:0:1}"
        elif [ ${#pair} -eq 1 ]; then
            swapped="${swapped}${pair:0:1}"
        fi
        i=$((i+2))
    done

    # 两位分组加逗号，并转小写
    formatted=$(echo "$swapped" | sed 's/../&,/g' | sed 's/,$//' | tr 'A-Z' 'a-z')

    local raw parsed
    raw=$(cmd_nv_550_clear "$at_port" "$at_pre"); _foxconn_parse foxconn.nv.clear "$raw" >/dev/null
    raw=$(cmd_nv_550_set "$at_port" "$at_pre" "$formatted"); parsed=$(_foxconn_parse foxconn.nv.set "$raw"); res=$(printf '%s' "$parsed"|jq -r '.result//empty')
    json_select "result"
    json_add_string "set_imei" "$res"
    json_close_object
    get_imei
}

get_mode(){
    local mode_num
    local mode
    local raw parsed; raw=$(cmd_pciemode_query "$at_port" "$at_pre"); parsed=$(_foxconn_parse foxconn.pciemode "$raw"); config_type=$(printf '%s' "$parsed"|jq -r '.config_type//empty')
    if [ "$config_type" = "1" ]; then
        mode_num="0"
    json_add_int disable_mode_btn 1

    else
          raw=$(cmd_usbswitch_query "$at_port" "$at_pre"); parsed=$(_foxconn_parse foxconn.usbswitch "$raw"); config_type=$(printf '%s' "$parsed"|jq -r '.config_type//empty')
          if [ "$config_type" = "9025" ]; then
             mode_num="1"
          elif [ "$config_type" = "90D5" ]; then
             mode_num="0"
        fi
    fi
    case "$platform" in
        "qualcomm")
            case "$mode_num" in
                "0") mode="mbim" ;;
                "1") mode="rmnet" ;;
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

set_mode(){
    local mode=$1
    case "$platform" in
        "qualcomm")
            case "$mode" in
                "mbim") mode_num="90d5" ;;
                "rmnet") mode_num="9025" ;;
                *) mode="90d5" ;;
            esac
        ;;
        *)
            mode_num="90d5"
        ;;
    esac
    #设置模组
    local raw parsed; raw=$(cmd_usbswitch_set "$at_port" "$at_pre" "$mode_num"); parsed=$(_foxconn_parse foxconn.usbswitch.set "$raw"); res=$(printf '%s' "$parsed"|jq -r '.result//empty')
    json_select "result"
    json_add_string "set_mode" "$res"
    json_close_object
}

get_network_prefer(){
    local raw parsed; raw=$(cmd_slmode_query "$at_port" "$at_pre"); parsed=$(_foxconn_parse foxconn.slmode "$raw"); res=$(printf '%s' "$parsed"|jq -r '.code//empty')
# (RAT index): 
# 0 Automatically 
# 1 WCDMA Only
# 2 LTE Only 
# 3 WCDMA And LTE 
# 4 NR5G Only 
# 5 WCDMA And NR5G 
# 6 LTE And NR5G 
# 7 WCDMA And LTE And NR5G
    local network_prefer_3g="0"
    local network_prefer_4g="0"
    local network_prefer_5g="0"
   case $res in
        "10")
            network_prefer_3g="1"
            network_prefer_4g="1"
            network_prefer_5g="1"
            ;;
        "11")
            network_prefer_3g="1"
            ;;
        "12")
            network_prefer_4g="1"
            ;;
        "13")
            network_prefer_3g="1"
            network_prefer_4g="1"
            ;;
        "14")
            network_prefer_5g="1"
            ;;
        "15")
            network_prefer_3g="1"
            network_prefer_5g="1"
            ;;
        "16")
            network_prefer_4g="1"
            network_prefer_5g="1"
            ;;
        "17")
            network_prefer_3g="1"
            network_prefer_4g="1"
            network_prefer_5g="1"
            ;;
        *)
            network_prefer_3g="0"
            network_prefer_4g="0"
            network_prefer_5g="0"
            ;;
    esac
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
                code="11"
            elif [ "$network_prefer_4g" = "true" ]; then
                code="12"
            elif [ "$network_prefer_5g" = "true" ]; then
                code="14"
            fi
            ;;
        "2")
            if [ "$network_prefer_3g" = "true" ] && [ "$network_prefer_4g" = "true" ]; then
                code="13"
            elif [ "$network_prefer_4g" = "true" ] && [ "$network_prefer_5g" = "true" ]; then
                code="16"
            elif [ "$network_prefer_3g" = "true" ] && [ "$network_prefer_5g" = "true" ]; then
                code="15"
            fi
            ;;
        "3")
            code="17"
            ;;
        *)
            code="10"
            ;;
    esac
    local raw parsed; raw=$(cmd_slmode_set "$at_port" "$at_pre" "${code%?},${code#?}"); parsed=$(_foxconn_parse foxconn.slmode.set "$raw"); res=$(printf '%s' "$parsed"|jq -r '.result//empty')
    json_add_string "code" "$code"
    json_add_string "result" "$res"
}



get_lockband(){
    json_add_object "lockband"
    case $platform in
        "qualcomm")
            get_lockband_nr
            ;;
    esac
    json_close_object
}

sim_info()
{
    class="SIM Information"

    #IMEI（国际移动设备识别码）
    local raw parsed; raw=$(cmd_ati "$at_port"); parsed=$(_foxconn_parse foxconn.ati "$raw"); imei=$(printf '%s' "$parsed"|jq -r '.imei//empty')
    
    raw=$(cmd_switch_slot_query "$at_port" "$at_pre"); parsed=$(_foxconn_parse foxconn.switch_slot "$raw"); sim_slot=$(printf '%s' "$parsed"|jq -r '.slot//empty')

    #SIM Status（SIM状态）
    raw=$(cmd_cpin_query "$at_port"); parsed=$(_foxconn_parse foxconn.cpin "$raw"); sim_status=$(printf '%s' "$parsed"|jq -r '.status//empty')

    if [ "$sim_status" != "ready" ]; then
        return
    fi
    
    raw=$(cmd_cops_query "$at_port"); parsed=$(_foxconn_parse foxconn.cops "$raw"); isp=$(printf '%s' "$parsed"|jq -r '.operator//empty')
    if [ "$isp" = "CHN-CMCC" ] || [ "$isp" = "CMCC" ]|| [ "$isp" = "46000" ]; then
         isp="中国移动"
    # # elif [ "$isp" = "CHN-UNICOM" ] || [ "$isp" = "UNICOM" ] || [ "$isp" = "46001" ]; then
    elif [ "$isp" = "CHN-UNICOM" ] || [ "$isp" = "CUCC" ] || [ "$isp" = "46001" ]; then
         isp="中国联通"
    elif [ "$isp" = "CHN-CT" ] || [ "$isp" = "CT" ] || [ "$isp" = "46011" ]; then
    # elif [ "$isp" = "CHN-TELECOM" ] || [ "$isp" = "CTCC" ] || [ "$isp" = "46011" ]; then
         isp="中国电信"
    fi

    raw=$(cmd_cnum "$at_port"); parsed=$(_foxconn_parse foxconn.cnum "$raw"); sim_number=$(printf '%s' "$parsed"|jq -r '.number//empty')

    #IMSI（国际移动用户识别码）
    raw=$(cmd_cimi "$at_port"); parsed=$(_foxconn_parse foxconn.cimi "$raw"); imsi=$(printf '%s' "$parsed"|jq -r '.imsi//empty')

    #ICCID（集成电路卡识别码）
    raw=$(cmd_iccid "$at_port"); parsed=$(_foxconn_parse foxconn.iccid "$raw"); iccid=$(printf '%s' "$parsed"|jq -r '.iccid//empty')
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

base_info(){
        #Name（名称）
    local raw parsed; raw=$(cmd_ati "$at_port"); parsed=$(_foxconn_parse foxconn.ati "$raw"); name=$(printf '%s' "$parsed"|jq -r '.name//empty')
    #Manufacturer（制造商）
    manufacturer=$(printf '%s' "$parsed"|jq -r '.manufacturer//empty')
    #Revision（固件版本）
    revision=$(printf '%s' "$parsed"|jq -r '.revision//empty')
    class="Base Information"
    add_plain_info_entry "manufacturer" "$manufacturer" "Manufacturer"
    add_plain_info_entry "revision" "$revision" "Revision"
    add_plain_info_entry "at_port" "$at_port" "AT Port"
    get_connect_status
    _get_temperature
    _get_voltage
}

network_info() {
    class="Network Information"
    [ -z "$network_type" ] && {
        local raw parsed; raw=$(cmd_cops_query "$at_port"); parsed=$(_foxconn_parse foxconn.cops "$raw"); local rat_num=$(printf '%s' "$parsed"|jq -r '.rat_code//empty')
        network_type=$(get_rat ${rat_num})
    }
    #at_command='AT+debug?'
    #response=$(at $at_port $at_command)
    add_plain_info_entry "Network Type" "$network_type" "Network Type"
}

vendor_get_disabled_features(){
    json_add_string "" "NeighborCell"
}

get_lockband_nr()
{
    m_debug  "Quectel sdx55 get lockband info"
    local raw parsed
    raw=$(cmd_band_pref_query "$at_port" "$at_pre"); parsed=$(_foxconn_parse foxconn.band_pref "$raw")

    # WCDMA
    wcdma_enable=$(printf '%s' "$parsed"|jq -r '.wcdma.enabled[]')
    wcdma_disable=$(printf '%s' "$parsed"|jq -r '.wcdma.disabled[]')
    wcdma_all=$(echo "$wcdma_enable $wcdma_disable" | tr ' ' '\n' | grep -v '^$' | sort -n | uniq)

    # LTE
    lte_enable=$(printf '%s' "$parsed"|jq -r '.lte.enabled[]')
    lte_disable=$(printf '%s' "$parsed"|jq -r '.lte.disabled[]')
    lte_all=$(echo "$lte_enable $lte_disable" | tr ' ' '\n' | grep -v '^$' | sort -n | uniq)

    # NR5G_NSA
    nr_nsa_enable=$(printf '%s' "$parsed"|jq -r '.nr_nsa.enabled[]')
    nr_nsa_disable=$(printf '%s' "$parsed"|jq -r '.nr_nsa.disabled[]')
    nr_nsa_all=$(echo "$nr_nsa_enable $nr_nsa_disable" | tr ' ' '\n' | grep -v '^$' | sort -n | uniq)

    # NR5G_SA
    nr_sa_enable=$(printf '%s' "$parsed"|jq -r '.nr_sa.enabled[]')
    nr_sa_disable=$(printf '%s' "$parsed"|jq -r '.nr_sa.disabled[]')
    nr_sa_all=$(echo "$nr_sa_enable $nr_sa_disable" | tr ' ' '\n' | grep -v '^$' | sort -n | uniq)

    # UMTS
    json_add_object "UMTS"
    json_add_array "available_band"
    for i in $wcdma_all; do
        echo "$i" | grep -Eq '^[0-9]+$' && add_avalible_band_entry "$i" "UMTS_$i"
    done
    json_close_array
    json_add_array "lock_band"
    for i in $wcdma_enable; do
        echo "$i" | grep -Eq '^[0-9]+$' && json_add_string "" "$i"
    done
    json_close_array
    json_close_object

    # LTE
    json_add_object "LTE"
    json_add_array "available_band"
    for i in $lte_all; do
        echo "$i" | grep -Eq '^[0-9]+$' && add_avalible_band_entry "$i" "LTE_B$i"
    done
    json_close_array
    json_add_array "lock_band"
    for i in $lte_enable; do
        echo "$i" | grep -Eq '^[0-9]+$' && json_add_string "" "$i"
    done
    json_close_array
    json_close_object

    # NR_NSA
    json_add_object "NR_NSA"
    json_add_array "available_band"
    for i in $nr_nsa_all; do
        echo "$i" | grep -Eq '^[0-9]+$' && add_avalible_band_entry "$i" "NR_NSA_N$i"
    done
    json_close_array
    json_add_array "lock_band"
    for i in $nr_nsa_enable; do
        echo "$i" | grep -Eq '^[0-9]+$' && json_add_string "" "$i"
    done
    json_close_array
    json_close_object

    # NR_SA
    json_add_object "NR_SA"
    json_add_array "available_band"
    for i in $nr_sa_all; do
        echo "$i" | grep -Eq '^[0-9]+$' && add_avalible_band_entry "$i" "NR_SA_N$i"
    done
    json_close_array
    json_add_array "lock_band"
    for i in $nr_sa_enable; do
        echo "$i" | grep -Eq '^[0-9]+$' && json_add_string "" "$i"
    done
    json_close_array
    json_close_object
}

set_lockband_nr(){
    #lock_band=$(echo $lock_band | tr ',' ':')
    case "$band_class" in
        "UMTS") 
        lock_band=$(echo $lock_band)
            local raw parsed; raw=$(cmd_band_pref_lock "$at_port" "$at_pre" WCDMA "$lock_band"); parsed=$(_foxconn_parse foxconn.band_pref.set "$raw"); res=$(printf '%s' "$parsed"|jq -r '.result//empty')
            ;;
        "LTE") 
            local raw parsed; raw=$(cmd_band_pref_lock "$at_port" "$at_pre" LTE "$lock_band"); parsed=$(_foxconn_parse foxconn.band_pref.set "$raw"); res=$(printf '%s' "$parsed"|jq -r '.result//empty')
            ;;
        "NR")
            local raw parsed; raw=$(cmd_band_pref_lock "$at_port" "$at_pre" NR5G "$lock_band"); parsed=$(_foxconn_parse foxconn.band_pref.set "$raw"); res=$(printf '%s' "$parsed"|jq -r '.result//empty')
            ;;
    esac
}

set_lockband()
{
    m_debug  "quectel set lockband info"
    config=$1
    #{"band_class":"NR","lock_band":"41,78,79"}
    band_class=$(echo $config | jq -r '.band_class')
    lock_band=$(echo $config | jq -r '.lock_band')
    case "$platform" in
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

_get_voltage(){
    local raw parsed; raw=$(cmd_pcvolt_query "$at_port"); parsed=$(_foxconn_parse foxconn.pcvolt "$raw"); voltage=$(printf '%s' "$parsed"|jq -r '.millivolts//empty')
    [ -n "$voltage" ] && {
        add_plain_info_entry "voltage" "$voltage mV" "Voltage" 
    }
}

_get_temperature(){
    local raw parsed; raw=$(cmd_temp_query "$at_port" "$at_pre"); parsed=$(_foxconn_parse foxconn.temp "$raw"); temperature=$(printf '%s' "$parsed"|jq -r '.celsius//empty')
    [ -n "$temperature" ] && {
        add_plain_info_entry "temperature" "$temperature C" "Temperature" 
    }
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

process_signal_value() {
    local value="$1"
    local numbers=$(echo "$value" | grep -oE '[-+]?[0-9]+(\.[0-9]+)?')
    local count=0
    local total=0

    for num in $numbers; do
        total=$(echo "$total + $num" | bc -l)
        count=$((count+1))
    done

    if [ $count -gt 0 ]; then
        echo "scale=2; $total / $count" | bc -l | sed 's/^\./0./' | sed 's/^-\./-0./'
    else
        echo ""
    fi
}

cell_info(){
    class="Cell Information"
    local raw parsed
    raw=$(cmd_debug_query "$at_port" "$at_pre"); parsed=$(_foxconn_parse foxconn.debug "$raw")
    network_mode=$(printf '%s' "$parsed"|jq -r '.network_mode//empty')
    #add_plain_info_entry "network_mode" "$network_mode" "Network Mode"

    case $network_mode in
    "LTE")
        lte_mcc=$(printf '%s' "$parsed"|jq -r '.mcc//empty'); lte_mnc=$(printf '%s' "$parsed"|jq -r '.mnc//empty')
        lte_earfcn=$(printf '%s' "$parsed"|jq -r '.earfcn//empty'); lte_physical_cell_id=$(printf '%s' "$parsed"|jq -r '.pci//empty')
        lte_cell_id=$(printf '%s' "$parsed"|jq -r '.cell_id//empty'); lte_band=$(printf '%s' "$parsed"|jq -r '.band//empty')
        lte_freq_band_ind=$(printf '%s' "$parsed"|jq -r '.band_width//empty'); lte_sinr=$(printf '%s' "$parsed"|jq -r '.sinr//empty')
        lte_rsrq=$(printf '%s' "$parsed"|jq -r '.rsrq//empty'); lte_rssi=$(printf '%s' "$parsed"|jq -r '.rssi//empty')
        lte_tac=$(printf '%s' "$parsed"|jq -r '.tac//empty'); lte_tx_power=$(printf '%s' "$parsed"|jq -r '.tx_power//empty')

        add_plain_info_entry "MCC" "$lte_mcc" "Mobile Country Code"
        add_plain_info_entry "MNC" "$lte_mnc" "Mobile Network Code"
        #add_plain_info_entry "Duplex Mode" "$lte_duplex_mode" "Duplex Mode"
        add_plain_info_entry "Cell ID" "$lte_cell_id" "Cell ID"
        add_plain_info_entry "Physical Cell ID" "$lte_physical_cell_id" "Physical Cell ID"
        add_plain_info_entry "EARFCN" "$lte_earfcn" "E-UTRA Absolute Radio Frequency Channel Number"
        add_plain_info_entry "Freq band indicator" "$lte_freq_band_ind" "Freq band indicator"
        add_plain_info_entry "Band" "$lte_band" "Band"
        #add_plain_info_entry "UL Bandwidth" "$lte_ul_bandwidth" "UL Bandwidth"
        #add_plain_info_entry "DL Bandwidth" "$lte_dl_bandwidth" "DL Bandwidth"
        add_plain_info_entry "TAC" "$lte_tac" "Tracking area code of cell served by neighbor Enb"
        add_bar_info_entry "RSRQ" "$lte_rsrq" "Reference Signal Received Quality" -19.5 -3 dB
        add_bar_info_entry "RSSI" "$lte_rssi" "Received Signal Strength Indicator" -120 -20 dBm
        add_bar_info_entry "SINR" "$lte_sinr" "Signal to Interference plus Noise Ratio Bandwidth" 0 30 dB
        #add_plain_info_entry "RxLev" "$lte_rxlev" "Received Signal Level"
        add_plain_info_entry "RSSNR" "$lte_rssnr" "Radio Signal Strength Noise Ratio"
        #add_plain_info_entry "CQI" "$lte_cql" "Channel Quality Indicator"
        add_plain_info_entry "TX Power" "$lte_tx_power" "TX Power"
        #add_plain_info_entry "Srxlev" "$lte_srxlev" "Serving Cell Receive Level"
        ;;
    "NR5G_SA")
        has_ca=$(printf '%s' "$parsed"|jq -r 'if .has_ca then 1 else 0 end')
        nr_display_mode="$network_mode"
        
        nr_mcc=$(printf '%s' "$parsed"|jq -r '.mcc//empty'); nr_mnc=$(printf '%s' "$parsed"|jq -r '.mnc//empty')
        nr_earfcn=$(printf '%s' "$parsed"|jq -r '.earfcn//empty'); nr_physical_cell_id=$(printf '%s' "$parsed"|jq -r '.pci//empty')
        nr_cell_id=$(printf '%s' "$parsed"|jq -r '.cell_id//empty'); nr_band=$(printf '%s' "$parsed"|jq -r '.band//empty')
        nr_band_width=$(printf '%s' "$parsed"|jq -r '.band_width//empty'); nr_freq_band_ind=$(printf '%s' "$parsed"|jq -r '.freq_band_ind//empty')
        nr_sinr=$(printf '%s' "$parsed"|jq -r '.sinr//empty'); nr_rsrq=$(printf '%s' "$parsed"|jq -r '.rsrq//empty')
        nr_rsrp=$(printf '%s' "$parsed"|jq -r '.rsrp//empty'); nr_rssi=$(printf '%s' "$parsed"|jq -r '.rssi//empty')
        nr_tac=$(printf '%s' "$parsed"|jq -r '.tac//empty'); nr_tx_power=$(printf '%s' "$parsed"|jq -r '.tx_power//empty')

        if [ "$has_ca" -gt 0 ]; then
            nr_display_mode="NR5G_SA-CA"

            scc1_band=$(printf '%s' "$parsed"|jq -r '.scc1_band//empty')
            scc1_band_width=$(printf '%s' "$parsed"|jq -r '.scc1_band_width//empty')

            nr_band="$nr_band $scc1_band"
            nr_band_width="$nr_band_width $scc1_band_width"
        fi

        add_plain_info_entry "Network Mode" "$nr_display_mode" "Network Mode"
        add_plain_info_entry "Band" "$nr_band" "Band"
        add_plain_info_entry "DL Bandwidth" "$nr_band_width" "DL Bandwidth"
        add_plain_info_entry "MCC" "$nr_mcc" "Mobile Country Code"
        add_plain_info_entry "MNC" "$nr_mnc" "Mobile Network Code"
        #add_plain_info_entry "Duplex Mode" "$lte_duplex_mode" "Duplex Mode"
        add_plain_info_entry "Cell ID" "$nr_cell_id" "Cell ID"
        add_plain_info_entry "Physical Cell ID" "$nr_physical_cell_id" "Physical Cell ID"
        add_plain_info_entry "EARFCN" "$nr_earfcn" "E-UTRA Absolute Radio Frequency Channel Number"
        add_plain_info_entry "Freq band indicator" "$nr_freq_band_ind" "Freq band indicator"
        add_plain_info_entry "TAC" "$nr_tac" "Tracking area code of cell served by neighbor Enb"
        add_bar_info_entry "RSRQ" "$nr_rsrq" "Reference Signal Received Quality" -19.5 -3 dB
        add_bar_info_entry "RSRP" "$nr_rsrp" "Reference Signal Received Power" -140 -44 dBm
        add_bar_info_entry "SINR" "$nr_sinr" "Signal to Interference plus Noise Ratio Bandwidth" 0 30 dB
        add_plain_info_entry "TX Power" "$nr_tx_power" "TX Power"
        ;;
    esac
}
