'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const filename = path.join(__dirname, '../htdocs/luci-static/resources/qmodem-voip/enrollment.js');
const sandbox = { baseclass: { extend: value => value }, _: value => value };
vm.runInNewContext('String.prototype.format = function(x) { return this.replace("%s", x); };', sandbox);
const parser = vm.runInNewContext('(function(){' + fs.readFileSync(filename, 'utf8') + '})()', sandbox);
const input = { schema_version: 1, transport: 'tls', server: 'pbx.example.invalid', port: 5061,
 username: 'test_line', password: 'synthetic-secret-only', realm: 'asterisk', register_interval: 300,
 voip_enabled: true, sms_enabled: false, interface: 'untrusted', enabled: false };
const parsed = parser.parse(JSON.stringify(input));
assert.equal(parsed.server, input.server);
assert.equal(parsed.enabled, '1');
assert.equal(parsed.sms_enabled, '0');
assert.equal(parsed.voip_enabled, '1');
assert.equal(parsed.port, '5061');
assert.equal(parsed.interface, undefined);
assert.equal(parsed.listen_port, undefined);
assert.equal(parsed.sms_modem, undefined);
for (const change of [{ schema_version: 2 }, { transport: 'udp' }, { port: 0 }, { port: '5061' },
 { register_interval: 5 }, { password: 'short' }, { password: 'secret\ninvalid' },
 { server: 'https://example.invalid' }, { voip_enabled: '1' }, { realm: '' }])
 assert.throws(() => parser.parse(JSON.stringify({ ...input, ...change })));
for (const value of ['null', '[]', '{', 'x'.repeat(16385)]) assert.throws(() => parser.parse(value));
console.log('PASS: enrollment validation, allowlisted fields and service flag conversion');
