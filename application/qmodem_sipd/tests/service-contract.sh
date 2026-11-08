#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
REPO=$(CDPATH= cd -- "$ROOT/../.." && pwd)
VOIP="$REPO/application/voipd"
SMSD="$REPO/application/qmodem_smsd"
FORWARDER="$REPO/application/sms_forwarder_next"
LUCI="$REPO/luci/luci-app-qmodem-sipd"

"$ROOT/tests/registration-retry.sh"

test -f "$ROOT/files/etc/init.d/qmodem_voip_sipd"
test -f "$ROOT/files/etc/config/qmodem_sip"
test -x "$ROOT/files/etc/uci-defaults/89-qmodem-sip-migrate"
grep -q 'qmodem.sip.%s.%s' "$ROOT/src/sip_consumer.c"
grep -q 'object.name = "qmodem.sip"' "$ROOT/src/sip_control.c"
grep -q 'ubus_lookup_id(context, "qmodem_voip"' "$ROOT/src/sip_control.c"
grep -q 'ubus_lookup_id(context, "qmodem.sms"' "$ROOT/src/sip_control.c"
grep -q '"send_managed"' "$ROOT/src/sip_consumer.c"
grep -q 'standard logical return URI' "$ROOT/src/sip_consumer.c"
grep -q 'add_string_header(tx, "Reply-To"' "$ROOT/src/sip_consumer.c"
grep -q 'name = "remote_number"' "$ROOT/src/sip_consumer.c"
grep -q 'add_string_header(request, "P-Asserted-Identity"' \
	"$ROOT/src/sip_consumer.c"
grep -q 'from = pj_str(local_uri)' "$ROOT/src/sip_consumer.c"
grep -q 'schedule_outbound_register_retry' "$ROOT/src/sip_consumer.c"
grep -q '"registration_attempts"' "$ROOT/src/sip_consumer.c"
grep -q '"retry_scheduled"' "$ROOT/src/sip_consumer.c"

grep -q 'UBUS_METHOD("send_managed"' "$SMSD/src/main.c"
grep -q 'managed send requires database mode' "$SMSD/src/main.c"
grep -q 'managed_sends' "$SMSD/src/sms_db.c"
grep -q "conn.call('qmodem.sip', 'send_message'" \
	"$FORWARDER/files/sms_forwarder_next"
grep -q "api_type == 'sip'" "$FORWARDER/files/sms_forwarder_next"
grep -q 'SIP forwarding failed:' "$FORWARDER/files/sms_forwarder_next"
grep -q '\.name = "recipient_uri"' "$ROOT/src/sip_control.c"
grep -q '\.name = "content"' "$ROOT/src/sip_control.c"
grep -q '\.name = "message_id"' "$ROOT/src/sip_control.c"

! find "$VOIP/src" -maxdepth 1 -name 'sip_*' -print -quit | grep -q .
! grep -q 'qmodem_voip_sip_consumer' "$VOIP/Makefile"

"$ROOT/tests/multi-service.sh"
grep -q 'config_foreach start_direction direction' "$ROOT/files/etc/init.d/qmodem_sipd"
grep -q 'procd_add_interface_trigger' "$ROOT/files/etc/init.d/qmodem_sipd"
! grep -q 'qmodem_voip_sip_wait' "$ROOT/files/etc/init.d/qmodem_sipd"
grep -q 'qmodem_voip.sip.outbound_server' \
	"$ROOT/files/etc/uci-defaults/89-qmodem-sip-migrate"
grep -q 'delete qmodem_voip.sip' \
	"$ROOT/files/etc/uci-defaults/89-qmodem-sip-migrate"

test -f "$LUCI/htdocs/luci-static/resources/view/qmodem-sipd/sip.js"
grep -q 'admin/modem/qmodem/qmodem-sipd' \
	"$LUCI/root/usr/share/luci/menu.d/luci-app-qmodem-sipd.json"
grep -q "new form.Map('qmodem_sip'" \
	"$LUCI/htdocs/luci-static/resources/view/qmodem-sipd/sip.js"
grep -q 'message_context=qmodem-message' \
	"$REPO/docs/wiki/SIP-SMS-VoIP-Configuration.zh-cn.md"
grep -q 'MESSAGE_DATA(X-QModem-SMS-From)' \
	"$REPO/docs/wiki/SIP-SMS-VoIP-Configuration.zh-cn.md"
grep -Fq 'MessageSend(pjsip:PJSIP/${EXTEN}@qmodem1001)' \
	"$REPO/docs/wiki/SIP-SMS-VoIP-Configuration.zh-cn.md"

echo 'PASS: independent SIP, VoIP/SMS integration, and managed SMS contracts'
