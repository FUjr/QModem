#!/bin/sh
qmodem_parser_dispatch(){
 case "$1" in
  gosuncn.cgsn|gosuncn.zswitch|gosuncn.zsnt|gosuncn.mtsm|gosuncn.zband|gosuncn.zband.list|gosuncn.cpin|gosuncn.cops|gosuncn.cnum|gosuncn.cimi|gosuncn.iccid|gosuncn.cgmm|gosuncn.cgmi|gosuncn.cgmr|gosuncn.csq|gosuncn.cesq|gosuncn.zcellinfo) . "$base_dir/gosuncn/response.sh"; qmodem_gosuncn_parse "$1";;
  gosuncn.egmr.set|gosuncn.zswitch.set|gosuncn.zsnt.set|gosuncn.zband.set|gosuncn.zband.reset|gosuncn.cops.numeric|gosuncn.cfun|gosuncn.atf) qmodem_parser_completion "$1";;
  *) qmodem_parser_error "$1" unknown_parser; return 2;;
 esac
}
