#!/bin/sh

qmodem_parser_dispatch()
{
    . "$base_dir/telit/fields.sh"
    case "$1" in
        telit.command.completion) telit_parse_completion ;;
        telit.usbcfg) telit_parse_usbcfg ;;
        telit.ws46) telit_parse_ws46 ;;
        telit.cbc) telit_parse_csv "$1" '#CBC:' millivolts 2 ;;
        telit.tempsens) telit_parse_csv "$1" '#TEMPSENS: TSENS,' temperature 2 ;;
        telit.cgmm) telit_parse_body "$1" name ;;
        telit.cgmi) telit_parse_body "$1" manufacturer ;;
        telit.cgmr) telit_parse_body "$1" revision ;;
        telit.qss) telit_parse_qss ;;
        telit.cgsn) telit_parse_body "$1" imei ;;
        telit.cpin) telit_parse_body "$1" status_text ;;
        telit.cops) telit_parse_cops ;;
        telit.cimi) telit_parse_body "$1" imsi ;;
        telit.iccid) telit_parse_iccid ;;
        telit.cametrics) telit_parse_csv "$1" '#CAMETRICS:' network_type 3 ;;
        telit.cqi) telit_parse_cqi ;;
        telit.bnd.config) telit_parse_bnd config ;;
        telit.bnd.available) telit_parse_bnd available ;;
        telit.cainfoext) telit_parse_cainfoext ;;
        *) qmodem_parser_error "$1" unknown_parser; return 2 ;;
    esac
}
