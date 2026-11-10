#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
export QMODEM_SIP_CONFIG_DIR="$tmp/config"
export QMODEM_SIP_SHARE_DIR="$root/files/usr/share/qmodem_sip"
export QMODEM_SIP_SBIN_DIR="$root/files/usr/sbin"
export QMODEM_SIP_MIGRATE_LOCK="$tmp/lock"
export QMODEM_VOIP_JOURNAL="$tmp/journal"
migrate="$root/files/usr/sbin/qmodem_sip_migrate"
u() { uci -c "$QMODEM_SIP_CONFIG_DIR" -t "$tmp/delta" -p "$tmp/delta" "$@"; }
fingerprint() { sha256sum "$QMODEM_SIP_CONFIG_DIR/"*; }
setup() {
 rm -rf "$QMODEM_SIP_CONFIG_DIR"
 rm -f "$QMODEM_VOIP_JOURNAL"
 mkdir -p -m 700 "$QMODEM_SIP_CONFIG_DIR" "$tmp/delta"
 cat > "$QMODEM_SIP_CONFIG_DIR/qmodem" <<'EOF'
config modem-device 'modem_a'
 option name 'rm520n-gl'
 option data_interface 'usb'
 option path '/sys/bus/usb/devices/2-1/'
EOF
 cat > "$QMODEM_SIP_CONFIG_DIR/qmodem_sip" <<'EOF'
config sipd 'main'
config direction 'outbound'
 option enabled '1'
 option interface 'lan'
 option listen_port '5091'
 option server 'pbx.example.invalid'
 option port '5061'
 option username 'test-account'
 option password 'test-only-password'
 option voip_enabled '1'
 option sms_enabled '1'
 option transport 'tls'
 option realm 'test'
 option register_interval '300'
EOF
 cat > "$QMODEM_SIP_CONFIG_DIR/qmodem_voip" <<'EOF'
config main 'main'
 option enabled '1'
EOF
 cat > "$QMODEM_SIP_CONFIG_DIR/sms_forwarder" <<'EOF'
config sms_forward 'sms_forward'
 option enable '1'
config sms_forward_instance 'sip_old'
 option enable '1'
 option api_type 'sip'
 option modem_cfg 'modem_a'
 option api_config '{"direction":"outbound","recipient_uri":"sips:sms@pbx.example.invalid"}'
config sms_forward_instance 'other'
 option enable '1'
 option api_type 'webhook'
EOF
}
setup
before=$(fingerprint)
"$migrate" --status | grep -q '"status":[[:space:]]*"ready"'
[ "$(fingerprint)" = "$before" ]
"$migrate" | tee "$tmp/result" | grep -q '"status":[[:space:]]*"migrated"'
[ "$(u get qmodem_sip.sip_modem_a.modem_id)" = modem_a ]
[ "$(u get qmodem_sip.legacy_outbound.username)" = test-account ]
[ "$(u get qmodem_sip.legacy_outbound.password)" = test-only-password ]
[ "$(u get qmodem_sip.legacy_outbound.listen_port)" = 5091 ]
[ "$(u get qmodem_sip.legacy_outbound.receive_sms)" = 1 ]
[ "$(u get qmodem_sip.legacy_outbound.receive_voice)" = 1 ]
[ "$(u get qmodem_sip.outbound)" = direction ]
[ "$(u get sms_forwarder.sip_old.enable)" = 0 ]
[ "$(u get sms_forwarder.other.enable)" = 1 ]
u set qmodem_sip.legacy_outbound.password=changed-after-migration
u commit qmodem_sip
before=$(fingerprint)
"$migrate" | tee "$tmp/result" | grep -q '"status":[[:space:]]*"current"'
[ "$(fingerprint)" = "$before" ]

# Two modems without an explicit binding need a choice, never first-match binding.
setup
u delete sms_forwarder.sip_old
u commit sms_forwarder
u set qmodem.modem_b=modem-device
u set qmodem.modem_b.name=rm520n-gl
u set qmodem.modem_b.data_interface=usb
u set qmodem.modem_b.path=/sys/bus/usb/devices/3-1/
u commit qmodem
before=$(fingerprint)
"$migrate" | tee "$tmp/result" | grep -q '"status":[[:space:]]*"needs_modem"'
[ "$(fingerprint)" = "$before" ]
"$migrate" modem_b | grep -q '"status":[[:space:]]*"migrated"'
[ "$(u get qmodem_sip.sip_modem_b.modem_id)" = modem_b ]

# Two previously enabled voice endpoints retain both ringing routes.
setup
u set qmodem_sip.inbound=direction
u set qmodem_sip.inbound.enabled=1
u set qmodem_sip.inbound.username=direct-account
u set qmodem_sip.inbound.password=test-only-password
u set qmodem_sip.inbound.transport=udp_tcp
u set qmodem_sip.inbound.listen_port=5090
u set qmodem_sip.inbound.voip_enabled=1
u commit qmodem_sip
"$migrate" | tee "$tmp/result" | grep -q '"status":[[:space:]]*"migrated"'
[ "$(u get qmodem_sip.legacy_inbound.receive_voice)" = 1 ]
[ "$(u get qmodem_sip.legacy_outbound.receive_voice)" = 1 ]
[ "$(u get qmodem_sip.sip_modem_a.modem_id)" = modem_a ]
[ "$(u get qmodem_sip.legacy_inbound.listen_port)" = 5090 ]

