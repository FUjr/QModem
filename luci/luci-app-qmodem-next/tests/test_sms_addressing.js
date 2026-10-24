'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const root = path.join(__dirname, '../htdocs/luci-static/resources/qmodem');
const L = { Class: { extend: value => value } };
const identity = value => value;
const smsNumber = new Function('L', fs.readFileSync(path.join(root, 'sms-number.js'), 'utf8'))(L);
const pduParser = new Function('L', fs.readFileSync(path.join(root, 'sms-pdu.js'), 'utf8'))(L);

const cases = [
	['2025550123', '', '2025550123'],
	['(202) 555-0123', '1', '+12025550123'],
	['7911123456', '+44', '+447911123456'],
	['15123456789', '49', '+4915123456789'],
	['9876543210', '91', '+919876543210'],
	['13800138000', '86', '+8613800138000'],
	['+1 (202) 555-0123', '44', '+12025550123'],
	['0201234567', '44', '+440201234567'], // no country-specific trunk removal
	['0012025550123', '', '0012025550123'], // no access-prefix guessing
	['12345', '', '12345'],
	['2025550123', '  ', '2025550123']
];

function destination(pdu) {
	assert(/^[0-9a-f]+$/i.test(pdu), 'PDU must contain hex only');
	const data = Buffer.from(pdu, 'hex');
	const start = data[0] + 3;
	let digits = '';
	for (let i = 0; i < data[start]; i++) {
		const octet = data[start + 2 + Math.floor(i / 2)];
		digits += String(i % 2 ? octet >> 4 : octet & 15);
	}
	return { number: (data[start + 1] === 0x91 ? '+' : '') + digits, toa: data[start + 1] };
}

function testNumbersAndPdus() {
	const template = fs.readFileSync(path.join(__dirname, '../../luci-app-qmodem-sms/luasrc/view/modem_sms/modem_sms.htm'), 'utf8');
	const legacySource = template.slice(template.indexOf('var pduParser'), template.indexOf('class ModemSMS'));
	const legacy = new Function(legacySource + '\nreturn { pduParser, normalize, normalizeCode };')();
	for (const [number, code, expected] of cases) {
		assert.strictEqual(smsNumber.normalize(number, code), expected);
		assert.strictEqual(legacy.normalize(number, code), expected);
		for (const parser of [pduParser, legacy.pduParser]) {
			for (const text of ['hello', '短信', 'A'.repeat(80)]) {
				const pdus = parser.generate({ receiver: expected, text, encoding: '16bit' });
				assert(pdus.length > 0);
				for (const pdu of pdus) assert.deepStrictEqual(destination(pdu), {
					number: expected, toa: expected.startsWith('+') ? 0x91 : 0x81
				});
			}
		}
	}
	for (const number of ['', '+', '++123', '+0123', '12+34', '12x34', '１２３', '123\n', '+1234567890123456', '123456789012345678901']) {
		assert.throws(() => smsNumber.normalize(number, ''));
		assert.throws(() => pduParser.generate({ receiver: number, text: 'test', encoding: '16bit' }));
	}
	for (const code of ['+', '0', '01', '1234', '+1234', 'x', '1;id'])
		assert.throws(() => smsNumber.normalizeCode(code));
	assert.throws(() => smsNumber.normalize('123456789012345', '1'));
	assert.strictEqual(smsNumber.normalizeCode('+44'), '44');
}

function testConversations() {
	const received = { id: 1, type: 'received', sender: '2025550123', timestamp: 1, is_read: false };
	const international = { id: 2, type: 'sent', recipient: '+12025550123', timestamp: 2 };
	assert.strictEqual(smsNumber.conversations([received, international]).length, 2,
		'no suffix matching without an explicit reply');
	const reply = { ...international, conversation_contact: received.sender };
	let groups = smsNumber.conversations([received, reply]);
	assert.strictEqual(groups.length, 1);
	assert.strictEqual(groups[0].contact, international.recipient);
	assert.strictEqual(groups[0].unread_count, 1);
	assert.deepStrictEqual(groups[0].messages.map(m => m.id), [1, 2]);
	assert.strictEqual(smsNumber.conversations([
		international, { ...received, sender: '12025550123' }
	]).length, 1, 'same complete digits with and without + share a conversation');
	groups = smsNumber.conversations([received, reply,
		{ ...reply, id: 3, recipient: '+442025550123', timestamp: 3 }]);
	assert.strictEqual(groups.length, 3, 'conflicting explicit associations remain separate');
	assert.strictEqual(smsNumber.conversations([
		{ ...received, sender: 'BANK' }, { ...received, sender: 'OTHER' }
	]).length, 2);
}

