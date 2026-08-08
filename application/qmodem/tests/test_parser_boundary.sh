#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR=$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$TESTS_DIR/lib/test_env.sh"

parser_dir="$QMODEM_HOME/parsers"
business_paths=(
    "$QMODEM_HOME/generic.sh"
    "$QMODEM_HOME/modem_util.sh"
    "$QMODEM_HOME/modem_dial.sh"
    "$QMODEM_HOME/vendor"
)

fail=0
if rg -n '\b(at|fastat|uci|json_add_[A-Za-z_]+)\b|/etc/config|/tmp/' \
    "$parser_dir" --glob '*.sh'; then
    echo 'FAIL: parser layer accesses commands, UCI, business JSON, or mutable state' >&2
    fail=1
fi

if rg -n '^([^#]|$)*\$\(cmd_[A-Za-z0-9_]+[^|)]*\|[[:space:]]*(grep|sed|awk|cut)' \
    "${business_paths[@]}"; then
    echo 'FAIL: business layer directly parses a cmd_* response' >&2
    fail=1
fi

if rg -n 'response_lines|\.(lines|fields)([^A-Za-z0-9_]|$)' "${business_paths[@]}"; then
    echo 'FAIL: business layer consumes unnamed parser output' >&2
    fail=1
fi

malicious_id='core.command.completion;touch /tmp/qmodem-parser-injection'
if printf 'OK\r\n' | "$parser_dir/parse.sh" "$malicious_id" \
    --platform unknown --model unknown --context-json '{}' >/dev/null 2>&1; then
    echo 'FAIL: malicious parser ID was accepted' >&2
    fail=1
fi
[ ! -e /tmp/qmodem-parser-injection ] || {
    echo 'FAIL: parser ID executed as shell code' >&2
    fail=1
}

[ "$fail" -eq 0 ] || exit 1
echo 'parser boundary tests passed'
