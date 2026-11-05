#!/bin/sh
set -eu

package_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

node "$package_dir/tests/enrollment.test.js"
node "$package_dir/tests/reducer.test.js"
node "$package_dir/tests/media.test.js"
node "$package_dir/tests/module-loader.test.js"
find "$package_dir/htdocs" -type f -name '*.js' -exec node --check {} \;
find "$package_dir" -type f -name '*.json' -exec node -e 'const fs = require("node:fs"); JSON.parse(fs.readFileSync(process.argv[1], "utf8"));' {} \;

test -f "$package_dir/htdocs/luci-static/resources/view/qmodem-voip/sip.js"
grep -q 'admin/modem/qmodem/qmodem-sipd' \
	"$package_dir/root/usr/share/luci/menu.d/luci-app-qmodem-voip.json"
grep -q "new form.Map('qmodem_sip'" \
	"$package_dir/htdocs/luci-static/resources/view/qmodem-voip/sip.js"
grep -q '"uci": \[ "network", "qmodem", "qmodem_voip", "qmodem_sip" \]' \
	"$package_dir/root/usr/share/rpcd/acl.d/luci-app-qmodem-voip.json"
! grep -q 'qmodem_sip' \
	"$package_dir/htdocs/luci-static/resources/view/qmodem-voip/call.js"

printf '%s\n' 'PASS: qmodem voip LuCI package contract'
