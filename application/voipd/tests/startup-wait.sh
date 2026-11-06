#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

grep -q -- 'procd_set_param command /usr/sbin/qmodem_voip_daemon_wait' \
	"$ROOT/files/etc/init.d/qmodem_voip"
grep -q -- '--media-interface "$interface"' "$ROOT/files/etc/init.d/qmodem_voip"
grep -q -- '--start-enabled "$enabled"' "$ROOT/files/etc/init.d/qmodem_voip"
grep -q 'enabled=$(uci -q get qmodem_voip.main.enabled)' "$ROOT/files/etc/init.d/qmodem_voip"
grep -A1 "config main 'main'" "$ROOT/files/etc/config/qmodem_voip" |
	grep -q "option enabled '0'"
grep -q "option web_enabled '0'" "$ROOT/files/etc/config/qmodem_voip"
grep -q 'qmodem_voip_web' "$ROOT/files/etc/init.d/qmodem_voip"
grep -q 'qmodem_voip_https' "$ROOT/files/usr/sbin/qmodem_voip_web"
grep -q 'case " $listeners " in' "$ROOT/files/usr/sbin/qmodem_voip_web"
grep -q "web_enabled" "$ROOT/../../luci/luci-app-qmodem-voip/htdocs/luci-static/resources/view/qmodem-voip/call.js"
grep -q 'revision = app->call.revision' "$ROOT/src/media_manager.c"
if grep -q '\[ -n "$lan_address" \] || return 0' "$ROOT/files/etc/init.d/qmodem_voip"; then
	echo 'FAIL: daemon startup still exits when the interface address is late' >&2
	exit 1
fi
grep -q 'qmodem_voip_wait_interface_address' \
	"$ROOT/files/usr/sbin/qmodem_voip_daemon_wait"
grep -q -- '--media-address "$media_address"' \
	"$ROOT/files/usr/sbin/qmodem_voip_daemon_wait"
grep -q 'remaining=120' "$ROOT/files/usr/sbin/qmodem_voip_daemon_wait"
grep -q '\[ "$start_enabled" = 0 \] || \. /usr/lib/qmodem_voip/at_daemon_adapter.sh' \
	"$ROOT/files/usr/sbin/qmodem_voip_daemon_wait"
if grep -q 'qmodem_voip_modem_safety\|prepare_adb\|install-media-gate' \
	"$ROOT/files/usr/sbin/qmodem_voip_daemon_wait"; then
	echo 'FAIL: passive daemon wait path still mutates modem state' >&2
	exit 1
fi
if grep -q 'qmodem_voip_recover_startup' "$ROOT/files/etc/init.d/qmodem_voip"; then
	echo 'FAIL: blocking modem recovery remains in the procd registration path' >&2
	exit 1
fi
if grep -q 'install-media-gate' "$ROOT/src/adb_unlock.c" ||
   grep -q 'libqvoice_media_gate' "$ROOT/Makefile"; then
	echo 'FAIL: PCM patch is still built or installable' >&2
	exit 1
fi
if grep -q 'qmodem_voip_prepare_adb\|qmodem_voip_prepare_media_gate' "$ROOT/src/main.c"; then
	echo 'FAIL: daemon startup still unlocks ADB or installs the media gate' >&2
	exit 1
fi
grep -q 'set_application_enabled(1)' "$ROOT/src/daemon_core.c"
grep -q 'set_application_enabled(0)' "$ROOT/src/daemon_core.c"
grep -q 'qmodem_voip_prepare_adb(&app->media.profile)' "$ROOT/src/daemon_core.c"
grep -q 'uloop_timeout_set(&app->browser_timer, 20)' "$ROOT/src/daemon_core.c"
if grep -q '91-qmodem-voip-https' "$ROOT/Makefile"; then
	echo 'FAIL: package install still owns uhttpd HTTPS configuration' >&2
	exit 1
fi
[ ! -e "$ROOT/files/etc/uci-defaults/91-qmodem-voip-https" ] || {
	echo 'FAIL: uhttpd-mutating defaults script remains in the package source' >&2
	exit 1
}

echo 'PASS: qmodem voip feature-gated startup contract'
