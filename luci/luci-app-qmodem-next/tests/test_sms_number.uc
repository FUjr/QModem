import { normalizeCode, normalizeNumber, readdressPdu, validReply, groupMessages } from 'qmodem.sms_number';

for (let entry in [
	['2025550123', '', '2025550123'],
	['(202) 555-0123', '1', '+12025550123'],
	['7911123456', '+44', '+447911123456'],
	['15123456789', '49', '+4915123456789'],
	['9876543210', '91', '+919876543210'],
	['13800138000', '86', '+8613800138000'],
	['+12025550123', '44', '+12025550123'],
	['0201234567', '44', '+440201234567'],
	['0012025550123', '', '0012025550123'],
	['12345', '', '12345']
]) assert(normalizeNumber(entry[0], entry[1]) == entry[2], sprintf('number: %J', entry));

for (let number in ['', '+', '++123', '+0123', '12+34', '12x34', '１２３', '123\n', '+1234567890123456', '123456789012345678901'])
	assert(normalizeNumber(number, '') == null, 'invalid number accepted');
for (let code in ['+', '0', '01', '1234', '+1234', 'x', '1;id'])
	assert(normalizeCode(code) == null, 'invalid code accepted');

let local = '0011000A8102525510320008B0020041';
let international = '0011000B912120550521F30008B0020041';
assert(readdressPdu(local, '+12025550123') == international, 'PDU international address');
assert(readdressPdu(international, '2025550123') == local, 'PDU local address');
assert(readdressPdu('039121F0' + substr(local, 2), '+12025550123') ==
	'039121F0' + substr(international, 2), 'PDU SMSC preserved');
let multipart = replace(local, /001100/, '005100') + '0500032A0201';
assert(readdressPdu(multipart, '+12025550123') ==
	replace(international, /001100/, '005100') + '0500032A0201', 'PDU UDH and body preserved');
for (let pdu in ['', 'NaN', '00', '001100FF81', '0004000A8102525510320008B0020041'])
	assert(readdressPdu(pdu, '+12025550123') == null, 'invalid PDU accepted');

assert(validReply('+12025550123', '2025550123'), 'explicit reply');
assert(!validReply('+12025550123', '+442025550123'), 'different international address');
assert(!validReply('+12025550123', '7911123456'), 'unrelated address');
let received = { id: 1, type: 'received', sender: '2025550123', timestamp: 1, is_read: false };
let reply = { id: 2, type: 'sent', recipient: '+12025550123', timestamp: 2 };
assert(length(groupMessages([received, reply])) == 2, 'no automatic suffix matching');
reply.conversation_contact = received.sender;
let groups = groupMessages([received, reply]);
assert(length(groups) == 1 && groups[0].contact == reply.recipient && groups[0].unread_count == 1, 'explicit association');
assert(length(groupMessages([received, reply, {
	id: 3, type: 'sent', recipient: '+442025550123', conversation_contact: received.sender, timestamp: 3
}])) == 3, 'ambiguous associations remain separate');

print('PASS ucode country codes, PDU destination rewrite, message preservation and conversation identity\n');
