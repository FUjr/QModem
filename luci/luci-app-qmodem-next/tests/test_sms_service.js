'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const L = { Class: { extend: function(service) { return service; } } };
const smsNumber = new Function('L', fs.readFileSync(path.join(__dirname,
	'../htdocs/luci-static/resources/qmodem/sms-number.js'), 'utf8'))(L);

const source = fs.readFileSync(path.join(__dirname,
	'../htdocs/luci-static/resources/qmodem/sms.js'), 'utf8');

function createService(listResults, syncResult, responses) {
	let listCalls = 0;
	const calls = [];
	const rpc = {
		declare: function(spec) {
			return function(...args) {
				calls.push({ method: spec.method, args });
				if (spec.method === 'list')
					return Promise.resolve(listResults[listCalls++]);
				if (spec.method === 'sync')
					return Promise.resolve(syncResult);
				return Promise.resolve((responses || {})[spec.method] || {});
			};
		}
	};
	const L = { Class: { extend: function(service) { return service; } } };
	const service = new Function('rpc', 'L', 'smsNumber', '_', source)(rpc, L, smsNumber, function(value) { return value; });
	return { service: service, calls, listCalls: function() { return listCalls; } };
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
	for (const mode of [ 'database_urc', 'database_poll', 'direct' ]) {
		const first = { mode, messages: [] };
		const second = { mode, messages: [
			{ id: 9, type: 'received', sender: '10086', timestamp: 1, content: 'new' }
		] };
		const forced = createService([first, second], { status: 'success' });
		const refreshed = await forced.service.listSms('modem_2', true);
		assert.strictEqual(refreshed.total, mode === 'direct' ? 0 : 1);
		assert.deepStrictEqual(forced.calls.map(c => c.method),
			mode === 'direct' ? ['list'] : ['list', 'sync', 'list']);
		assert(forced.calls.every(c => c.args[0] === 'modem_2'));
	}
	const urc = createService([{ mode: 'database_urc', messages: [] }]);
	await urc.service.getConversation('modem_2', '10086');
	assert.deepStrictEqual(urc.calls.map(c => c.method), ['list'],
		'URC background page refresh must not poll AT every time');
	const opened = createService([
		{ mode: 'database_urc', messages: [] },
		{ mode: 'database_urc', messages: [{ id: 3, type: 'received', sender: '10086' }] }
	], { status: 'success' });
	assert.strictEqual((await opened.service.getConversation('modem_2', '10086', true)).messages.length, 1);
	const syncError = createService([{ mode: 'database_urc', messages: [] }],
		{ status: 'error', error: 'AT port unavailable' });
	await assert.rejects(syncError.service.listSms('modem_2', true), /AT port unavailable/);

	for (const mode of [ 'direct', 'database_poll', 'database_urc' ]) {
		const raw = { status: 'success', mode, storage: 'ME', auto_delete: true,
			messages: [{ index: 0, pdu: '00AB', content: 'raw' }] };
		const modem = createService([], null, { sim_list: raw,
			sim_delete: { status: 'success', deleted: 1 } });
		assert.deepStrictEqual(await modem.service.getSimSms('modem_2'), raw);
		assert((await modem.service.deleteSimSms('modem_2', raw.storage, raw.messages[0])).success);
		assert.deepStrictEqual(modem.calls, [
			{ method: 'sim_list', args: ['modem_2'] },
			{ method: 'sim_delete', args: ['modem_2', 'ME', 0, '00AB'] }
		], 'module storage APIs must not use database list/delete');
		await assert.rejects(modem.service.deleteSimSms('modem_2', 'ME', { id: 1 }), /identity/);
		assert.strictEqual(modem.calls.length, 2, 'database IDs must never reach modem delete');
	}
	const unavailable = createService([]);
	await assert.rejects(unavailable.service.getSimSms('modem_1'), /Update qmodem-smsd and LuCI together/);
	assert(!(await unavailable.service.deleteSimSms('modem_1', 'SM', { index: 0, pdu: '00' })).success);
	const readError = createService([], null, { sim_list: { status: 'error', error: 'CPMS failed' } });
	await assert.rejects(readError.service.getSimSms('modem_1'), /CPMS failed/);
	const metadataError = createService([], null, { sim_delete: {
		status: 'error', deleted: 1, error: 'metadata failed'
	} });
	const partial = await metadataError.service.deleteSimSms('modem_1', 'SM', { index: 0, pdu: '00' });
	assert.strictEqual(partial.deleted, 1);
	assert.strictEqual(partial.success, false);
	console.log('PASS: SMS source separation, safe delete identity, refresh and sync errors');
}

main().catch(function(error) {
	console.error(error);
	process.exit(1);
});
