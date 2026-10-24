'use strict';
'require rpc';
'require qmodem.sms-number as smsNumber';

var callList = rpc.declare({ object: 'qmodem.sms', method: 'list', params: [ 'modem_id', 'limit', 'offset' ], expect: { } });
var callSync = rpc.declare({ object: 'qmodem.sms', method: 'sync', params: [ 'modem_id' ], expect: { } });
var callSend = rpc.declare({ object: 'qmodem.sms', method: 'send', params: [ 'modem_id', 'recipient', 'content', 'conversation_contact', 'country_code' ], expect: { } });
var callSetCountryCode = rpc.declare({ object: 'qmodem.sms', method: 'configure', params: [ 'modem_id', 'country_code' ], expect: { } });
var callDelete = rpc.declare({ object: 'qmodem.sms', method: 'delete', params: [ 'modem_id', 'id', 'index' ], expect: { } });
var callMarkRead = rpc.declare({ object: 'qmodem.sms', method: 'mark_read', params: [ 'modem_id', 'id' ], expect: { } });
var callStorageGet = rpc.declare({ object: 'qmodem.sms', method: 'storage_get', params: [ 'modem_id' ], expect: { } });
var callStorageSet = rpc.declare({ object: 'qmodem.sms', method: 'storage_set', params: [ 'modem_id', 'mem1', 'mem2', 'mem3' ], expect: { } });
var callConfigure = rpc.declare({ object: 'qmodem.sms', method: 'configure', params: [ 'modem_id', 'mode', 'poll_interval', 'forwarding', 'auto_delete' ], expect: { } });
var callModemList = rpc.declare({ object: 'qmodem.sms', method: 'modem_list', expect: { } });
var callConfigGet = rpc.declare({ object: 'qmodem.sms', method: 'config_get', params: [ 'modem_id' ], expect: { } });

function messagesFrom(result) {
	return (result.messages || result.msg || result.received || []).map(function(message) {
		if (!message.type) message.type = 'received';
		if (message.is_read == null) message.is_read = false;
		if (message.success != null && message.is_success == null) message.is_success = message.success;
		return message;
	});
}

function listRaw(modem) {
	return callList(modem, 500, 0).then(function(result) {
		if (result.status === 'error') return Promise.reject(new Error(result.error || 'SMS backend error'));
		return result;
	});
}

function syncRaw(modem) {
	return callSync(modem).then(function(result) {
		if (result.status === 'error') return Promise.reject(new Error(result.error || 'SMS synchronization failed'));
		return result;
	});
}

function deleteMany(modem, ids) {
	ids = Array.isArray(ids) ? ids : [ ids ];
	return Promise.all(ids.map(function(id) { return callDelete(modem, id, id); })).then(function(results) {
		return { success: results.every(function(result) { return result.status === 'success'; }), deleted: results.length };
	});
}

function parseStorage(result) {
	var storage = { mem1: result.configured || 'SM', mem2: 'SM', mem3: 'SM', ME: { used: 0, total: 0 }, SM: { used: 0, total: 0 } };
	var match = (result.response || '').match(/\+CPMS:\s*"?([^",]+)"?,(\d+),(\d+),"?([^",]+)"?,(\d+),(\d+)(?:,"?([^",]+)"?,(\d+),(\d+))?/);
	if (!match) return storage;
	storage.mem1 = match[1]; storage.mem2 = match[4]; storage.mem3 = match[7] || match[4];
	[ [ match[1], match[2], match[3] ], [ match[4], match[5], match[6] ], [ match[7], match[8], match[9] ] ].forEach(function(values) {
		if (values[0] === 'SM' || values[0] === 'ME') storage[values[0]] = { used: +values[1] || 0, total: +values[2] || 0 };
	});
	return storage;
}

