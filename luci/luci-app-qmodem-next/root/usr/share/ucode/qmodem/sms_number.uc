/* Explicit country codes only; never infer a country from the locale or SIM. */
function normalizeCode(code) {
	code = replace(code || '', /^[ \t]+|[ \t]+$/g, '');
	return code == '' || match(code, /^\+?[1-9][0-9]{0,2}$/) ? replace(code, /^\+/, '') : null;
}

function normalizeNumber(number, country_code) {
	if (type(number) != 'string') return null;
	number = replace(number, /[ \t()\-]/g, '');
	if (!match(number, /^\+?[0-9]+$/)) return null;
	if (substr(number, 0, 1) != '+' && country_code) {
		let code = normalizeCode(country_code);
		if (code == null) return null;
		if (code) number = '+' + code + number;
	}
	if (substr(number, 0, 1) == '+')
		return match(number, /^\+[1-9][0-9]{0,14}$/) ? number : null;
	return length(number) <= 20 ? number : null;
}

function numberKey(number) {
	let normalized = normalizeNumber(number, '');
	return normalized ? 'number:' + replace(normalized, /^\+/, '') : 'text:' + number;
}

/* Rebuild only TP-DA, preserving the message payload and multipart header. */
function readdressPdu(pdu, recipient) {
	if (type(pdu) != 'string' || length(pdu) % 2 || !match(pdu, /^[0-9a-fA-F]+$/)) return null;
	let offset = (1 + int(substr(pdu, 0, 2), 16)) * 2;
	if (length(pdu) < offset + 10 || (int(substr(pdu, offset, 2), 16) & 3) != 1) return null;
	let start = offset + 4;
	let old_length = int(substr(pdu, start, 2), 16);
	let tail = start + 4 + int((old_length + 1) / 2) * 2;
	if (old_length > 20 || length(pdu) < tail + 6) return null;
	let international = substr(recipient, 0, 1) == '+';
	let digits = international ? substr(recipient, 1) : recipient;
	let encoded = '';
	for (let i = 0; i < length(digits); i += 2)
		encoded += (substr(digits, i + 1, 1) || 'F') + substr(digits, i, 1);
	return substr(pdu, 0, start) + sprintf('%02X', length(digits)) +
		(international ? '91' : '81') + encoded + substr(pdu, tail);
}

function validReply(recipient, contact) {
	return recipient == contact || (substr(recipient, 0, 1) == '+' &&
		substr(contact, 0, 1) != '+' && length(recipient) > length(contact) &&
		substr(recipient, length(recipient) - length(contact)) == contact);
}

function groupMessages(messages) {
	let links = {}, addresses = {}, grouped = {};
	for (let message in messages) {
		let address = message.type == 'received' ? message.sender : message.recipient;
		let target = numberKey(address);
		let source = message.conversation_contact ? numberKey(message.conversation_contact) : null;
		if (!addresses[target] || substr(address, 0, 1) == '+') addresses[target] = address;
		if (message.type == 'sent' && source && source != target)
			links[source] = !exists(links, source) || links[source] == target ? target : null;
	}
	function resolve(id) {
		let seen = {};
		while (links[id] && !seen[id]) { seen[id] = true; id = links[id]; }
		return id;
	}
	for (let message in messages) {
		let address = message.type == 'received' ? message.sender : message.recipient;
		let id = resolve(numberKey(address));
		if (!grouped[id]) grouped[id] = { contact: addresses[id] || address, contacts: [], messages: [], last_timestamp: 0, unread_count: 0 };
		let group = grouped[id];
		push(group.contacts, address);
		if (message.conversation_contact && resolve(numberKey(message.conversation_contact)) == id)
			push(group.contacts, message.conversation_contact);
		push(group.messages, message);
		if (message.timestamp > group.last_timestamp) group.last_timestamp = message.timestamp;
		if (message.type == 'received' && !message.is_read) group.unread_count++;
	}
	let result = [];
	for (let id in grouped) push(result, grouped[id]);
	return sort(result, (a, b) => b.last_timestamp - a.last_timestamp);
}

export { normalizeCode, normalizeNumber, numberKey, readdressPdu, validReply, groupMessages };
