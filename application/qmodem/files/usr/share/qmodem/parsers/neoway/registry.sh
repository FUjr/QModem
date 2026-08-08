#!/bin/sh
qmodem_parser_dispatch() {
 case "$1" in
  neoway.cgsn|neoway.mysysinfo|neoway.cgmm|neoway.cgmi|neoway.ati|neoway.simcross|neoway.cpin|neoway.cops|neoway.cnum|neoway.cimi|neoway.myccid|neoway.csq|neoway.c5gqosrdp|neoway.nwsetband|neoway.nwsetband.list|neoway.netdmsgex) . "$base_dir/neoway/response.sh"; qmodem_neoway_parse "$1" ;;
  neoway.spimei.set|neoway.mysysinfo.set|neoway.nwsetband.set|neoway.nwsetband.reset) qmodem_parser_completion "$1" ;;
  *) qmodem_parser_error "$1" unknown_parser; return 2;;
 esac
}
