#!/bin/sh

qmodem_parser_dispatch()
{
    local parser_id="$1"
    case "$parser_id" in
        huawei.cgsn|huawei.setmode|huawei.syscfgex|huawei.cpin|huawei.cnum|huawei.cimi|huawei.cgmm|huawei.cgmi|huawei.ati|huawei.monsc|huawei.cserssi|huawei.hfreqinfo|huawei.band.config|huawei.band.list|huawei.chiptemp)
            . "$base_dir/huawei/response.sh"
            qmodem_huawei_parse "$parser_id"
            ;;
        huawei.phynum.set|huawei.setmode.set|huawei.syscfgex.set|huawei.band.set|huawei.band.reset|huawei.simswitch.set|huawei.scichg.set)
            qmodem_parser_completion "$parser_id"
            ;;
        *) qmodem_parser_error "$parser_id" "unknown_parser"; return 2 ;;
    esac
}
