#!/bin/sh

parser_id=${1:-}
[ -n "$parser_id" ] || {
    printf '%s\n' '{"error":{"code":"invalid_arguments","parser":""}}'
    exit 2
}
shift

platform=
model=
context_json=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --platform)
            [ "$#" -ge 2 ] || break
            platform=$2
            shift 2
            ;;
        --model)
            [ "$#" -ge 2 ] || break
            model=$2
            shift 2
            ;;
        --context-json)
            [ "$#" -ge 2 ] || break
            context_json=$2
            shift 2
            ;;
        *)
            break
            ;;
    esac
done

base_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "$base_dir/lib/common.sh"

if [ "$#" -ne 0 ] || [ -z "$platform" ] || [ -z "$model" ] || \
   [ -z "$context_json" ] || ! printf '%s' "$context_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    qmodem_parser_error "$parser_id" "invalid_arguments"
    exit 2
fi

case "$parser_id" in
    quectel.*) registry="$base_dir/quectel/registry.sh" ;;
    openluat.*) registry="$base_dir/openluat/registry.sh" ;;
    fibocom.*) registry="$base_dir/fibocom/registry.sh" ;;
    simcom.*) registry="$base_dir/simcom/registry.sh" ;;
    huawei.*) registry="$base_dir/huawei/registry.sh" ;;
    meig.*) registry="$base_dir/meig/registry.sh" ;;
    neoway.*) registry="$base_dir/neoway/registry.sh" ;;
    gosuncn.*) registry="$base_dir/gosuncn/registry.sh" ;;
    foxconn.*) registry="$base_dir/foxconn/registry.sh" ;;
    sierra.*) registry="$base_dir/sierra/registry.sh" ;;
    telit.*) registry="$base_dir/telit/registry.sh" ;;
    core.*) registry="$base_dir/core/registry.sh" ;;
    *)
        qmodem_parser_error "$parser_id" "unknown_parser"
        exit 2
        ;;
esac

. "$registry"
output_file=$(mktemp "${TMPDIR:-/tmp}/qmodem-parser.XXXXXX") || exit 2
trap 'rm -f "$output_file"' EXIT HUP INT TERM
qmodem_parser_dispatch "$parser_id" "$platform" "$model" "$context_json" > "$output_file"
rc=$?
if ! jq -e . "$output_file" >/dev/null 2>&1; then
    qmodem_parser_error "$parser_id" "invalid_parser_output"
    exit 2
fi
jq -cS . "$output_file"
exit "$rc"
