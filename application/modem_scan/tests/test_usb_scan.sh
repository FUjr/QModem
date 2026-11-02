#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT INT TERM
SLOT="$BUILD/sys/bus/usb/devices/4-1"
mkdir -p "$SLOT"
printf '2dee\n' > "$SLOT/idVendor"
printf '4d23\n' > "$SLOT/idProduct"
for entry in '1.0 option ttyUSB0' '1.1 option ttyUSB1' '1.4 option ttyUSB4' \
             '1.5 cdc_ether net/usb0' '1.6 unsupported net/ignored' \
             '1.7 cdc_ether net/.hidden'; do
    set -- $entry
    mkdir -p "$SLOT/4-1:$1/$3"
    mkdir -p "$BUILD/drivers/$2"
    ln -s "$BUILD/drivers/$2" "$SLOT/4-1:$1/driver"
done
# Another slot's interface must never leak into this slot's result.
mkdir -p "$SLOT/4-10:1.5/net/foreign"
ln -s "$BUILD/drivers/cdc_ether" "$SLOT/4-10:1.5/driver"
${CC:-cc} -std=c99 -D_GNU_SOURCE -Wall -Wextra ${CPPFLAGS:-} ${CFLAGS:-} \
    -DQMODEM_SYSFS_ROOT=\""$BUILD/sys"\" "$ROOT/tests/test_usb_scan.c" ${LDFLAGS:-} -ljson-c -lpthread -o "$BUILD/test-usb"
"$BUILD/test-usb"
