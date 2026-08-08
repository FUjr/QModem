#!/bin/sh

qmodem_parser_dispatch()
{
    case "$1" in
        core.gtdns) . "$base_dir/core/fields.sh"; parser_core_gtdns ;;
        core.cgact.active_contexts) . "$base_dir/core/fields.sh"; parser_core_cgact ;;
        core.cgpaddr.addresses) . "$base_dir/core/fields.sh"; parser_core_cgpaddr ;;
        core.cpms) . "$base_dir/core/fields.sh"; parser_core_cpms ;;
        core.cpin) . "$base_dir/core/fields.sh"; parser_core_cpin ;;
        core.simslot) . "$base_dir/core/fields.sh"; parser_core_simslot "$4" ;;
        core.error-status) . "$base_dir/core/fields.sh"; parser_core_error_status ;;
        core.cops.numeric) . "$base_dir/core/fields.sh"; parser_core_cops_numeric ;;
        core.cnmp) . "$base_dir/core/fields.sh"; parser_core_cnmp ;;
        core.setautodial) . "$base_dir/core/fields.sh"; parser_core_setautodial ;;
        core.quectel.ethernet) . "$base_dir/core/fields.sh"; parser_core_quectel_ethernet "$4" ;;
        core.command.completion)
            qmodem_parser_completion "$1"
            ;;
        *)
            qmodem_parser_error "$1" "unknown_parser"
            return 2
            ;;
    esac
}
