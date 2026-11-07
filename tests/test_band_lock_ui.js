'use strict';
// Execute the production legacy LuCI class with a minimal DOM-free base.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../luci/luci-app-qmodem/luasrc/view/qmodem/modem_debug.htm'), 'utf8');
const start = source.indexOf('class Lockband extends ModemConfig');
const end = source.indexOf('class RatPrefer extends ModemConfig', start);
const alerts = [];
const context = vm.createContext({
  ModemConfig: class {}, window: { alert: text => alerts.push(text) },
  console: { log() {} }
});
vm.runInContext(source.slice(start, end).replace(/<%:([^%]*)%>/g, '$1') + '\nglobalThis.Lockband = Lockband;', context);
const Lockband = context.Lockband;
Lockband.prototype.init_table = function() {};
const ui = new Lockband('test');
const sent = [];
ui.set_config = payload => sent.push(JSON.parse(payload));
ui.config = { NR: { allow_empty: false } };
ui.lockband_config.NR = [];
ui.submit('NR');
assert.equal(sent.length, 0);
assert.match(alerts.pop(), /at least one band/);
ui.lockband_config.NR = ['78', '3', '1'];
ui.submit('NR');
assert.equal(sent[0].lock_band, '1,3,78');
assert.equal(ui.lockband_config.NR.join(','), '78,3,1');
let reads = 0;
ui.get_config = () => reads++;
ui.cb_set({ result: { success: false, error: 'Rejected', set_lockband: '+CME ERROR: 4' } });
assert.equal(reads, 0);
assert.match(alerts.pop(), /Rejected\n\+CME ERROR: 4/);
ui.cb_set(null);
assert.equal(reads, 0);
assert.match(alerts.pop(), /Failed/);
ui.cb_set({ result: { success: true } });
assert.equal(reads, 1);
// Older non-Quectel backends do not expose the new success flag.
ui.cb_set({ result: { set_lockband: 'OK' } });
assert.equal(reads, 2);
for (const result of [{}, {status: 'error', set_lockband: 'Rejected'}, {set_lockband: 'ERROR'}]) {
  ui.cb_set({result});
  assert.equal(reads, 2);
  assert.ok(alerts.pop());
}
ui.config.NR = {};
ui.lockband_config.NR = [];
ui.submit('NR');
assert.equal(sent.at(-1).lock_band, ''); // other vendors retain empty-list reset
console.log('Legacy band UI: empty-submit guard, numeric sort, rejection and success checks passed');

async function testNext() {
  const source = fs.readFileSync(path.join(__dirname, '../luci/luci-app-qmodem-next/htdocs/luci-static/resources/view/qmodem/config_advanced.js'), 'utf8');
  const start = source.indexOf("var applyBtn = E('button'");
  const end = source.indexOf('buttonField.appendChild(selectAllBtn)', start);
  const state = { NR: { locked: [] } };
  const bandData = { allow_empty: false };
  const notifications = [];
  let calls = 0, reads = 0, answer;
  const ctx = vm.createContext({
    bandData, lockbandState: state, bandClass: 'NR', modem: { id: 'test' }, lockbandContent: {},
    E: (tag, attrs, text) => ({ tag, attrs, text }), _: value => value,
    ui: { addNotification: (unused, message, type) => notifications.push({ message, type }) },
    self: { loadLockBand() { reads++; } },
    qmodem: { setLockBand() { calls++; return Promise.resolve(answer); } }
  });
  vm.runInContext("String.prototype.format = function(value) { return this.replace('%s', value); };" + source.slice(start, end), ctx);
  const button = ctx.applyBtn;
  const flush = () => new Promise(resolve => setImmediate(resolve));
  button.attrs.click();
  assert.equal(calls, 0);
  assert.match(notifications.pop().message.attrs, /at least one band/);
  state.NR.locked = ['78'];
  answer = { result: { success: false, error: 'Rejected', set_lockband: 'ERROR' } };
  button.attrs.click(); await flush();
  assert.equal(reads, 0);
  assert.equal(button.disabled, false);
  assert.equal(notifications.at(-1).type, 'error');
  assert.match(notifications.pop().message.attrs, /Rejected\nERROR/);
  answer = { result: { success: true } };
  button.attrs.click(); await flush();
  assert.equal(reads, 1);
  assert.equal(notifications.at(-1).type, 'success');
  for (const result of [{}, {status: 'error', set_lockband: 'Rejected'}, {set_lockband: 'ERROR'}]) {
    answer = {result};
    button.attrs.click(); await flush();
    assert.equal(reads, 1);
    assert.equal(notifications.pop().type, 'error');
  }
  bandData.allow_empty = undefined;
  state.NR.locked = [];
  answer = {result: {set_lockband: 'OK'}};
  const previousCalls = calls;
  button.attrs.click(); await flush();
  assert.equal(calls, previousCalls + 1);
  assert.equal(notifications.pop().type, 'success');
  console.log('Next band UI: empty-submit guard, rejection and success checks passed');
}
testNext().catch(error => { console.error(error); process.exitCode = 1; });
