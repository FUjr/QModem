#!/bin/sh

qmodem_parser_dispatch()
{
    local parser_id="$1"
    case "$parser_id" in
        meig.cgsn|meig.ser|meig.syscfgex|meig.temp|meig.cgmm|meig.cgmi|meig.cgmr|meig.simslot|meig.cpin|meig.cops|meig.cnum|meig.cimi|meig.iccid|meig.sysinfoex|meig.csq|meig.dsambr|meig.dsflowqry|meig.cellinfo)
            . "$base_dir/meig/response.sh"; qmodem_meig_parse "$parser_id" ;;
        meig.lctsn.set|meig.ser.set|meig.syscfgex.set)
            qmodem_parser_completion "$parser_id" ;;
        *) qmodem_parser_error "$parser_id" unknown_parser; return 2 ;;
    esac
}
