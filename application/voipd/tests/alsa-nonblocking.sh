#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/sys/2-1/2-1:1.6/sound/card3" "$tmp/sys/3-1" "$tmp/proc"
for slot in 2-1 3-1; do
 echo 2c7c > "$tmp/sys/$slot/idVendor"
 echo 0801 > "$tmp/sys/$slot/idProduct"
 echo RM520N-GL > "$tmp/sys/$slot/product"
done
echo '03-00: USB Audio : playback 1 : capture 1' > "$tmp/proc/pcm"
${CC:-cc} -DQMODEM_VOIP_HOST_TEST -std=c11 -Wall -Wextra -Werror -ffunction-sections \
 -I"$root/src" -c "$root/src/media_core.c" -o "$tmp/core.o"
${CC:-cc} -std=c11 -Wall -Wextra -Werror -ffunction-sections \
 -I"$root/src" "$root/tests/alsa-nonblocking-fixture.c" "$root/src/media_alsa.c" \
 "$tmp/core.o" -Wl,--gc-sections -Wl,--wrap=snd_pcm_readi -Wl,--wrap=snd_pcm_writei -Wl,--wrap=snd_pcm_open \
 -lasound -lm -pthread -o "$tmp/test"
"$tmp/test" "$tmp/sys" "$tmp/proc"
echo 'PASS: UAC slot isolation and partial nonblocking capture/playback across EAGAIN'
