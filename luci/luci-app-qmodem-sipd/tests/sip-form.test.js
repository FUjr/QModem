'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const data = { qmodem_sip: { main: {} }, qmodem_voip: {main:{}} };
const uci = {
 get(c, s, o) { return o ? data[c]?.[s]?.[o] : data[c]?.[s]; },
 add(c, t, s) { data[c][s] = { '.type': t }; return s; },
 set(c, s, o, v) { data[c][s][o] = v; },
 sections(c, type) {
  if (c === 'qmodem') return [{ '.name': 'modem_a' }, { '.name': 'modem_b' }];
  if (c !== 'qmodem_sip' && c !== 'qmodem_voip') return [];
  return Object.entries(data[c]).filter(([, v]) => v['.type'] === type).map(([id, v]) => ({ '.name': id, ...v }));
 }
};
class Option { depends() {} value() {} }
class Section {
 constructor() { this.options = []; this.tabs = []; }
 option(type, name) { const o = new Option(); o.name = name; this.options.push(o); return o; }
 tab(name) { this.tabs.push(name); }
 taboption(tab, type, name) { const o = this.option(type, name); if (type === 'section') o.subsection = new Section(); return o; }
}
class FormMap {
 constructor() { this.sections = []; }
 section() { const s = new Section(); this.sections.push(s); return s; }
 chain() {}
 async parse() {}
}
const form = { Map: FormMap, NamedSection: Section, SectionValue: 'section' };
const sandbox = { form, uci, view: { extend: x => x }, E() {}, rpc: {declare: () => () => ({})}, _: x => x };
const file = path.join(__dirname, '../htdocs/luci-static/resources/view/qmodem-sipd/sip.js');
const view = vm.runInNewContext('(function(){' + fs.readFileSync(file, 'utf8') + '})()', sandbox);
function reset() {
 data.qmodem_sip = { main: {} };
 data.qmodem_voip = {main:{}};
 for (const modem of ['a', 'b']) data.qmodem_sip['sip_modem_' + modem] = { '.type': 'group', modem_id: 'modem_' + modem };
 for (const modem of ['a', 'b']) for (const direction of ['inbound', 'outbound']) {
  data.qmodem_sip[modem + '_' + direction] = { '.type': 'direction', group: 'sip_modem_' + modem, direction, server: direction === 'outbound' ? 'sip.example.invalid' : '',
   username: 'account_' + modem, password: 'test-only-password', receive_voice: '1', send_voice: '1', receive_sms: '1' };
 }
}
(async () => {
 reset();
 const map = view.createMap();
 assert.deepEqual(Array.from(map.sections[0].tabs), ['connections', 'voice', 'sms', 'advanced']);
 await map.parse();
 assert.equal(data.qmodem_sip.a_inbound.transport, 'udp_tcp');
 assert.equal(data.qmodem_voip.sip_modem_a.modem_id, 'modem_a');
 assert.equal(data.qmodem_sip.b_outbound.transport, 'tls');
 data.qmodem_sip.b_outbound.username = 'account_a';
 await assert.rejects(map.parse(), /independent SIP accounts/);
 reset(); data.qmodem_sip.sip_modem_a.modem_id = '';
 await assert.rejects(map.parse(), /one direct and one external/);
 reset(); data.qmodem_sip.extra = { ...data.qmodem_sip.a_inbound };
 await assert.rejects(map.parse(), /one direct and one external/);
 reset(); data.qmodem_sip.a_inbound.listen_port = data.qmodem_sip.b_inbound.listen_port = '5070';
 await assert.rejects(map.parse(), /ports must be unique/);
 reset(); data.qmodem_sip.a_outbound.password = 'bad\nserver=evil';
 await assert.rejects(map.parse(), /printable characters/);
 console.log('PASS: unified tabs, two modem accounts, shared voice and SMS routes and invalid route rejection');
})().catch(e => { console.error(e); process.exitCode = 1; });
