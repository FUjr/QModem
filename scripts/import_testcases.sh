#!/bin/sh
# import_testcases.sh <tarball> - merge collected qmodem AT fixtures into testcases/
set -eu

[ $# -ge 1 ] || { echo "usage: $0 <qmodem_testcases_*.tar.gz>" >&2; exit 1; }
tarball="$1"
[ -f "$tarball" ] || { echo "not found: $tarball" >&2; exit 1; }
repo_root=${QMODEM_TEST_REPO_ROOT:-$(CDPATH= cd "$(dirname "$0")/.." && pwd)}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tar -xzf "$tarball" -C "$tmp"

# Legacy snapshots had no state boundary. Place them in the default scenario.
find "$tmp" -type f -name '*.json' -path '*/expected/*.json' | while IFS= read -r f; do
    [ "$(basename "$(dirname "$f")")" = expected ] || continue
    mkdir -p "$(dirname "$f")/default"
    mv "$f" "$(dirname "$f")/default/$(basename "$f")"
done

# validate every fixture before merging; archives may contain fixtures only
fixture_list="$tmp/fixture-list"
find "$tmp" -name '*.json' -type f > "$fixture_list"
[ -s "$fixture_list" ] || { echo "archive contains no fixtures" >&2; exit 1; }
while IFS= read -r f; do
    case "$f" in
        */expected/*) ;;
        *)
            if ! jq -e 'has("responses")' "$f" >/dev/null 2>&1; then
                normalized="${f}.normalized"
                jq '.responses=[{response_hex:(.response_hex // ""), response:.response,
                                  rc:(.rc // 0), timestamp:(.timestamp // ""),
                                  scenario:"default", sequence:0, capture_sequence:0}]
                    | .responses |= map(if .response == null then del(.response) else . end)
                    | del(.response_hex, .response, .rc, .timestamp)' "$f" > "$normalized" || {
                        echo "invalid legacy fixture: $f" >&2
                        exit 1
                    }
                mv "$normalized" "$f"
            fi
            normalized="${f}.normalized"
            jq '.responses |= to_entries | .responses |= map(
                    .value + {scenario:(.value.scenario // "default"), sequence:(.value.sequence // .key),
                              capture_sequence:(.value.capture_sequence // .value.sequence // .key)})' \
                "$f" > "$normalized" && mv "$normalized" "$f"
            ;;
    esac
    case "$f" in
        "$tmp"/recognition/pending/*)
            echo "unresolved recognition fixture: $f" >&2
            exit 1
            ;;
        "$tmp"/recognition/*/*/*/*.json)
            filter='.phase == "recognition" and .config_section and .command and
                (.expected_identity.vendor and .expected_identity.platform and .expected_identity.model) and
                ((.responses | type) == "array" and (.responses | length) > 0) and
                all(.responses[];
                    ((.scenario | type) == "string" and (.scenario | test("^[a-z0-9._-]+$"))) and
                    ((.sequence | type) == "number" and .sequence >= 0) and
                    ((.capture_sequence | type) == "number" and .capture_sequence >= 0) and
                    ((.rc // 0) | type) == "number" and
                    (((.response_hex | type) == "string" and (.response_hex | test("^([0-9a-fA-F]{2})*$"))) or
                     (.response != null)))'
            ;;
        "$tmp"/*/*/*/expected/*/*.json) filter='type == "object"' ;;
        "$tmp"/*/*/*/*.json) filter='.vendor and .platform and .model and .command and
            ((.responses | type) == "array" and (.responses | length) > 0) and
            all(.responses[];
                ((.scenario | type) == "string" and (.scenario | test("^[a-z0-9._-]+$"))) and
                ((.sequence | type) == "number" and .sequence >= 0) and
                ((.capture_sequence | type) == "number" and .capture_sequence >= 0) and
                ((.rc // 0) | type) == "number" and
                (((.response_hex | type) == "string" and (.response_hex | test("^([0-9a-fA-F]{2})*$"))) or
                 (.response != null)))' ;;
        *)
            echo "invalid fixture path (expected vendor/platform/model): $f" >&2
            exit 1
            ;;
    esac
    jq -e "$filter" "$f" >/dev/null || {
        echo "invalid fixture: $f" >&2
        exit 1
    }
done < "$fixture_list"

# Merge command responses by scenario. Expected snapshots remain scenario-specific files.
cd "$tmp"
find . -name '*.json' -type f > "$fixture_list"
while IFS= read -r f; do
    rel=${f#./}
    dst="$repo_root/testcases/$rel"
    mkdir -p "$(dirname "$dst")"
    if [ -f "$dst" ] && [ "${rel#*/expected/}" = "$rel" ]; then
        merged="${dst}.merged"
        jq -s '
          .[0] as $old | .[1] as $new | ($old * $new)
          | .responses = ([$old.responses[], $new.responses[]]
              | unique_by([.scenario, .capture_sequence, .timestamp, .response_hex, .response, .rc])
              | group_by(.scenario)
              | map(sort_by(.sequence) | to_entries | map(.value + {sequence:.key}))
              | add)
        ' "$dst" "$f" > "$merged" && mv "$merged" "$dst"
    else
        cp "$f" "$dst"
    fi
done < "$fixture_list"
cd "$repo_root"

git status --short testcases/ 2>/dev/null | head -20 || true
echo "imported into testcases/; review with 'git diff testcases/' and commit"