return L.Class.extend({
	getModems: function() {
		return callModemList().then(function(result) {
			return (result.modems || []).map(function(modem) {
				return { id: modem.modem_id, name: modem.name || modem.modem_id, enabled: !!modem.enabled };
			});
		});
	},
	getConfig: function(configSection) { return callConfigGet(configSection || 'modem_1'); },
	getCountryCode: function(configSection) {
		return callConfigGet(configSection || 'modem_1').then(function(result) {
			if (result.status === 'error') throw new Error(result.error || 'Failed to load country calling code');
			return result.country_code || '';
		});
	},
	setCountryCode: function(configSection, code) {
		return callSetCountryCode(configSection || 'modem_1', smsNumber.normalizeCode(code)).then(function(result) {
			if (result.status === 'error') throw new Error(result.error || 'Failed to save country calling code');
			return result;
		});
	},
	configure: function(configSection, mode, pollInterval, forwarding, autoDelete) {
		var modem = configSection || 'modem_1';
		return callConfigGet(modem).then(function(current) {
			return callConfigure(modem, mode, pollInterval,
				forwarding == null ? !!current.forwarding : forwarding, autoDelete);
		}).then(function(result) {
			if (result.status === 'error') return Promise.reject(new Error(result.error || 'SMS configuration failed'));
			return result;
		});
	},
	listSms: function(configSection) {
		var modem = configSection || 'modem_1';
		return listRaw(modem).then(function(first) {
			var refresh = first.mode === 'database_poll' ? syncRaw(modem) : Promise.resolve();
			return refresh.then(function() { return first.mode === 'database_poll' ? listRaw(modem) : first; });
		}).then(function(result) {
			var messages = messagesFrom(result);
			return { conversations: smsNumber.conversations(messages), total: messages.length, mode: result.mode };
		});
	},
	getConversation: function(configSection, contact) {
		return this.listSms(configSection).then(function(result) {
			var found = result.conversations.filter(function(item) {
				return item.contacts.some(function(address) { return smsNumber.key(address) === smsNumber.key(contact); });
			})[0];
			return { contact: found ? found.contact : contact, messages: found ? found.messages : [] };
		});
	},

	sync: function(configSection) { return syncRaw(configSection || 'modem_1'); },
	sendSms: function(configSection, recipient, message, encoding, conversationContact) {
		try { recipient = smsNumber.normalize(recipient); }
		catch (e) { return Promise.reject(e); }
		return callSend(configSection || 'modem_1', recipient, message, conversationContact, '').then(function(result) { result.success = result.status === 'success'; return result; });
	},
	deleteSms: function(configSection, type, ids) { return deleteMany(configSection || 'modem_1', ids); },
	markRead: function(configSection, ids) {
		var modem = configSection || 'modem_1'; ids = Array.isArray(ids) ? ids : [ ids ];
		return Promise.all(ids.map(function(id) { return callMarkRead(modem, id); })).then(function() { return { success: true, marked: ids.length }; });
	},
	getSentHistory: function(configSection) {
		return listRaw(configSection || 'modem_1').then(function(result) { return { messages: messagesFrom(result).filter(function(message) { return message.type === 'sent'; }) }; });
	},
	getReceivedHistory: function(configSection) {
		return listRaw(configSection || 'modem_1').then(function(result) { return { messages: messagesFrom(result).filter(function(message) { return message.type === 'received'; }) }; });
	},
	clearSentHistory: function(configSection) {
		var modem = configSection || 'modem_1';
		return this.getSentHistory(modem).then(function(result) { return deleteMany(modem, result.messages.map(function(message) { return message.id; })); });
	},
	clearReceivedHistory: function(configSection) {
		var modem = configSection || 'modem_1';
		return this.getReceivedHistory(modem).then(function(result) { return deleteMany(modem, result.messages.map(function(message) { return message.id; })); });
	},
	formatTimestamp: function(timestamp) {
		var date = new Date(timestamp * 1000), now = new Date(), days = Math.floor((now - date) / 86400000);
		if (days === 0) return String(date.getHours()).padStart(2, '0') + ':' + String(date.getMinutes()).padStart(2, '0');
		if (days === 1) return _('Yesterday');
		if (days < 7) return [ _('Sunday'), _('Monday'), _('Tuesday'), _('Wednesday'), _('Thursday'), _('Friday'), _('Saturday') ][date.getDay()];
		return date.getFullYear() + '-' + String(date.getMonth() + 1).padStart(2, '0') + '-' + String(date.getDate()).padStart(2, '0');
	},
	formatPhoneNumber: function(number) {
		if (!number) return '';
		var digits = number.replace(/\D/g, '');
		return digits.length === 11 && digits.startsWith('1') ? digits.substring(0, 3) + ' ' + digits.substring(3, 7) + ' ' + digits.substring(7) : number;
	},
	truncateMessage: function(content, maximum) {
		maximum = maximum || 50; return !content || content.length <= maximum ? (content || '') : content.substring(0, maximum) + '...';
	},
	getSmsStorage: function(configSection) {
		return callStorageGet(configSection || 'modem_1').then(function(result) { return result.status === 'error' ? { error: result.error } : { storage: parseStorage(result) }; });
	},
	setSmsStorage: function(configSection, mem1, mem2, mem3) {
		return callStorageSet(configSection || 'modem_1', mem1, mem2, mem3 || mem2).then(function(result) { result.success = result.status !== 'error'; return result; });
	},
	getSimSms: function(configSection) {
		return listRaw(configSection || 'modem_1').then(function(result) { return { messages: result.msg || result.received || result.messages || [] }; });
	},
	deleteSimSms: function(configSection, index) {
		return callDelete(configSection || 'modem_1', index, index).then(function(result) { result.success = result.status === 'success'; return result; });
	}
});
