#!/usr/bin/env bash
# A command consumes ordered responses within one scenario without leaking state.
set -u

TESTS_DIR=$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FIXTURE_LOOKUP=$(mktemp -d)
trap 'rm -rf "$FIXTURE_LOOKUP"' EXIT

command='AT+STATE?'
hash=$(printf '%s' "$command" | md5sum | cut -c1-8)
mkdir -p "$FIXTURE_LOOKUP/$hash.responses/registered" \
    "$FIXTURE_LOOKUP/$hash.responses/sim-absent" "$FIXTURE_LOOKUP/cursors"
printf 'REGISTERING\r\n' > "$FIXTURE_LOOKUP/$hash.responses/registered/0.response"
printf 'REGISTERED\r\n' > "$FIXTURE_LOOKUP/$hash.responses/registered/1.response"
printf 'NO SIM\r\n' > "$FIXTURE_LOOKUP/$hash.responses/sim-absent/0.response"
printf '0\n' > "$FIXTURE_LOOKUP/$hash.responses/registered/0.rc"
printf '0\n' > "$FIXTURE_LOOKUP/$hash.responses/registered/1.rc"
printf '3\n' > "$FIXTURE_LOOKUP/$hash.responses/sim-absent/0.rc"

export FIXTURE_LOOKUP
. "$TESTS_DIR/lib/at_fixture.sh"

FIXTURE_SCENARIO=registered
export FIXTURE_SCENARIO
[ "$(at /dev/null "$command")" = $'REGISTERING\r' ]
[ "$(at /dev/null "$command")" = $'REGISTERED\r' ]
at /dev/null "$command" >/dev/null 2>&1
[ "$?" -eq 127 ]

rm -f "$FIXTURE_LOOKUP/cursors/$hash"
FIXTURE_SCENARIO=sim-absent
export FIXTURE_SCENARIO
output=$(at /dev/null "$command")
rc=$?
[ "$output" = $'NO SIM\r' ]
[ "$rc" -eq 3 ]

echo 'fixture response queue tests passed'
