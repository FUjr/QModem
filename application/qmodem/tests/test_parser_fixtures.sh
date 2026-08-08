#!/usr/bin/env bash
# Validate parser assertions independently from vendor JSON assembly.
set -u

TESTS_DIR=$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$TESTS_DIR/lib/test_env.sh"

PARSER="$QMODEM_HOME/parsers/parse.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0
assertion_count=0

mapfile -t fixtures < <(
    find "$REPO_ROOT/testcases" -type f -name '*.json' \
        -not -path '*/expected/*' | sort
)

for fixture in "${fixtures[@]}"; do
    if ! jq -e '
        .schema_version == 2 and (.responses | type) == "array" and
        ([.responses[] |
            (.scenario | type) == "string" and
            (.scenario | test("^[a-z0-9._-]+$")) and
            (.sequence | type) == "number" and
            (.assertions | type) == "array" and
            ([.assertions[] |
                (.parser | type) == "string" and
                (.context | type) == "object" and
                (.expected | type) == "object" and
                ((.expected_rc // 0) | type) == "number"] | all)
        ] | all)' "$fixture" >/dev/null; then
        echo "FAIL: invalid parser fixture schema: ${fixture#"$REPO_ROOT/"}" >&2
        fail=1
        continue
    fi

    vendor=$(jq -r '.vendor // .expected_identity.vendor // "core"' "$fixture")
    platform=$(jq -r '.platform // .expected_identity.platform // "unknown"' "$fixture")
    model=$(jq -r '.model // .expected_identity.model // "unknown"' "$fixture")
    response_count=$(jq '.responses | length' "$fixture")
    response_index=0
    while [ "$response_index" -lt "$response_count" ]; do
        raw="$work/response.raw"
        response_hex=$(jq -r --argjson i "$response_index" \
            '.responses[$i].response_hex // empty' "$fixture")
        if [ -n "$response_hex" ]; then
            fixture_hex_decode "$response_hex" > "$raw"
        else
            jq -j --argjson i "$response_index" '.responses[$i].response // ""' "$fixture" > "$raw"
        fi

        assertion_total=$(jq --argjson i "$response_index" '.responses[$i].assertions | length' "$fixture")
        assertion_index=0
        while [ "$assertion_index" -lt "$assertion_total" ]; do
            assertion=$(jq -c --argjson i "$response_index" --argjson a "$assertion_index" \
                '.responses[$i].assertions[$a]' "$fixture")
            parser_id=$(jq -r '.parser' <<< "$assertion")
            context=$(jq -c '.context' <<< "$assertion")
            expected_rc=$(jq -r '.expected_rc // 0' <<< "$assertion")
            case "$parser_id" in
                "$vendor".*|core.*) ;;
                *)
                    echo "FAIL: $parser_id does not belong to fixture vendor $vendor" >&2
                    fail=1
                    assertion_index=$((assertion_index + 1))
                    continue
                    ;;
            esac

            actual_file="$work/actual.json"
            "$PARSER" "$parser_id" --platform "$platform" --model "$model" \
                --context-json "$context" < "$raw" > "$actual_file"
            actual_rc=$?
            if [ "$actual_rc" -ne "$expected_rc" ] || ! jq -e . "$actual_file" >/dev/null 2>&1 || \
               ! diff <(jq -S '.expected' <<< "$assertion") <(jq -S . "$actual_file") >/dev/null; then
                echo "FAIL: ${fixture#"$REPO_ROOT/"} response[$response_index] $parser_id" >&2
                echo "  rc: expected=$expected_rc actual=$actual_rc" >&2
                diff <(jq -S '.expected' <<< "$assertion") <(jq -S . "$actual_file") >&2 || true
                fail=1
            else
                canonical=$(jq -cS . "$actual_file")
                actual=$(cat "$actual_file")
                if [ "$actual" != "$canonical" ]; then
                    echo "FAIL: non-canonical parser output: $parser_id" >&2
                    fail=1
                fi
            fi
            assertion_count=$((assertion_count + 1))
            assertion_index=$((assertion_index + 1))
        done
        response_index=$((response_index + 1))
    done
done

attack_file="$work/parser-id-was-executed"
printf 'x' | "$PARSER" "quectel.cgsn;touch $attack_file" \
    --platform unknown --model unknown --context-json '{}' >/dev/null
attack_rc=$?
if [ "$attack_rc" -ne 2 ] || [ -e "$attack_file" ]; then
    echo 'FAIL: untrusted parser ID was not safely rejected' >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo 'parser fixture tests FAILED' >&2
    exit 1
fi
echo "parser fixture tests passed ($assertion_count assertions)"
