#!/bin/sh
qmodem_parser_dispatch(){
 case "$1" in
  sierra.cgsn|sierra.usbcomp|sierra.selrat|sierra.uims|sierra.cpin|sierra.cgmm|sierra.cgmi|sierra.ati|sierra.gstatus|sierra.band.config|sierra.band.list|sierra.pcvolt|sierra.pctemp) . "$base_dir/sierra/response.sh"; qmodem_sierra_parse "$1";;
  sierra.entercnd|sierra.egmr.set|sierra.usbcomp.set|sierra.selrat.set|sierra.band.set|sierra.band.reset) . "$base_dir/sierra/response.sh"; qmodem_sierra_completion "$1";;
  *) qmodem_parser_error "$1" unknown_parser; return 2;;
 esac
}
