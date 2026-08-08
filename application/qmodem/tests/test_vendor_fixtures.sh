#!/usr/bin/env bash
# Replay response queues and compare profile/scenario-specific vendor JSON.
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

    if [ "$vendor" = core ]; then
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
    fixture_vendor=$(jq -r '.vendor // empty' "$first_fixture")
    fixture_platform=$(jq -r '.platform // empty' "$first_fixture")
    fixture_model=$(jq -r '.model // "unknown"' "$first_fixture")
    fixture_modes=$(jq -r '.capabilities.modes // [] | join(" ")' "$first_fixture")
    [ -n "$fixture_modes" ] || fixture_modes=$(jq -r --arg model "$fixture_model" '
        [.modem_support[] | .[$model]? | .modes[]?] | join(" ")
    ' "$QMODEM_HOME/modem_support.json")
    if [ "$(profile_segment "$fixture_vendor" core)" != "$vendor" ] || \
       [ "$(profile_segment "$fixture_platform" unknown)" != "$profile_platform" ] || \
       [ "$(model_segment "$fixture_model")" != "$profile_model" ]; then
        echo "FAIL: $profile_label: profile path does not match fixture metadata"
        fail=1
        continue
    fi

    LOOKUP=$(mktemp -d)
    SCENARIOS="$LOOKUP/scenarios.txt"
    CMDS_LIST="$LOOKUP/commands.txt"
    : > "$SCENARIOS"
    : > "$CMDS_LIST"
    mkdir -p "$LOOKUP/cursors"

    for fixture in "$profile_dir"/*.json; do
        [ -f "$fixture" ] || continue
        if ! jq -e '.schema_version == 2 and (.responses | type) == "array" and (.responses | length) > 0' \
            "$fixture" >/dev/null; then
            echo "FAIL: $profile_label: invalid v2 fixture: $(basename "$fixture")"
            fail=1
            continue
        fi
        current_vendor=$(jq -r '.vendor' "$fixture")
        current_platform=$(jq -r '.platform' "$fixture")
        current_model=$(jq -r '.model' "$fixture")
        if [ "$current_vendor" != "$fixture_vendor" ] || \
           [ "$current_platform" != "$fixture_platform" ] || \
           [ "$current_model" != "$fixture_model" ]; then
            echo "FAIL: $profile_label: inconsistent fixture metadata: $(basename "$fixture")"
            fail=1
            continue
        fi
        command=$(jq -r '.command' "$fixture")
        hash=$(printf '%s' "$command" | md5sum | cut -c1-8)
        if [ -d "$LOOKUP/$hash.responses" ]; then
            echo "FAIL: $profile_label: duplicate command fixture: $command"
            fail=1
            continue
        fi
        printf '%s\n' "$command" >> "$CMDS_LIST"
        while IFS= read -r response; do
            scenario=$(jq -r '.scenario' <<< "$response")
            sequence=$(jq -r '.sequence' <<< "$response")
            if [ "$(profile_segment "$scenario" default)" != "$scenario" ] || \
               ! [[ "$sequence" =~ ^[0-9]+$ ]]; then
                echo "FAIL: $profile_label: invalid scenario/sequence in $(basename "$fixture")"
                fail=1
                continue
            fi
            variant="$LOOKUP/$hash.responses/$scenario/$sequence"
            if [ -e "$variant.response" ]; then
                echo "FAIL: $profile_label: duplicate $scenario sequence $sequence for $command"
                fail=1
                continue
            fi
            mkdir -p "$(dirname "$variant")"
            response_hex=$(jq -r '.response_hex // empty' <<< "$response")
            if [ -n "$response_hex" ]; then
                fixture_hex_decode "$response_hex" > "$variant.response"
            else
                jq -j '.response // ""' <<< "$response" > "$variant.response"
            fi
            jq -r '.rc // 0' <<< "$response" > "$variant.rc"
            printf '%s\n' "$scenario" >> "$SCENARIOS"
        done < <(jq -c '.responses[]' "$fixture")
    done

    while IFS= read -r command; do
        [ -n "$command" ] || continue
        head=${command%%[=?]*}
        esc_head=$(printf '%s' "$head" | sed 's/\([$"]\)/\\\1/g')
        command_name=$(printf '%s' "$head" | sed 's/^AT[+!^#&*$]*//')
        if ! grep -qF "$head" "$cmds_file" "$QMODEM_HOME/cmds/generic.sh" 2>/dev/null && \
           ! grep -qF "$esc_head" "$cmds_file" "$QMODEM_HOME/cmds/generic.sh" 2>/dev/null && \
           ! grep -qiF "$command_name" "$cmds_file" 2>/dev/null && \
           ! grep -RqiF "$command_name" "$QMODEM_HOME/cmds" 2>/dev/null; then
            echo "FAIL: $profile_label: command head '$head' not found in cmds layer"
            fail=1
        fi
    done < "$CMDS_LIST"

    while IFS= read -r scenario; do
        [ -n "$scenario" ] || continue
        expected_dir="$profile_dir/expected/$scenario"
        if [ ! -d "$expected_dir" ]; then
            echo "OK: $profile_label/$scenario: parser-only responses loaded"
            continue
        fi
        (
            . "$TESTS_DIR/lib/test_env.sh"
            vendor="$vendor"
            platform="$profile_platform"
            model="$fixture_model"
            QMODEM_TESTCASE_MODEL="$fixture_model"
            QMODEM_TESTCASE_MODES="$fixture_modes"
            FIXTURE_LOOKUP="$LOOKUP"
            FIXTURE_SCENARIO="$scenario"
            export vendor platform model QMODEM_TESTCASE_MODEL QMODEM_TESTCASE_MODES
            export FIXTURE_LOOKUP FIXTURE_SCENARIO
            . "$QMODEM_JSHN"
            . "$vendor_file"
            . "$cmds_file"
            . "$TESTS_DIR/lib/at_fixture.sh"

            for expected in "$expected_dir"/*.json; do
                [ -f "$expected" ] || continue
                method=$(basename "$expected" .json)
                case "$method" in
                    base_info|cell_info|get_*) ;;
                    *) echo "WARN: $profile_label/$scenario: refusing non-read-only snapshot: $method"; continue ;;
                esac
                if ! command -v "$method" >/dev/null; then
                    echo "WARN: $profile_label/$scenario: $method not defined, skipping snapshot"
                    continue
                fi
                rm -f "$FIXTURE_LOOKUP/cursors"/* "$FIXTURE_LOOKUP/misses.log"
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
                out=$(json_dump)
                rc=$?
                if [ -s "$FIXTURE_LOOKUP/misses.log" ]; then
                    echo "FAIL: $profile_label/$scenario: $method missed/exhausted responses"
                    sed 's/^/  /' "$FIXTURE_LOOKUP/misses.log"
                    exit 1
                fi
                if [ "$rc" -ne 0 ] || ! printf '%s' "$out" | jq -e . >/dev/null 2>&1 || \
                   ! diff <(jq -S . "$expected") <(printf '%s' "$out" | jq -S .) >/dev/null; then
                    echo "FAIL: $profile_label/$scenario: $method output changed"
                    diff <(jq -S . "$expected") <(printf '%s' "$out" | jq -S .) | head -30 || true
                    exit 1
                fi
                echo "OK: $profile_label/$scenario: $method matches golden snapshot"
            done
        ) || fail=1
    done < <(sort -u "$SCENARIOS")
    rm -rf "$LOOKUP"
done

echo '--- fixture coverage (warn only) ---'
for cmds_file in "$QMODEM_HOME"/cmds/*.sh; do
    vendor_name=$(basename "$cmds_file" .sh)
    missing_file=$(mktemp)
    sed -n 's/.*at "$1" ["'\''"]\([^"'\''"]*\).*/\1/p' "$cmds_file" | while read -r literal; do
        literal=$(printf '%s' "$literal" | sed 's/^\${2}//; s/^$2//')
        head=$(printf '%s' "$literal" | sed 's/[^A-Za-z0-9+!^#&*$-].*$//')
        [ -n "$head" ] || continue
        if ! find "$REPO_ROOT/testcases" -type f -name '*.json' -not -path '*/expected/*' \
            -exec jq -r '.command // empty' {} + 2>/dev/null | grep -qF "$head"; then
            printf '%s\n' "$head" >> "$missing_file"
        fi
    done
    missing=$(sort -u "$missing_file" | wc -l)
    [ "$missing" -eq 0 ] || echo "  $vendor_name: $missing command heads without fixtures"
    rm -f "$missing_file"
done

if [ "$fail" -ne 0 ]; then
    echo 'vendor fixture tests FAILED' >&2
    exit 1
fi
echo 'vendor fixture tests passed'
