#!/bin/sh

qmodem_parser_dispatch()
{
    . "$base_dir/fibocom/fields.sh"
    case "$1" in
        fibocom.command.completion) qmodem_parser_completion "$1" ;;
        fibocom.gtusbmode) parser_fibocom_prefixed "$1" '+GTUSBMODE:' mode_num ;;
        fibocom.gtact.current|fibocom.gtact.available) parser_fibocom_gtact "$1" ;;
        fibocom.cbc.voltage) parser_fibocom_csv "$1" '+CBC:' voltage 2 ;;
        fibocom.mtsm.temperature|fibocom.mtsm16.temperature) parser_fibocom_temperature "$1" mtsm ;;
        fibocom.gtladc.temperature) parser_fibocom_temperature "$1" gtladc ;;
        fibocom.gtsenrdtemp.temperature) parser_fibocom_temperature "$1" gtsenrdtemp ;;
        fibocom.cgmm) parser_fibocom_quoted "$1" '+CGMM:' name ;;
        fibocom.cgmi) parser_fibocom_quoted "$1" '+CGMI:' manufacturer ;;
        fibocom.cgmr) parser_fibocom_quoted "$1" '+CGMR:' revision ;;
        fibocom.gtdualsim.slot) parser_fibocom_gtdualsim ;;
        fibocom.gtdualsim.status) parser_fibocom_gtdualsim_status ;;
        fibocom.cgsn) parser_fibocom_cgsn ;;
        fibocom.cpin.status) parser_fibocom_cpin ;;
        fibocom.cops.operator) parser_fibocom_quoted "$1" '+COPS' operator ;;
        fibocom.cops.rat) parser_fibocom_csv "$1" '+COPS:' rat_code 4 ;;
        fibocom.cnum.primary) parser_fibocom_quoted "$1" '+CNUM:' number 2 ;;
        fibocom.cnum.secondary) parser_fibocom_quoted "$1" '+CNUM:' number 4 ;;
        fibocom.cimi) parser_fibocom_prefixed "$1" '+CIMI:' imsi ;;
        fibocom.iccid) parser_fibocom_iccid ;;
        fibocom.ccid) parser_fibocom_prefixed "$1" '+CCID:' iccid ;;
        fibocom.psrat) parser_fibocom_prefixed "$1" '+PSRAT:' network_type ;;
        fibocom.gtstatis.rates) parser_fibocom_gtstatis ;;
        fibocom.gtccinfo) parser_fibocom_gtccinfo_semantic ;;
        fibocom.gtcainfo) parser_fibocom_gtcainfo_semantic ;;
        fibocom.gtcelllock.status) parser_fibocom_prefixed "$1" '+GTCELLLOCK:' status ;;
        fibocom.csq) parser_fibocom_prefixed "$1" '+CSQ:' csq ;;
        fibocom.gtusagerec) parser_fibocom_usage ;;
        *) qmodem_parser_error "$1" unknown_parser; return 2 ;;
    esac
}
