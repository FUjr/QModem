'use strict';
'require baseclass';
'require rpc';
'require qmodem-voip.contract as contract';

const calls = {};
let selectedModem = null;

Object.keys(contract.METHODS).forEach((name) => {
	const invoke = rpc.declare({
		object: contract.OBJECT,
		method: contract.METHODS[name],
		params: contract.PARAMS[name].concat([ 'modem_id' ]),
		expect: {}
	});
	calls[name] = (...args) => invoke(...args, selectedModem);
});

const api = Object.freeze(Object.assign({}, calls, { eventTopic: contract.EVENT_TOPIC, selectModem: (id) => { selectedModem = id; } }));

if (typeof module !== 'undefined' && module.exports && typeof baseclass === 'undefined')
	module.exports = api;
else
	return baseclass.extend(api);