# Different SMS destinations cannot be collapsed without losing a route.
setup
u set sms_forwarder.second=sms_forward_instance
u set sms_forwarder.second.enable=1
u set sms_forwarder.second.api_type=sip
u set sms_forwarder.second.modem_cfg=modem_a
u set 'sms_forwarder.second.api_config={"direction":"outbound","recipient_uri":"sip:other@pbx.example.invalid"}'
u commit sms_forwarder
before=$(fingerprint)
"$migrate" | tee "$tmp/result" | grep -q '"status":[[:space:]]*"conflict"'
[ "$(fingerprint)" = "$before" ]

setup
u set qmodem_sip.outbound.password=short
u commit qmodem_sip
before=$(fingerprint)
"$migrate" | tee "$tmp/result" | grep -q '"status":[[:space:]]*"invalid"'
[ "$(fingerprint)" = "$before" ]

# The oldest combined voice/SIP configuration follows the same single transaction.
setup
cp "$root/files/etc/config/qmodem_sip" "$QMODEM_SIP_CONFIG_DIR/qmodem_sip"
u set qmodem_voip.sip=sip
u set qmodem_voip.sip.mode=outbound
u set qmodem_voip.sip.enabled=1
u set qmodem_voip.sip.outbound_server=pbx.example.invalid
u set qmodem_voip.sip.outbound_port=5061
u set qmodem_voip.sip.outbound_username=oldest-account
u set qmodem_voip.sip.outbound_password=test-only-password
u commit qmodem_voip
"$migrate" | tee "$tmp/result" | grep -q '"status":[[:space:]]*"migrated"'
[ "$(u get qmodem_sip.legacy_outbound.username)" = oldest-account ]
[ "$(u get qmodem_voip.sip.mode)" = outbound ]

# A failed final publication leaves the original configuration byte-for-byte intact.
setup
before=$(fingerprint)
mkdir "$tmp/bin"
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/mv"
chmod 700 "$tmp/bin/mv"
if PATH="$tmp/bin:$PATH" "$migrate" >/dev/null; then exit 1; fi
[ "$(fingerprint)" = "$before" ]
# The deployed connection schema also used version 2: inspect section types.
setup
u set qmodem_sip.main.schema_version=2
u set qmodem_sip.outbound=connection
u set qmodem_sip.outbound.direction=outbound
u set qmodem_sip.outbound.modem_id=modem_a
u set qmodem_sip.outbound.receive_voice=1
u set qmodem_sip.outbound.send_voice=0
u set qmodem_sip.outbound.receive_sms=1
u set qmodem_sip.outbound.sms_recipient_uri=sips:sms@pbx.example.invalid
u commit qmodem_sip
"$migrate" | grep -q '"status":[[:space:]]*"migrated"'
[ "$(u get qmodem_sip.outbound)" = direction ]
[ "$(u get qmodem_sip.outbound.group)" = sip_modem_a ]
[ "$(u get qmodem_sip.outbound.send_voice)" = 0 ]
[ "$(u get qmodem_sip.outbound.receive_voice)" = 1 ]
[ "$(u get qmodem_sip.main.schema_version)" = 3 ]
[ "$(u get qmodem_voip.sip_modem_a.modem_id)" = modem_a ]
[ "$(u get qmodem.modem_a.sms_mode)" = database_poll ]

# Main's group schema keeps its custom group identity and adopts old SMS routes.
setup
u set qmodem_sip.main.schema_version=2
u set qmodem_sip.custom=group
u set qmodem_sip.custom.modem_id=modem_a
u set qmodem_sip.outbound.group=custom
u set qmodem_sip.outbound.direction=outbound
u delete qmodem_sip.outbound.enabled
u commit qmodem_sip
"$migrate" | grep -q '"status":[[:space:]]*"migrated"'
[ "$(u get qmodem_sip.outbound.group)" = custom ]
[ "$(u get qmodem_sip.outbound.receive_sms)" = 1 ]
[ "$(u get qmodem_sip.outbound.receive_voice)" = 1 ]
before=$(fingerprint)
"$migrate" | grep -q '"status":[[:space:]]*"current"'
[ "$(fingerprint)" = "$before" ]

# SMS-only installations must not acquire empty optional-package configs.
setup
rm "$QMODEM_SIP_CONFIG_DIR/qmodem_voip" "$QMODEM_SIP_CONFIG_DIR/sms_forwarder"
u set qmodem_sip.outbound.voip_enabled=0
u set qmodem_sip.outbound.modem_id=modem_a
u commit qmodem_sip
"$migrate" | grep -q '"status":[[:space:]]*"migrated"'
[ ! -e "$QMODEM_SIP_CONFIG_DIR/qmodem_voip" ]
[ ! -e "$QMODEM_SIP_CONFIG_DIR/sms_forwarder" ]

echo 'PASS: staged legacy migrations, binding selection, route conflict, validation, idempotency and publication failure'
