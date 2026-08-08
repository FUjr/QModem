#!/usr/bin/env bash
# The same vendor command may have different bytes on different model/platform profiles.
set -euo pipefail

PACKAGE_DIR=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

write_fixture()
{
    local platform=$1 model=$2 model_dir=$3 response=$4 response2=${5:-} dir hex hex2
    dir="$test_root/testcases/quectel/$platform/$model_dir"
    mkdir -p "$dir"
    hex=$(printf '%s' "$response" | xxd -p | tr -d '\n')
    hex2=$(printf '%s' "$response2" | xxd -p | tr -d '\n')
    jq -n --arg platform "$platform" --arg model "$model" --arg hex "$hex" --arg hex2 "$hex2" \
        '{vendor:"quectel",platform:$platform,model:$model,command:"AT+CGSN",tool:"at",
          responses:([{response_hex:$hex,rc:0,timestamp:"test",scenario:"default",sequence:0,capture_sequence:0}] +
                     (if $hex2 == "" then [] else [{response_hex:$hex2,rc:0,timestamp:"test",scenario:"roaming",sequence:0,capture_sequence:0}] end))}' \
        > "$dir/AT_CGSN.json"
}

write_fixture qualcomm RM500Q-AE rm500q-ae-9f94df3c \
    $'AT+CGSN\r\r\n860000000000012\r\n\r\nOK\r\n' \
    $'AT+CGSN\r\r\n860000000000013\r\n\r\nOK\r\n'
write_fixture unisoc UDX710 udx710-861f4136 $'UNISOC\r\nOK\r\n'
mkdir -p "$test_root/testcases/quectel/qualcomm/rm500q-ae-9f94df3c/expected/default"
mkdir -p "$test_root/testcases/quectel/qualcomm/rm500q-ae-9f94df3c/expected/roaming"
jq -n '{result:{},imei:"860000000000012"}' \
    > "$test_root/testcases/quectel/qualcomm/rm500q-ae-9f94df3c/expected/default/get_imei.json"
jq -n '{result:{},imei:"860000000000013"}' \
    > "$test_root/testcases/quectel/qualcomm/rm500q-ae-9f94df3c/expected/roaming/get_imei.json"

output=$(QMODEM_TEST_REPO_ROOT="$test_root" "$PACKAGE_DIR/tests/test_vendor_fixtures.sh")
printf '%s\n' "$output" | grep -q 'quectel/qualcomm/rm500q-ae-9f94df3c/default: replay passed'
printf '%s\n' "$output" | grep -q 'qualcomm/rm500q-ae-9f94df3c/default: get_imei matches golden snapshot'
printf '%s\n' "$output" | grep -q 'qualcomm/rm500q-ae-9f94df3c/roaming: get_imei matches golden snapshot'
printf '%s\n' "$output" | grep -q 'quectel/unisoc/udx710-861f4136/default: replay passed'

echo 'fixture profile isolation tests passed'
