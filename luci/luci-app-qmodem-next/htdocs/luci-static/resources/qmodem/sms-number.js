'use strict';

/* No country is inferred from a number, locale or SIM. */
function normalizeCode(code) {
	code = (code || '').trim();
	if (code && !/^\+?[1-9][0-9]{0,2}$/.test(code)) throw new Error('Invalid country calling code');
	return code.replace(/^\+/, '');
}

function normalize(number, countryCode) {
	if (typeof number !== 'string') throw new Error('Invalid phone number');
	number = number.replace(/[ \t()\-]/g, '');
	if (!/^\+?[0-9]+$/.test(number) || /[^+0-9]/.test(number)) throw new Error('Invalid phone number');
	if (number.charAt(0) !== '+' && countryCode) {
		countryCode = normalizeCode(countryCode);
		if (countryCode) number = '+' + countryCode + number;
	}
	if (number.charAt(0) === '+') {
		if (!/^\+[1-9][0-9]{0,14}$/.test(number)) throw new Error('Invalid international phone number');
	} else if (number.length > 20) {
		throw new Error('Invalid phone number');
	}
	return number;
}

function key(number) {
	try { return 'number:' + normalize(number).replace(/^\+/, ''); }
	catch (e) { return 'text:' + String(number); }
}

/* Only an explicit reply associates a local address with a longer one.
 * Conflicting associations remain separate; never match number suffixes. */
function conversations(messages) {
	var links = Object.create(null), addresses = Object.create(null), grouped = Object.create(null);
	messages.forEach(function(message) {
		var address = message.type === 'received' ? message.sender : message.recipient;
		var target = key(address), source = message.conversation_contact && key(message.conversation_contact);
		if (!addresses[target] || String(address).charAt(0) === '+') addresses[target] = address;
		if (message.type === 'sent' && source && source !== target)
			links[source] = links[source] === undefined || links[source] === target ? target : null;
	});
	function resolve(id) {
		var seen = Object.create(null);
		while (links[id] && !seen[id]) { seen[id] = true; id = links[id]; }
		return id;
	}
	messages.forEach(function(message) {
		var address = message.type === 'received' ? message.sender : message.recipient;
		var id = resolve(key(address));
		if (!grouped[id]) grouped[id] = { contact: addresses[id] || address, contacts: [], messages: [], last_timestamp: 0, unread_count: 0 };
		var group = grouped[id];
		group.contacts.push(address);
		if (message.conversation_contact && resolve(key(message.conversation_contact)) === id)
			group.contacts.push(message.conversation_contact);
		group.messages.push(message);
		group.last_timestamp = Math.max(group.last_timestamp, message.timestamp || 0);
		if (message.type === 'received' && !message.is_read) group.unread_count++;
	});
	return Object.keys(grouped).map(function(id) { return grouped[id]; })
		.sort(function(a, b) { return b.last_timestamp - a.last_timestamp; });
}

return L.Class.extend({ normalize: normalize, normalizeCode: normalizeCode, key: key, conversations: conversations });
