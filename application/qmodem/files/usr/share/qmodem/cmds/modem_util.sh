#!/bin/sh
# AT commands used by modem_util.sh before a vendor implementation is loaded.

cmd_util_quimslot_query() { at "$1" 'AT+QUIMSLOT?' 3; }
cmd_util_gtdualsim_query() { at "$1" 'AT+GTDUALSIM?' 3; }
cmd_util_smsimcfg_query() { at "$1" 'AT+SMSIMCFG?' 3; }
cmd_util_simslot_query() { at "$1" 'AT^SIMSLOT?' 3; }
cmd_util_simcross_query() { at "$1" 'AT+SIMCROSS?' 3; }
cmd_util_qss_query() { at "$1" 'AT#QSS?' 3; }
cmd_util_qsimdet_query() { at "$1" 'AT+QSIMDET?' 3; }
