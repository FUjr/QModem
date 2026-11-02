'use strict';
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const path = require('path');
const source = fs.readFileSync(path.join(__dirname, '../htdocs/luci-static/resources/view/qmodem/config_advanced.js'), 'utf8');
const marker = 'qmodem.setNetworkPrefer(modem.id, selectedNetworks).then(function(result) {';
const start = source.indexOf(marker);
assert(start >= 0);
const end = source.indexOf('}).catch(function(e)', start);
assert(end > start);
let refreshed = 0;
const context = {
    _: text => text,
    E: () => ({}),
    ui: { addNotification() {} },
    self: { loadNetworkPrefer() { refreshed++; } },
    modem: {}, currentPrefValue: {}, prefSelectionField: {}, submitButton: {}
};
const callback = vm.runInNewContext('(function(result) {' + source.slice(start + marker.length, end) + '})', context);
assert.throws(() => callback({ result: { success: false, status: '+CME ERROR: 3' } }), /CME ERROR/);
assert.strictEqual(refreshed, 0);
callback({ result: { success: true, status: 'OK' } });
assert.strictEqual(refreshed, 1);
// Vendor responses without the new Fibocom flag remain compatible.
callback({ result: { status: 'OK' } });
assert.strictEqual(refreshed, 2);
console.log('PASS: failed Fibocom preference writes do not show success or refresh; legacy vendors remain compatible');
