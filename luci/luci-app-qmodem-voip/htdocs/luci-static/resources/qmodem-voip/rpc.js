'use strict';
'require baseclass';
'require rpc';
'require qmodem-voip.contract as contract';

const calls = {};

Object.keys(contract.METHODS).forEach((name) => {
	calls[name] = rpc.declare({
		object: contract.OBJECT,
		method: contract.METHODS[name],
		params: contract.PARAMS[name],
		expect: {}
	});
});

calls.reprobeAudio = rpc.declare({
	object: 'qmodem_voip', method: 'reprobe_audio', params: [], expect: {}
});

calls.sipStatus = rpc.declare({
	object: 'qmodem.sip',
	method: 'status',
	params: [],
	expect: {}
});

calls.generateSipCredentials = rpc.declare({
	object: 'qmodem.sip',
	method: 'generate_credentials',
	params: [ 'username' ],
	expect: {}
});

const api = Object.freeze(Object.assign({}, calls, { eventTopic: contract.EVENT_TOPIC }));

if (typeof module !== 'undefined' && module.exports && typeof baseclass === 'undefined')
	module.exports = api;
else
	return baseclass.extend(api);
