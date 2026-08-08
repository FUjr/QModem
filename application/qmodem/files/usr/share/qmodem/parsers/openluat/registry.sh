#!/bin/sh

qmodem_parser_dispatch()
{
    case "$1" in
        openluat.cesq)
            . "$base_dir/openluat/cesq.sh"
            parser_openluat_cesq "$2" "$3" "$4"
            ;;
        openluat.identity)
            . "$base_dir/openluat/basic.sh"
            parser_openluat_identity "$2" "$3" "$4"
            ;;
        openluat.cgsn) . "$base_dir/openluat/basic.sh"; parser_openluat_number "$1" imei 15 20 ;;
        openluat.cimi) . "$base_dir/openluat/basic.sh"; parser_openluat_number "$1" imsi 15 15 ;;
        openluat.iccid) . "$base_dir/openluat/basic.sh"; parser_openluat_number "$1" iccid 18 20 ;;
        openluat.cbc) . "$base_dir/openluat/basic.sh"; parser_openluat_cbc "$2" "$3" "$4" ;;
        openluat.cops) . "$base_dir/openluat/basic.sh"; parser_openluat_cops "$2" "$3" "$4" ;;
        openluat.cnum) . "$base_dir/openluat/basic.sh"; parser_openluat_cnum "$2" "$3" "$4" ;;
        openluat.cpin) . "$base_dir/openluat/basic.sh"; parser_openluat_cpin "$2" "$3" "$4" ;;
        openluat.csq) . "$base_dir/openluat/basic.sh"; parser_openluat_csq "$2" "$3" "$4" ;;
        openluat.ctec) . "$base_dir/openluat/basic.sh"; parser_openluat_ctec "$2" "$3" "$4" ;;
        openluat.setusb) . "$base_dir/openluat/basic.sh"; parser_openluat_setusb "$2" "$3" "$4" ;;
        openluat.band) . "$base_dir/openluat/basic.sh"; parser_openluat_band "$2" "$3" "$4" ;;
        openluat.cgcontrdp) . "$base_dir/openluat/basic.sh"; parser_openluat_cgcontrdp "$2" "$3" "$4" ;;
        openluat.cced.serving) . "$base_dir/openluat/cell.sh"; parser_openluat_cced_serving "$2" "$3" "$4" ;;
        openluat.cced.neighbors) . "$base_dir/openluat/cell.sh"; parser_openluat_cced_neighbors "$2" "$3" "$4" ;;
        openluat.eem.lte) . "$base_dir/openluat/cell.sh"; parser_openluat_eem_lte "$2" "$3" "$4" ;;
        openluat.command.completion)
            qmodem_parser_completion "$1"
            ;;
        *)
            qmodem_parser_error "$1" "unknown_parser"
            return 2
            ;;
    esac
}
