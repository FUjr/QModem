#!/bin/sh
# import_testcases.sh <tarball> - merge collected qmodem AT fixtures into testcases/
set -eu

[ $# -ge 1 ] || { echo "usage: $0 <qmodem_testcases_*.tar.gz>" >&2; exit 1; }
tarball="$1"
[ -f "$tarball" ] || { echo "not found: $tarball" >&2; exit 1; }
repo_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tar -xzf "$tarball" -C "$tmp"

# validate every fixture before merging; archives may contain fixtures only
fixture_list="$tmp/fixture-list"
find "$tmp" -name '*.json' -type f > "$fixture_list"
[ -s "$fixture_list" ] || { echo "archive contains no fixtures" >&2; exit 1; }
while IFS= read -r f; do
    case "$f" in
        "$tmp"/recognition/pending/*)
            echo "unresolved recognition fixture: $f" >&2
            exit 1
            ;;
        "$tmp"/recognition/*/*/*/*.json)
            filter='.phase == "recognition" and .config_section and .command and
                (.expected_identity.vendor and .expected_identity.platform and .expected_identity.model) and
                (((.response_hex | type) == "string" and (.response_hex | test("^([0-9a-fA-F]{2})*$"))) or (.response != null))'
            ;;
        "$tmp"/*/*/*/expected/*.json) filter='type == "object"' ;;
        "$tmp"/*/*/*/*.json) filter='.vendor and .platform and .model and .command and
            (((.response_hex | type) == "string" and (.response_hex | test("^([0-9a-fA-F]{2})*$"))) or (.response != null))' ;;
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

# merge (same relative path overwrites; filename = command hash, so reruns dedupe)
cd "$tmp"
find . -name '*.json' -type f > "$fixture_list"
while IFS= read -r f; do
    rel=${f#./}
    dst="$repo_root/testcases/$rel"
    mkdir -p "$(dirname "$dst")"
    cp "$f" "$dst"
done < "$fixture_list"
cd "$repo_root"

git status --short testcases/ 2>/dev/null | head -20 || true
echo "imported into testcases/; review with 'git diff testcases/' and commit"
