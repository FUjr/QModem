#!/bin/sh

qmodem_parser_dispatch()
{
    case "$1" in
        quectel.cgsn)
            . "$base_dir/quectel/cgsn.sh"
            parser_quectel_cgsn "$2" "$3" "$4"
            ;;
        quectel.cops.operator)
            . "$base_dir/quectel/cops.sh"
            parser_quectel_cops_operator "$2" "$3" "$4"
            ;;
        quectel.cops.rat)
            . "$base_dir/quectel/cops.sh"
            parser_quectel_cops_rat "$2" "$3" "$4"
            ;;
        quectel.command.completion)
            qmodem_parser_completion "$1"
            ;;
        quectel.qcfg.value) . "$base_dir/quectel/basic.sh"; parser_quectel_qcfg_value "$2" "$3" "$4" ;;
        quectel.qcfg.5glan) . "$base_dir/quectel/basic.sh"; parser_quectel_5glan "$2" "$3" "$4" ;;
        quectel.qnwprefcfg.value) . "$base_dir/quectel/basic.sh"; parser_quectel_qnwprefcfg_value "$2" "$3" "$4" ;;
        quectel.line) . "$base_dir/quectel/basic.sh"; parser_quectel_line "$2" "$3" "$4" ;;
        quectel.second_line) . "$base_dir/quectel/basic.sh"; parser_quectel_second_line "$2" "$3" "$4" ;;
        quectel.cpin) . "$base_dir/quectel/basic.sh"; parser_quectel_cpin "$2" "$3" "$4" ;;
        quectel.cnum) . "$base_dir/quectel/basic.sh"; parser_quectel_cnum "$2" "$3" "$4" ;;
        quectel.iccid) . "$base_dir/quectel/basic.sh"; parser_quectel_iccid "$2" "$3" "$4" ;;
        quectel.csq) . "$base_dir/quectel/basic.sh"; parser_quectel_csq "$2" "$3" "$4" ;;
        quectel.qnwinfo) . "$base_dir/quectel/basic.sh"; parser_quectel_qnwinfo "$2" "$3" "$4" ;;
        quectel.qtemp) . "$base_dir/quectel/basic.sh"; parser_quectel_qtemp "$2" "$3" "$4" ;;
        quectel.cbc) . "$base_dir/quectel/basic.sh"; parser_quectel_cbc "$2" "$3" "$4" ;;
        quectel.sim_slot) . "$base_dir/quectel/basic.sh"; parser_quectel_sim_slot "$2" "$3" "$4" ;;
        quectel.qnwcfg) . "$base_dir/quectel/basic.sh"; parser_quectel_qnwcfg "$2" "$3" "$4" ;;
        quectel.qeng) . "$base_dir/quectel/radio.sh"; parser_quectel_qeng "$2" "$3" "$4" ;;
        quectel.qeng.neighbors) . "$base_dir/quectel/radio.sh"; parser_quectel_qeng_neighbors "$2" "$3" "$4" ;;
        quectel.qcainfo) . "$base_dir/quectel/radio.sh"; parser_quectel_qcainfo "$2" "$3" "$4" ;;
        quectel.qnwlock) . "$base_dir/quectel/radio.sh"; parser_quectel_qnwlock "$2" "$3" "$4" ;;
        quectel.band.value) . "$base_dir/quectel/radio.sh"; parser_quectel_band_value "$2" "$3" "$4" ;;
        quectel.usage) . "$base_dir/quectel/radio.sh"; parser_quectel_usage "$2" "$3" "$4" ;;
        quectel.sim_slots) . "$base_dir/quectel/radio.sh"; parser_quectel_sim_slots "$2" "$3" "$4" ;;
        *)
            qmodem_parser_error "$1" "unknown_parser"
            return 2
            ;;
    esac
}
