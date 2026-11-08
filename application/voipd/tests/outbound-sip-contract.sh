#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SIP_ROOT="$ROOT/../qmodem_sipd"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/etc/config"
cat >"$TMP/bin/uci" <<'EOF'
#!/bin/sh
key=$3
case "$key" in
qmodem_sip.outbound.group) printf '%s\n' first ;;
qmodem_sip.first) printf '%s\n' group ;;
qmodem_sip.first.modem_id) printf '%s\n' m1 ;;
qmodem.m1) printf '%s\n' modem-device ;;
qmodem_sip.outbound.direction) printf '%s\n' outbound ;;
qmodem_sip.outbound.voip_enabled) printf '%s\n' 1 ;;
qmodem_sip.outbound.listen_port) printf '%s\n' 5061 ;;
qmodem_sip.outbound.rtp_start) printf '%s\n' 40000 ;;
qmodem_sip.outbound.realm) printf '%s\n' example ;;
qmodem_sip.outbound.register_interval) printf '%s\n' 300 ;;
qmodem_sip.*.interface) printf '%s\n' wan ;;
qmodem_sip.*.sms_enabled) printf '%s\n' 0 ;;
qmodem_sip.outbound.server) printf '%s\n' "${QMODEM_SERVER:-pbx.example.net}" ;;
qmodem_sip.outbound.port) printf '%s\n' "${QMODEM_PORT:-5061}" ;;
qmodem_sip.outbound.transport) printf '%s\n' "${QMODEM_TRANSPORT:-tls}" ;;
qmodem_sip.outbound.username) printf '%s\n' "${QMODEM_USER:-u}" ;;
qmodem_sip.outbound.password) printf '%s\n' "${QMODEM_PASS:-synthetic-test-password}" ;;
esac
EOF
chmod +x "$TMP/bin/uci"

PATH="$TMP/bin:$PATH" "$SIP_ROOT/files/usr/sbin/qmodem_voip_sip_validate" outbound
QMODEM_SERVER='bad value' PATH="$TMP/bin:$PATH" \
	"$SIP_ROOT/files/usr/sbin/qmodem_voip_sip_validate" outbound >/dev/null 2>&1 && exit 1 || :

grep -q 'pjsip_auth_clt_reinit_req' "$SIP_ROOT/src/sip_consumer.c"
grep -q 'send_outbound_ack' "$SIP_ROOT/src/sip_consumer.c"
grep -q 'pjsip_tx_data_set_transport(ack, &selector)' \
	"$SIP_ROOT/src/sip_consumer.c"
grep -q 'app.outbound ? "sips" : "sip"' "$SIP_ROOT/src/sip_consumer.c"
grep -q 'qmodem.sip.%s' "$SIP_ROOT/src/sip_consumer.c"
echo 'PASS: outbound SIP topology validation accepts TLS and rejects unsafe values'
