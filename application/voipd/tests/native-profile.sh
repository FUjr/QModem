#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
${CC:-cc} -std=c11 -Wall -Wextra -Werror -I"$root/src" \
 "$root/tests/native-profile-fixture.c" "$root/src/modem_profile.c" -ljson-c -o "$tmp/test"
"$tmp/test" "$root/files/usr/share/qmodem_voip/modem_profiles.json" \
 "$root/files/usr/share/qmodem/modem_supports.json" "$tmp/journal"
echo 'PASS: shared RM520 capability, native selection and independent RG500 profile'