function element(tag, attrs, children) {
	return { tag, attrs: attrs || {}, children: children || [], value: '', textContent: '',
		listeners: {}, addEventListener(name, fn) { this.listeners[name] = fn; } };
}
function descendants(node) {
	return [node].concat((Array.isArray(node.children) ? node.children : []).flatMap(child =>
		typeof child === 'object' ? descendants(child) : []));
}
const tick = () => new Promise(resolve => setImmediate(resolve));

async function testCountryCodeField() {
	const loads = [], saves = [], notifications = [];
	const service = {
		getCountryCode(modem) { return new Promise((resolve, reject) => loads.push({ modem, resolve, reject })); },
		setCountryCode(modem, code) { saves.push({ modem, code }); return Promise.resolve({}); }
	};
	const widget = new Function('L', 'smsNumber', 'smsService', 'ui', 'E', '_',
		fs.readFileSync(path.join(root, 'sms-address.js'), 'utf8'))(L, smsNumber, service,
		{ addNotification(...args) { notifications.push(args); } }, element, identity);
	let modem = 'modem_1', number = '2025550123';
	const field = widget.create(() => number, () => modem);
	const nodes = descendants(field.node);
	const code = nodes.find(n => n.tag === 'input');
	const save = nodes.find(n => n.tag === 'button');
	assert.throws(() => field.recipient(), /Loading/);
	loads[0].resolve(''); await tick();
	assert.strictEqual(code.value, '', 'new modem has no preset country code');
	assert.strictEqual(field.recipient(), number);
	code.value = '+1'; code.listeners.input();
	assert.strictEqual(field.recipient(), '+12025550123');
	assert.strictEqual(saves.length, 0, 'editing must not persist automatically');
	save.listeners.click(); await tick();
	assert.deepStrictEqual(saves, [{ modem: 'modem_1', code: '1' }]);
	code.value = ''; save.listeners.click(); await tick();
	assert.strictEqual(saves[1].code, '', 'empty country code can be saved');
	code.value = '+1'; number = '+447911123456';
	assert.strictEqual(field.recipient(), number, 'explicit international destination wins');
	modem = 'modem_2'; const second = field.load();
	modem = 'modem_3'; const third = field.load();
	loads[2].resolve('49'); await third;
	loads[1].resolve('86'); await second;
	assert.strictEqual(code.value, '+49', 'late response from another modem must be ignored');
	modem = 'modem_4'; const failed = field.load();
	loads[3].reject(new Error('offline')); await failed;
	assert.strictEqual(code.disabled, false, 'manual entry remains available after a load failure');
	assert(notifications.length > 0);
}

async function testService() {
	const calls = [];
	const rpc = { declare(spec) { return (...args) => {
		calls.push({ spec, args });
		return Promise.resolve({ status: 'success', success: true, country_code: '44' });
	}; } };
	const service = new Function('L', 'rpc', 'smsNumber', 'pduParser', '_',
		fs.readFileSync(path.join(root, 'sms.js'), 'utf8'))(L, rpc, smsNumber, pduParser, identity);
	assert.strictEqual(await service.getCountryCode('modem_2'), '44');
	await service.setCountryCode('modem_2', '+49');
	assert.deepStrictEqual(calls[1].args, ['modem_2', '49']);
	await service.sendSms('modem_2', '+12025550123', 'hello', '16bit', '2025550123');
	const send = calls[2], sent = Object.fromEntries(send.spec.params.map((name, i) => [name, send.args[i]]));
	assert.strictEqual(sent.recipient, '+12025550123');
	assert.strictEqual(sent.conversation_contact, '2025550123');
	assert.strictEqual(sent.country_code, '', 'already resolved address bypasses the saved code');
	if (sent.pdu) assert.strictEqual(destination(sent.pdu).number, sent.recipient);
	await assert.rejects(service.sendSms('modem_2', 'bad', 'hello'));
	assert.strictEqual(calls.length, 3, 'invalid numbers must not reach RPC');
}

(async function() {
	testNumbersAndPdus();
	testConversations();
	await testCountryCodeField();
	await testService();
	console.log('PASS SMS country code selection, explicit save, modem switching, PDU addressing, replies and RPC');
})().catch(error => { console.error(error); process.exit(1); });
