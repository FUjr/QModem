#!/usr/bin/env bash
# Legacy single-response feedback is normalized to responses[] during import.
set -euo pipefail

TESTS_DIR=$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH= cd "$TESTS_DIR/../../.." && pwd)
test_root=$(mktemp -d)
archive=$(mktemp --suffix=.tar.gz)
source_dir="$test_root/source/quectel/qualcomm/example-1a79a4d6"
cleanup() { rm -rf "$test_root" "$archive"; }
trap cleanup EXIT

mkdir -p "$source_dir"
jq -n '{vendor:"quectel",platform:"qualcomm",model:"example",command:"AT+CGSN",
        tool:"at",response_hex:"4f4b0d0a",rc:0,timestamp:"legacy"}' \
    > "$source_dir/AT_CGSN.json"
tar -czf "$archive" -C "$test_root/source" .

QMODEM_TEST_REPO_ROOT="$test_root/import" "$REPO_ROOT/scripts/import_testcases.sh" "$archive" >/dev/null
fixture="$test_root/import/testcases/quectel/qualcomm/example-1a79a4d6/AT_CGSN.json"
jq -e '
    (.responses | length) == 1 and
    .responses[0] == {response_hex:"4f4b0d0a",rc:0,timestamp:"legacy"} and
    (has("response_hex") | not) and (has("rc") | not)' "$fixture" >/dev/null

echo 'testcase import compatibility tests passed'
