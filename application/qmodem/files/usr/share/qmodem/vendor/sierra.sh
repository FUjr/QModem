#!/bin/sh
# Copyright (C) 2025 Fujr <fjrcn@outlook.com>
_Vendor="sierra"
_Author="Fujr"
_Maintainer="Fujr <fjrcn@outlook.com>"
source "${QMODEM_HOME:-/usr/share/qmodem}/generic.sh"
debug_subject="quectel_ctrl"
_sierra_parse(){ local id="$1" raw="$2" context="$3"; [ -n "$context" ]||context='{}'; printf '%s' "$raw"|"${QMODEM_HOME:-/usr/share/qmodem}/parsers/parse.sh" "$id" --platform "${platform:-unknown}" --model "${model:-unknown}" --context-json "$context"; }
unlock_advance(){
    [ -z "$sierra_pass" ] && sierra_pass="A710"
    local raw; raw=$(cmd_entercnd "$at_port" "$sierra_pass"); _sierra_parse sierra.entercnd "$raw" >/dev/null
}

get_imei(){
    local raw parsed; raw=$(cmd_cgsn "$at_port"); parsed=$(_sierra_parse sierra.cgsn "$raw"); imei=$(printf '%s' "$parsed"|jq -r '.imei//empty')
    json_add_string imei $imei
}

set_imei(){
    imei=$1
    local raw parsed; raw=$(cmd_egmr_set_imei "$at_port" "$imei"); parsed=$(_sierra_parse sierra.egmr.set "$raw"); printf '%s' "$parsed"|jq -r '.result//empty'
}

get_mode(){
    local raw parsed; raw=$(cmd_usbcomp_query "$at_port"); parsed=$(_sierra_parse sierra.usbcomp "$raw")
    config_type=$(printf '%s' "$parsed"|jq -r '.config_type//empty'); interface_mask=$(printf '%s' "$parsed"|jq -r '.interface_mask//empty')
    _mask_to_mode $interface_mask
    if [ "$mbim_port" = "1" ]; then
        mode="mbim"
    elif [ "$rmnet_port" = "1" ]; then
        mode="rmnet"
    fi
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
    case $mode in
        "mbim")
            interface_mask=0x00001009
            ;;
        "rmnet")
            interface_mask=0x00000109
            ;;
        *)
            echo "Invalid mode"
            return 1
            ;;
    esac
    local raw parsed; raw=$(cmd_usbcomp_set "$at_port" "$interface_mask"); parsed=$(_sierra_parse sierra.usbcomp.set "$raw"); printf '%s' "$parsed"|jq -r '.result//empty'
}

get_network_prefer(){
    local raw parsed; raw=$(cmd_selrat_query "$at_port"); parsed=$(_sierra_parse sierra.selrat "$raw")
# (RAT index): 
# • 00 – Automatic 
# • 01 – UMTS 3G only 
# • 04 – LTE only 
# • 05 – 5G only 
# • 0E – UMTS and LTE only 
# • 0F – LTE and NR5G only 
# • 10 – WCDMA and NR5G only 
   code=$(printf '%s' "$parsed"|jq -r '.code//empty')
    local network_prefer_3g="0"
    local network_prefer_4g="0"
    local network_prefer_5g="0"
   case $code in
        "00")
            network_prefer_3g="1"
            network_prefer_4g="1"
            network_prefer_5g="1"
            ;;
        "01")
            network_prefer_3g="1"
            ;;
        "06")
            network_prefer_4g="1"
            ;;
        "20")
            network_prefer_5g="1"
            ;;
        "11")
            network_prefer_3g="1"
            network_prefer_4g="1"
            ;;
        "21")
            network_prefer_4g="1"
            network_prefer_5g="1"
            ;;
        "22")
            network_prefer_3g="1"
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
                code="01"
            elif [ "$network_prefer_4g" = "true" ]; then
                code="06"
            elif [ "$network_prefer_5g" = "true" ]; then
                code="20"
            fi
            ;;
        "2")
            if [ "$network_prefer_3g" = "true" ] && [ "$network_prefer_4g" = "true" ]; then
                code="11"
            elif [ "$network_prefer_4g" = "true" ] && [ "$network_prefer_5g" = "true" ]; then
                code="21"
            elif [ "$network_prefer_3g" = "true" ] && [ "$network_prefer_5g" = "true" ]; then
                code="22"
            fi
            ;;
        "3")
            code="00"
            ;;
        *)
            code="00"
            ;;
    esac
    local raw parsed; raw=$(cmd_selrat_set "$at_port" "$code"); parsed=$(_sierra_parse sierra.selrat.set "$raw"); res=$(printf '%s' "$parsed"|jq -r '.result//empty')
    json_add_string "code" "$code"
    json_add_string "result" "$res"
}

