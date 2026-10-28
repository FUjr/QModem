#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

${CC:-cc} -DQMODEM_VOIP_HOST_TEST -std=c11 -Wall -Wextra -Werror \
	-I"$ROOT/src" "$ROOT/tests/media-profile-lifetime-fixture.c" \
	"$ROOT/src/media_core.c" "$ROOT/src/media_pcm_socket.c" -lm -pthread -o "$TMP/media-profile-lifetime"
"$TMP/media-profile-lifetime"

echo 'PASS: media release retains the selected modem recovery profile'
