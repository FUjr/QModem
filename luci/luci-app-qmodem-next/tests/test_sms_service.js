'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const L = { Class: { extend: function(service) { return service; } } };
const smsNumber = new Function('L', fs.readFileSync(path.join(__dirname,
	'../htdocs/luci-static/resources/qmodem/sms-number.js'), 'utf8'))(L);

const source = fs.readFileSync(path.join(__dirname,
	'../htdocs/luci-static/resources/qmodem/sms.js'), 'utf8');

function createService(listResults, syncResult) {
	let listCalls = 0;
	const rpc = {
		declare: function(spec) {
			return function() {
				if (spec.method === 'list')
					return Promise.resolve(listResults[listCalls++]);
				if (spec.method === 'sync')
					return Promise.resolve(syncResult);
				return Promise.resolve({});
			};
		}
	};
	const L = { Class: { extend: function(service) { return service; } } };
	const service = new Function('rpc', 'L', 'smsNumber', '_', source)(rpc, L, smsNumber, function(value) { return value; });
	return { service: service, listCalls: function() { return listCalls; } };
}

async function main() {
	const failed = createService([
		{ mode: 'database_poll', messages: [] }
	], { status: 'error', error: 'database mode requires use_ubus' });

	await assert.rejects(failed.service.listSms('modem_1'),
		/database mode requires use_ubus/);
	assert.strictEqual(failed.listCalls(), 1,
		'a failed sync must not be rendered as a second empty list');

	const synced = createService([
		{ mode: 'database_poll', messages: [] },
		{ mode: 'database_poll', messages: [
			{ id: 1, type: 'received', sender: '10086', timestamp: 1, content: 'ok' }
		] }
	], { status: 'success', imported: 1 });
	const result = await synced.service.listSms('modem_1');

	assert.strictEqual(synced.listCalls(), 2);
	assert.strictEqual(result.total, 1);
	assert.strictEqual(result.conversations[0].contact, '10086');
	console.log('PASS: SMS service propagates sync errors and renders refreshed messages');
}

main().catch(function(error) {
	console.error(error);
	process.exit(1);
});
