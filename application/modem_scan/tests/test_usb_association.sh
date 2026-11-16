#!/bin/sh
set -eu
test_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
QMODEM_TEST_ROOT="$(mktemp -d)"
export QMODEM_TEST_ROOT
trap 'rm -rf "$QMODEM_TEST_ROOT"' EXIT HUP INT TERM
mkdir -p "$QMODEM_TEST_ROOT/bin" "$QMODEM_TEST_ROOT/sys/bus/pci/devices"
cat > "$QMODEM_TEST_ROOT/bin/uci" <<'EOF'
#!/bin/sh
case "$2:$3" in
show:qmodem) echo "qmodem.pcie0.associated_usb='2-1'" ;;
get:qmodem.pcie0.type) echo pcie ;;
get:qmodem.pcie0.slot) echo 0000:01:00.0 ;;
*) exit 1 ;;
esac
EOF
chmod +x "$QMODEM_TEST_ROOT/bin/uci"
export PATH="$QMODEM_TEST_ROOT/bin:$PATH"
${CC:-cc} -std=c99 -D_GNU_SOURCE ${CFLAGS:-} "$test_dir/test_usb_association.c" \
    -o "$QMODEM_TEST_ROOT/test" ${LDFLAGS:--ljson-c} -lpthread
"$QMODEM_TEST_ROOT/test"
