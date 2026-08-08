#!/usr/bin/env bash
# Replay collected AT fixtures by vendor/platform/model profile.
# Layers: 1) fixture metadata and command heads must be valid;
#         2) read-only vendor methods must run cleanly and emit valid JSON;
#         3) profile-scoped expected/<method>.json snapshots are diffed.
set -u

TESTS_DIR=$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$TESTS_DIR/lib/test_env.sh"

fail=0
profile_segment()
{
    local value=$1 fallback=$2 slug
    [ -n "$value" ] || value=$fallback
    slug=$(printf '%s' "$value" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9._-' '_' | cut -c1-40)
    printf '%s' "${slug:-$fallback}"
}

model_segment()
{
    local value=$1 slug
    [ -n "$value" ] || value=unknown
    slug=$(profile_segment "$value" unknown)
    if [ "$value" = unknown ]; then
        printf '%s' "$slug"
    else
        printf '%s-%s' "$slug" "$(printf '%s' "$value" | md5sum | cut -c1-8)"
    fi
}

mapfile -t profile_dirs < <(
    find "$REPO_ROOT/testcases" -mindepth 4 -maxdepth 4 -type f -name '*.json' \
        -not -path '*/expected/*' -printf '%h\n' | sort -u
)

for profile_dir in "${profile_dirs[@]}"; do
    rel_profile=${profile_dir#"$REPO_ROOT/testcases/"}
    IFS=/ read -r vendor profile_platform profile_model extra <<< "$rel_profile"
    profile_label="$vendor/$profile_platform/$profile_model"
    if [ -n "${extra:-}" ]; then
        echo "FAIL: invalid testcase profile path: $rel_profile"
        fail=1
        continue
    fi

    if [ "$vendor" = "core" ]; then
        cmds_file="$QMODEM_HOME/cmds/generic.sh"
        vendor_file="$QMODEM_HOME/generic.sh"
    else
        cmds_file="$QMODEM_HOME/cmds/$vendor.sh"
        vendor_file="$QMODEM_HOME/vendor/$vendor.sh"
    fi
    if [ ! -f "$cmds_file" ] || [ ! -f "$vendor_file" ]; then
        echo "WARN: $profile_label: no matching cmds/vendor file, skipping"
        continue
    fi

    first_fixture=$(find "$profile_dir" -maxdepth 1 -type f -name '*.json' | sort | head -n 1)
    fixture_model=$(jq -r '.model // empty' "$first_fixture")
    [ -n "$fixture_model" ] || fixture_model=unknown
    fixture_vendor=$(jq -r '.vendor // empty' "$first_fixture")
    fixture_platform=$(jq -r '.platform // empty' "$first_fixture")
    fixture_modes=$(jq -r '.capabilities.modes // [] | join(" ")' "$first_fixture")
    [ -n "$fixture_modes" ] || fixture_modes=$(jq -r --arg model "$fixture_model" '
        [.modem_support[] | .[$model]? | .modes[]?] | join(" ")
    ' "$QMODEM_HOME/modem_support.json")
    profile_vendor_value=$fixture_vendor
    profile_platform_value=$fixture_platform
    if [ "$(profile_segment "$fixture_vendor" core)" != "$vendor" ] || \
       [ "$(profile_segment "$fixture_platform" unknown)" != "$profile_platform" ] || \
       [ "$(model_segment "$fixture_model")" != "$profile_model" ]; then
        echo "FAIL: $profile_label: profile path does not match fixture metadata"
        fail=1
        continue
    fi

    LOOKUP=$(mktemp -d)
    CMDS_LIST="$LOOKUP/commands.txt"
    SCENARIOS="$LOOKUP/scenarios.txt"
    : > "$CMDS_LIST"
    : > "$SCENARIOS"
    for f in "$profile_dir"/*.json; do
        [ -f "$f" ] || continue
        fixture_vendor=$(jq -r '.vendor // empty' "$f")
        fixture_platform=$(jq -r '.platform // empty' "$f")
        current_model=$(jq -r '.model // empty' "$f")
        if ! jq -e '
            (.responses | type) == "array" and (.responses | length) > 0 and
            all(.responses[];
                ((.scenario | type) == "string" and (.scenario | test("^[a-z0-9._-]+$"))) and
                ((.sequence | type) == "number" and .sequence >= 0) and
                ((.capture_sequence | type) == "number" and .capture_sequence >= 0) and
                ((.rc // 0) | type) == "number" and
                (((.response_hex | type) == "string" and (.response_hex | test("^([0-9a-fA-F]{2})*$"))) or
                 (.response != null)))' "$f" >/dev/null; then
            echo "FAIL: $profile_label: invalid responses in $(basename "$f")"
            fail=1
            continue
        fi
        if [ "$fixture_vendor" != "$profile_vendor_value" ] || \
           [ "$fixture_platform" != "$profile_platform_value" ] || \
           [ "$current_model" != "$fixture_model" ]; then
            echo "FAIL: $profile_label: metadata/path mismatch in $(basename "$f")"
            fail=1
            continue
        fi
        cmd=$(jq -r '.command' "$f")
        h=$(printf '%s' "$cmd" | md5sum | cut -c1-8)
        if [ -d "$LOOKUP/$h.responses" ]; then
            echo "FAIL: $profile_label: duplicate command fixture: $cmd"
            fail=1
            continue
        fi
        mkdir -p "$LOOKUP/$h.responses"
        while IFS= read -r response; do
            scenario=$(jq -r '.scenario // "default"' <<< "$response")
            if [ "$(profile_segment "$scenario" default)" != "$scenario" ]; then
                echo "FAIL: $profile_label: invalid response scenario '$scenario' in $(basename "$f")"
                fail=1
                continue
            fi
            mkdir -p "$LOOKUP/$h.responses/$scenario"
            response_index=$(find "$LOOKUP/$h.responses/$scenario" -name '*.response' | wc -l)
            response_hex=$(jq -r '.response_hex // empty' <<< "$response")
            if [ -n "$response_hex" ]; then
                fixture_hex_decode "$response_hex" > "$LOOKUP/$h.responses/$scenario/$response_index.response"
            else
                jq -j '.response' <<< "$response" > "$LOOKUP/$h.responses/$scenario/$response_index.response"
            fi
            jq -r '.rc // 0' <<< "$response" > "$LOOKUP/$h.responses/$scenario/$response_index.rc"
            printf '%s\n' "$scenario" >> "$SCENARIOS"
        done < <(jq -c '.responses | sort_by(.scenario // "default", .sequence // 0)[]' "$f")
        printf '%s\n' "$cmd" >> "$CMDS_LIST"
    done

    while read -r cmd; do
        [ -n "$cmd" ] || continue
        head=${cmd%%[=?]*}
        esc_head=$(printf '%s' "$head" | sed 's/\([$"]\)/\\\1/g')
        if ! grep -qF "$head" "$cmds_file" "$QMODEM_HOME/cmds/generic.sh" 2>/dev/null \
           && ! grep -qF "$esc_head" "$cmds_file" "$QMODEM_HOME/cmds/generic.sh" 2>/dev/null; then
            echo "FAIL: $profile_label: command head '$head' not found in cmds layer"
            fail=1
        fi
    done < "$CMDS_LIST"

    while IFS= read -r fixture_scenario; do
        [ -n "$fixture_scenario" ] || continue
        (
        . "$TESTS_DIR/lib/test_env.sh"
        vendor="$vendor"
        platform="$profile_platform"
        QMODEM_TESTCASE_MODEL="$fixture_model"
        QMODEM_TESTCASE_MODES="$fixture_modes"
        FIXTURE_LOOKUP="$LOOKUP"
        FIXTURE_SCENARIO="$fixture_scenario"
        export vendor platform QMODEM_TESTCASE_MODEL QMODEM_TESTCASE_MODES
        export FIXTURE_LOOKUP FIXTURE_SCENARIO
        . "$QMODEM_JSHN"
        . "$vendor_file"
        . "$cmds_file"
        mkdir -p "$FIXTURE_LOOKUP/cursors"
        . "$TESTS_DIR/lib/at_fixture.sh"

        # First prove the queue preserves every recorded byte sequence and rc.
        rm -f "$FIXTURE_LOOKUP/cursors"/*
        for fixture in "$profile_dir"/*.json; do
            [ -f "$fixture" ] || continue
            fixture_cmd=$(jq -r '.command' "$fixture")
            fixture_tool=$(jq -r '.tool // "at"' "$fixture")
            while IFS= read -r response; do
                fixture_rc=$(jq -r '.rc // 0' <<< "$response")
                fixture_hex=$(jq -r '.response_hex // empty' <<< "$response")
                expected_file="$LOOKUP/expected.response"
                replayed_file="$LOOKUP/replayed.response"
                if [ -n "$fixture_hex" ]; then
                    fixture_hex_decode "$fixture_hex" > "$expected_file"
                else
                    jq -j '.response' <<< "$response" > "$expected_file"
                fi
                "$fixture_tool" "$at_port" "$fixture_cmd" > "$replayed_file"
                replayed_rc=$?
                if [ "$replayed_rc" -ne "$fixture_rc" ] || ! cmp "$expected_file" "$replayed_file"; then
                    echo "FAIL: $profile_label/$fixture_scenario: queue replay mismatch: $(basename "$fixture")"
                    exit 1
                fi
            done < <(jq -c --arg scenario "$fixture_scenario" \
                '.responses | map(select((.scenario // "default") == $scenario)) | sort_by(.sequence // 0)[]' "$fixture")
        done

        expected_dir="$profile_dir/expected/$fixture_scenario"
        for exp in "$expected_dir"/*.json; do
            [ -f "$exp" ] || continue
            method=$(basename "$exp" .json)
            case "$method" in
                base_info|cell_info|get_*) ;;
                *) echo "WARN: $profile_label/$fixture_scenario: refusing non-read-only snapshot: $method"; continue ;;
            esac
            if ! command -v "$method" >/dev/null; then
                echo "WARN: $profile_label/$fixture_scenario: $method not defined, skipping snapshot"
                continue
            fi
            rm -f "$FIXTURE_LOOKUP/cursors"/* "$FIXTURE_LOOKUP/misses.log"
            out=$(
                json_init
                json_add_object result
                json_close_object
                case "$method" in
                    base_info|cell_info)
                        json_add_array modem_info
                        "$method"
                        json_close_array
                        ;;
                    *) "$method" ;;
                esac
                json_dump
            )
            rc=$?
            if [ -s "$FIXTURE_LOOKUP/misses.log" ]; then
                echo "FAIL: $profile_label/$fixture_scenario: $method exhausted or missed fixture responses"
                sed 's/^/  /' "$FIXTURE_LOOKUP/misses.log"
                exit 1
            fi
            if [ "$rc" -ne 0 ] || ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
                echo "FAIL: $profile_label/$fixture_scenario: $method failed (rc=$rc) or emitted invalid JSON"
                exit 1
            fi
            if ! diff <(jq -S . "$exp") <(printf '%s' "$out" | jq -S .) >/dev/null; then
                echo "FAIL: $profile_label/$fixture_scenario: $method differs from expected snapshot:"
                diff <(jq -S . "$exp") <(printf '%s' "$out" | jq -S .) | head -20
                exit 1
            fi
            echo "OK: $profile_label/$fixture_scenario: $method matches golden snapshot"
        done

        echo "OK: $profile_label/$fixture_scenario: replay passed"
        ) || fail=1
    done < <(sort -u "$SCENARIOS")

    rm -rf "$LOOKUP"
done

echo '--- fixture coverage (warn only) ---'
for cmds_file in "$QMODEM_HOME"/cmds/*.sh; do
    v=$(basename "$cmds_file" .sh)
    missing_file=$(mktemp)
    sed -n 's/.*at "$1" ["'\''"]\([^"'\''"]*\).*/\1/p' "$cmds_file" | while read -r lit; do
        lit=$(printf '%s' "$lit" | sed 's/^\${2}//; s/^$2//')
        head=$(printf '%s' "$lit" | sed 's/[^A-Za-z0-9+!^#&*$-].*$//')
        [ -n "$head" ] || continue
        found=0
        case "$v" in
            generic|modem_dial|modem_util) fixture_roots=("$REPO_ROOT/testcases") ;;
            *) fixture_roots=("$REPO_ROOT/testcases/$v" "$REPO_ROOT/testcases/core") ;;
        esac
        for fixture_root in "${fixture_roots[@]}"; do
            [ -d "$fixture_root" ] || continue
            if find "$fixture_root" -type f -name '*.json' -not -path '*/expected/*' \
                -exec jq -r '.command' {} + 2>/dev/null | grep -qF "$head"; then
                found=1
                break
            fi
        done
        if [ "$found" -eq 0 ]; then
            printf '%s\n' "$head" >> "$missing_file"
        fi
    done
    missing=$(sort -u "$missing_file" | wc -l)
    [ "$missing" -eq 0 ] || echo "  $v: $missing command heads without fixtures"
    rm -f "$missing_file"
done

if [ "$fail" -eq 0 ]; then
    echo 'vendor fixture tests passed'
else
    echo 'vendor fixture tests FAILED' >&2
    exit 1
fi
