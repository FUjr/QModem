#!/usr/bin/env bash
set -eu
SCAN_TESTS_DIR=$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SCAN_TESTS_DIR/../../qmodem/tests/lib/test_env.sh"
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT
mkdir "$temp_dir/bin"
cat >"$temp_dir/bin/uci" <<'EOF'
#!/bin/sh
exit 1
EOF
cat >"$temp_dir/bin/tom_modem" <<'EOF'
#!/bin/sh
printf called >"$QMODEM_TEST_AT_MARKER"
case "$QMODEM_TEST_AT_MODE" in
    slow-ok) sleep 0.6 ;;
    hang) sleep 5 ;;
esac
printf 'ATI\nOK\n'
EOF
chmod +x "$temp_dir/bin/uci" "$temp_dir/bin/tom_modem"
export PATH="$temp_dir/bin:$PATH"
export QMODEM_TEST_AT_MARKER="$temp_dir/called"
cc -D_GNU_SOURCE -std=c99 -O2 -Wall -Wextra \
    "$SCAN_TESTS_DIR/test_at_lock.c" -o "$temp_dir/test-at-lock" $(pkg-config --cflags --libs json-c) -lpthread
"$temp_dir/test-at-lock"