get_lockband(){
    json_add_object "lockband"
    case $platform in
        "qualcomm")
            _get_lockband_nr
            ;;
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
        "qualcomm")
            _set_lockband_nr
            ;;
        *)
            _set_lockband_nr
            ;;
    esac
}

sim_info()
{
    class="SIM Information"
    
	local raw parsed; raw=$(cmd_uims_query "$at_port"); parsed=$(_sierra_parse sierra.uims "$raw"); slot=$(printf '%s' "$parsed"|jq -r '.slot_index//empty')
    sim_slot=$(($slot+1))

    #SIM Status（SIM状态）
	raw=$(cmd_cpin_query "$at_port"); parsed=$(_sierra_parse sierra.cpin "$raw"); sim_status=$(printf '%s' "$parsed"|jq -r '.status//empty')
    add_plain_info_entry "SIM Status" "$sim_status" "SIM Status" 
    add_plain_info_entry "SIM Slot" "$sim_slot" "SIM Slot"
}

base_info(){
        #Name（名称）
    local raw parsed; raw=$(cmd_cgmm "$at_port"); parsed=$(_sierra_parse sierra.cgmm "$raw"); name=$(printf '%s' "$parsed"|jq -r '.name//empty')
    #Manufacturer（制造商）
    raw=$(cmd_cgmi "$at_port"); parsed=$(_sierra_parse sierra.cgmi "$raw"); manufacturer=$(printf '%s' "$parsed"|jq -r '.manufacturer//empty')
    #Revision（固件版本）
    raw=$(cmd_ati "$at_port"); parsed=$(_sierra_parse sierra.ati "$raw"); revision=$(printf '%s' "$parsed"|jq -r '.revision//empty')
    # at_command="AT+CGMR"
    # revision=$(cmd_ati "$at_port" | sed -n '2p' | sed 's/\r//g')
    class="Base Information"
    add_plain_info_entry "name" "$name" "Name"
    add_plain_info_entry "manufacturer" "$manufacturer" "Manufacturer"
    add_plain_info_entry "revision" "$revision" "Revision"
    add_plain_info_entry "at_port" "$at_port" "AT Port"
    get_connect_status
    _get_temperature
    _get_voltage
}

network_info(){
    class="Network Information"
    local raw parsed; raw=$(cmd_gstatus_query "$at_port"); parsed=$(_sierra_parse sierra.gstatus "$raw")
    _render_gstatus "$parsed"
}

vendor_get_disabled_features(){
    json_add_string "" "IMEI"
    json_add_string "" "NeighborCell"
}

