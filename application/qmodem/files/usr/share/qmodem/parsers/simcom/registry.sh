#!/bin/sh

qmodem_parser_dispatch()
{
    . "$base_dir/simcom/fields.sh"
    case "$1" in
        simcom.command.completion) qmodem_parser_completion "$1" ;;
        simcom.cgsn) parser_simcom_cgsn ;;
        simcom.cusbcfg.usbid) parser_simcom_prefixed "$1" 'USBID: 0X1E0E,0X' mode_num ;;
        simcom.cpciemode) parser_simcom_prefixed "$1" '+CPCIEMODE:' pcie_mode ;;
        simcom.myconfig) parser_simcom_myconfig ;;
        simcom.cnmp) parser_simcom_cnmp ;;
        simcom.cbc.voltage) parser_simcom_prefixed "$1" '+CBC:' voltage ;;
        simcom.cpmutemp) parser_simcom_prefixed "$1" '+CPMUTEMP:' temperature ;;
        simcom.cgmm) parser_simcom_line2 "$1" name ;;
        simcom.cgmi) parser_simcom_line2 "$1" manufacturer ;;
        simcom.ati.revision) parser_simcom_prefixed "$1" 'Revision:' revision ;;
        simcom.smsimcfg.slot) parser_simcom_csv "$1" '+SMSIMCFG:' sim_slot 2 ;;
        simcom.cpin.status) parser_simcom_line2 "$1" status_text ;;
        simcom.cops.operator) parser_simcom_quoted "$1" '+COPS:' operator 2 ;;
        simcom.cops.rat) parser_simcom_csv "$1" '+COPS:' rat_code 4 ;;
        simcom.cnum) parser_simcom_quoted "$1" '+CNUM:' number 4 ;;
        simcom.cimi) parser_simcom_line2 "$1" imsi ;;
        simcom.iccid) parser_simcom_iccid ;;
        simcom.cpsi.type) parser_simcom_csv "$1" '+CPSI:' network_type 1 ;;
        simcom.cpsi) parser_simcom_cpsi ;;
        simcom.cnwinfo) parser_simcom_cnwinfo ;;
        simcom.csyssel) parser_simcom_csyssel ;;
        simcom.cnbp) parser_simcom_cnbp ;;
        simcom.ccellcfg) parser_simcom_ccellcfg ;;
        simcom.c5gcellcfg) parser_simcom_c5gcellcfg ;;
        simcom.cnwsearch) parser_simcom_cnwsearch ;;
        *) qmodem_parser_error "$1" unknown_parser; return 2 ;;
    esac
}
