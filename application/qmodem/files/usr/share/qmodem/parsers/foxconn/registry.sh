#!/bin/sh
qmodem_parser_dispatch(){
 case "$1" in
  foxconn.ati|foxconn.pciemode|foxconn.usbswitch|foxconn.slmode|foxconn.switch_slot|foxconn.cpin|foxconn.cops|foxconn.cnum|foxconn.cimi|foxconn.iccid|foxconn.band_pref|foxconn.pcvolt|foxconn.temp|foxconn.debug) . "$base_dir/foxconn/response.sh"; qmodem_foxconn_parse "$1";;
  foxconn.nv.clear|foxconn.nv.set|foxconn.usbswitch.set|foxconn.slmode.set|foxconn.band_pref.set) . "$base_dir/foxconn/response.sh"; qmodem_foxconn_completion "$1";;
  *) qmodem_parser_error "$1" unknown_parser; return 2;;
 esac
}
