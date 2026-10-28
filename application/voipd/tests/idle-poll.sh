#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

${CC:-cc} -std=c11 -Wall -Wextra -Werror \
	-I"$ROOT/src" \
	"$ROOT/tests/idle-poll-fixture.c" "$ROOT/src/at_direct.c" "$ROOT/src/call_state.c" \
	-o "$BUILD_DIR/idle-poll"
"$BUILD_DIR/idle-poll"

echo 'PASS: direct idle call polling and endpoint names'