_get_lockband_nr(){
    local raw parsed list config type_count type_index band_count band_index type band_id band_name low high
    raw=$(cmd_band_query "$at_port"); config=$(_sierra_parse sierra.band.config "$raw")
    raw=$(cmd_band_list_query "$at_port"); list=$(_sierra_parse sierra.band.list "$raw")
    type_count=$(printf '%s' "$list"|jq '.types|length'); type_index=0
    while [ "$type_index" -lt "$type_count" ]; do
        type=$(printf '%s' "$list"|jq -r ".types[$type_index].type")
        json_add_object "$type"; json_add_array "available_band"
        band_count=$(printf '%s' "$list"|jq ".types[$type_index].bands|length"); band_index=0
        while [ "$band_index" -lt "$band_count" ]; do
            band_id=$(printf '%s' "$list"|jq -r ".types[$type_index].bands[$band_index].id")
            band_name=$(printf '%s' "$list"|jq -r ".types[$type_index].bands[$band_index].name")
            add_avalible_band_entry "$band_id" "${type}_${band_name}"
            band_index=$((band_index+1))
        done
        json_close_array; json_add_array "lock_band"; json_close_array; json_close_object
        type_index=$((type_index+1))
    done
    type_count=$(printf '%s' "$config"|jq '.configurations|length'); type_index=0
    while [ "$type_index" -lt "$type_count" ]; do
        type=$(printf '%s' "$config"|jq -r ".configurations[$type_index].type")
        low=$(printf '%s' "$config"|jq -r ".configurations[$type_index].low_mask")
        high=$(printf '%s' "$config"|jq -r ".configurations[$type_index].high_mask")
        json_select "$type"; json_select "lock_band"; _mask_to_band _add_lock_band "$low" "$high"; json_select ".."; json_select ".."
        type_index=$((type_index+1))
    done
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
    raw=$(cmd_band_set_custom "$at_port" "$band_class" "$bandlist"); parsed=$(_sierra_parse sierra.band.set "$raw"); res=$(printf '%s' "$parsed"|jq -r '.result//empty'|xargs)
    if [ "$res" == "OK" ]; then
        raw=$(cmd_band_reset "$at_port" "0F"); _sierra_parse sierra.band.reset "$raw" >/dev/null
    else
        raw=$(cmd_band_reset "$at_port" "00"); _sierra_parse sierra.band.reset "$raw" >/dev/null
    fi
    json_add_string "result" "$res"
    json_add_string "cmd" "$cmd"
}

_get_voltage(){
    local raw parsed; raw=$(cmd_pcvolt_query "$at_port"); parsed=$(_sierra_parse sierra.pcvolt "$raw"); voltage=$(printf '%s' "$parsed"|jq -r '.millivolts//empty')
    [ -n "$voltage" ] && {
        add_plain_info_entry "voltage" "$voltage mV" "Voltage" 
    }
}

_get_temperature(){
    local raw parsed; raw=$(cmd_pctemp_query "$at_port"); parsed=$(_sierra_parse sierra.pctemp "$raw"); temperature=$(printf '%s' "$parsed"|jq -r '.celsius//empty')
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

_mask_to_mode()
{
    mask=$1
# RmNet – 0x00000100 bin: 000100000000
# MBIM – 0x00001000 bin: 0001000000000000
    hex_to_bin=$(echo "obase=2; ibase=16; $mask" | bc)
    #paddding to 16 bits
    hex_to_bin=$(printf "%016d" $hex_to_bin)
    adb_port=${hex_to_bin: -1}
    diag_port=${hex_to_bin: -2:1}
    modem_port=${hex_to_bin: -4:1}
    rmnet_port=${hex_to_bin: -9:1}
    mbim_port=${hex_to_bin: -13:1}
}

_render_gstatus(){
    local parsed="$1" count i key value kind
    count=$(printf '%s' "$parsed"|jq '.entries|length')
    i=0
    while [ "$i" -lt "$count" ]; do
        key=$(printf '%s' "$parsed"|jq -r ".entries[$i].key")
        value=$(printf '%s' "$parsed"|jq -r ".entries[$i].value")
        kind=$(printf '%s' "$parsed"|jq -r ".entries[$i].kind")
        case "$kind" in
            sinr) add_bar_info_entry "SINR" "$value" "$key" 0 30 dB ;;
            rsrp) add_bar_info_entry "RSRP" "$value" "$key" -140 -44 dBm ;;
            rsrq) add_bar_info_entry "RSRQ" "$value" "$key" -19.5 -3 dB ;;
            rssi) add_bar_info_entry "RSSI" "$value" "$key" -120 -20 dBm ;;
            *) add_plain_info_entry "$key" "$value" "$key" ;;
        esac
        i=$((i+1))
    done
}



unlock_advance
