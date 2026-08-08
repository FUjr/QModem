#!/usr/bin/env bash
# Replay collected AT fixtures (testcases/) against vendor parsing code.
# Layers: 1) fixture command heads must exist in the cmds layer;
#         2) read-only vendor methods must run cleanly and emit valid JSON;
#         3) expected/<method>.json golden snapshots are diffed when present.
set -u

TESTS_DIR=$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$TESTS_DIR/lib/test_env.sh"

fail=0

for vendor_dir in "$REPO_ROOT"/testcases/*/; do
    [ -d "$vendor_dir" ] || continue
    vendor=$(basename "$vendor_dir")
    [ "$vendor" = "core" ] && cmds_file="$QMODEM_HOME/cmds/generic.sh" || cmds_file="$QMODEM_HOME/cmds/$vendor.sh"
    vendor_file="$QMODEM_HOME/vendor/$vendor.sh"
    if [ ! -f "$cmds_file" ] || [ ! -f "$vendor_file" ]; then
        echo "WARN: $vendor: no matching cmds/vendor file, skipping"
        continue
    fi

    # build fixture lookup (md5 of command -> response/rc)
    LOOKUP=$(mktemp -d)
    CMDS_LIST="$LOOKUP/commands.txt"
    : > "$CMDS_LIST"
    for f in "$vendor_dir"/*.json; do
        [ -f "$f" ] || continue
        cmd=$(jq -r '.command' "$f")
        h=$(printf '%s' "$cmd" | md5sum | cut -c1-8)
        response_hex=$(jq -r '.response_hex // empty' "$f")
        if [ -n "$response_hex" ]; then
            fixture_hex_decode "$response_hex" > "$LOOKUP/$h.response"
        else
            jq -j '.response' "$f" > "$LOOKUP/$h.response"
        fi
        jq -r '.rc // 0' "$f" > "$LOOKUP/$h.rc"
        printf '%s\n' "$cmd" >> "$CMDS_LIST"
    done

    # layer 1: fixture command heads must still exist in the cmds layer
    while read -r cmd; do
        [ -n "$cmd" ] || continue
        head=${cmd%%[=?]*}
        esc_head=$(printf '%s' "$head" | sed 's/\([$"]\)/\\\1/g')
        if ! grep -qF "$head" "$cmds_file" "$QMODEM_HOME/cmds/generic.sh" 2>/dev/null \
           && ! grep -qF "$esc_head" "$cmds_file" "$QMODEM_HOME/cmds/generic.sh" 2>/dev/null; then
            echo "FAIL: $vendor: command head '$head' not found in cmds layer (fixture: $cmd)"
            fail=1
        fi
    done < "$CMDS_LIST"

    # layer 2+3: replay in a subshell
    (
    . "$TESTS_DIR/lib/test_env.sh"
    . "$QMODEM_JSHN"
    . "$vendor_file"
    . "$cmds_file"
    FIXTURE_LOOKUP="$LOOKUP"
    export FIXTURE_LOOKUP
    . "$TESTS_DIR/lib/at_fixture.sh"

    # mandatory smoke: every fixture must replay byte-for-byte with its rc
    for fixture in "$vendor_dir"/*.json; do
        [ -f "$fixture" ] || continue
        fixture_cmd=$(jq -r '.command' "$fixture")
        fixture_tool=$(jq -r '.tool // "at"' "$fixture")
        fixture_rc=$(jq -r '.rc // 0' "$fixture")
        expected_file="$LOOKUP/expected.response"
        replayed_file="$LOOKUP/replayed.response"
        fixture_hex=$(jq -r '.response_hex // empty' "$fixture")
        if [ -n "$fixture_hex" ]; then
            fixture_hex_decode "$fixture_hex" > "$expected_file"
        else
            jq -j '.response' "$fixture" > "$expected_file"
        fi
        $fixture_tool "$at_port" "$fixture_cmd" > "$replayed_file"
        replayed_rc=$?
        if [ "$replayed_rc" -ne "$fixture_rc" ] || ! cmp "$expected_file" "$replayed_file"; then
            echo "FAIL: $vendor: fixture replay mismatch: $(basename "$fixture")"
            exit 1
        fi
    done

    # golden snapshots
    for exp in "$vendor_dir"/expected/*.json; do
        [ -f "$exp" ] || continue
        method=$(basename "$exp" .json)
        case "$method" in
            base_info|cell_info|get_*) ;;
            *)
                echo "WARN: $vendor: refusing non-read-only snapshot method: $method"
                continue
                ;;
        esac
        if ! command -v "$method" >/dev/null; then
            echo "WARN: $vendor: $method not defined, skipping snapshot"
            continue
        fi
        json_init
        out=$("$method"; json_dump)
        rc=$?
        if [ $rc -ne 0 ] || ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
            echo "FAIL: $vendor: $method failed (rc=$rc) or emitted invalid JSON"
            exit 1
        fi
        if ! diff <(jq -S . "$exp") <(printf '%s' "$out" | jq -S .) >/dev/null; then
            echo "FAIL: $vendor: $method differs from expected/$method.json:"
            diff <(jq -S . "$exp") <(printf '%s' "$out" | jq -S .) | head -20
            exit 1
        fi
        echo "OK: $vendor: $method matches golden snapshot"
    done

    echo "OK: $vendor: replay passed"
    ) || fail=1

    if [ -f "$LOOKUP/misses.log" ]; then
        echo "INFO: $vendor: commands used but without fixtures:"
        sort -u "$LOOKUP/misses.log" | sed 's/^/  /' | head -10
    fi
    rm -rf "$LOOKUP"
done

# coverage report (warn only): cmds commands without any fixture
echo '--- fixture coverage (warn only) ---'
for cmds_file in "$QMODEM_HOME"/cmds/*.sh; do
    v=$(basename "$cmds_file" .sh)
    [ "$v" = "generic" ] && tdir="$REPO_ROOT/testcases" || tdir="$REPO_ROOT/testcases/$v"
    # extract command literals from wrapper bodies
    missing_file=$(mktemp)
    sed -n 's/.*at "$1" ["'\''"]\([^"'\''"]*\).*/\1/p' "$cmds_file" | while read -r lit; do
        # strip leading at_pre parameter used by foxconn-style wrappers
        lit=$(printf '%s' "$lit" | sed 's/^\${2}//; s/^$2//')
        head=$(printf '%s' "$lit" | sed 's/[^A-Za-z0-9+!^#&*$-].*$//')
        [ -n "$head" ] || continue
        found=0
        for dir in "$tdir" "$REPO_ROOT/testcases"; do
            [ -d "$dir" ] || continue
            while read -r fc; do
                case "$fc" in *"$head"*) found=1; break ;; esac
            done < <(find "$dir" -maxdepth 2 -name '*.json' -not -path '*/expected/*' -exec jq -r '.command' {} + 2>/dev/null)
            [ "$found" = 1 ] && break
        done
        [ "$found" = 1 ] || printf '%s\n' "$head" >> "$missing_file"
    done
    missing=$(sort -u "$missing_file" | wc -l)
    [ "$missing" -eq 0 ] || echo "  $v: $missing command heads without fixtures"
    rm -f "$missing_file"
done

if [ $fail -eq 0 ]; then
    echo 'vendor fixture tests passed'
else
    echo 'vendor fixture tests FAILED' >&2
    exit 1
fi
