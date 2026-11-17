#!/bin/sh
set -eu
. "$(dirname "$0")/../root/usr/share/qmodem-uplink/core.sh"
UP_FAIL=3 UP_RECOVER=3 UP_STABLE=60
s=$(up_health null true true 0)
[ "$(echo "$s" | jq .healthy)" = true ]
s=$(up_health "$s" false true 10); [ "$(echo "$s" | jq .healthy)" = true ]
s=$(up_health "$s" false true 20); [ "$(echo "$s" | jq .healthy)" = true ]
s=$(up_health "$s" false true 30); [ "$(echo "$s" | jq .healthy)" = false ]
s=$(up_health "$s" true true 40)
s=$(up_health "$s" true true 50)
s=$(up_health "$s" true true 60); [ "$(echo "$s" | jq .healthy)" = false ]
s=$(up_health "$s" true true 100); [ "$(echo "$s" | jq .healthy)" = true ]
s=$(up_health "$s" true false 101); [ "$(echo "$s" | jq .healthy)" = false ]
# Stability restarts after a single failed round, even after enough successes.
s=$(up_health "$s" true true 102)
s=$(up_health "$s" false true 150)
s=$(up_health "$s" true true 160)
s=$(up_health "$s" true true 170)
s=$(up_health "$s" true true 180); [ "$(echo "$s" | jq .healthy)" = false ]
echo 'PASS: first admission, three failures, stable recovery, immediate removal'
