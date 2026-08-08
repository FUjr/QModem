#!/bin/sh

parser_quectel_cgsn()
{
    local imei
    imei=$(awk '
        {
            line=$0
            while (match(line, /[0-9]{15}/)) {
                print substr(line, RSTART, 15)
                exit
            }
        }
    ')
    [ -n "$imei" ] || {
        qmodem_parser_error "quectel.cgsn" "parse_failed"
        return 1
    }
    qmodem_parser_string "imei" "$imei"
}
