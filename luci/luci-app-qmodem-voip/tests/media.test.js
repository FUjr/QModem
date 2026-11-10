'use strict';

const assert = require('node:assert/strict');
const media = require('../htdocs/luci-static/resources/qmodem-voip/media.js');

const issueRequests = [];
const sockets = [];
let disconnects = 0;

class FakeWebSocket {
	constructor(url, protocol) {
		this.url = url;
		this.protocol = protocol;
		this.readyState = 0;
		this.sent = [];
		sockets.push(this);
	}

	send(frame) {
		this.sent.push(frame);
	}

	close() {
		this.readyState = 3;
	}
}

global.location = { href: 'https://10.96.210.191/cgi-bin/luci/admin/voip', origin: 'https://10.96.210.191' };

const client = media.createMediaClient({
	issueToken: async (sessionId, callRevision, httpsOrigin) => {
		issueRequests.push({ session_id: sessionId, call_revision: callRevision, https_origin: httpsOrigin });
		return { token: '0123456789abcdefghijkl', call_revision: 42 };
	},
	webSocketFactory: FakeWebSocket,
	socketOpenDelay: 0,
	onDisconnect: () => disconnects++
});

(async () => {
	const connection = client.connect({
		media: 'ready',
		url: 'wss://192.168.100.1/qmodem-voip/media?group=sip_modem_a&token=untrusted',
		sessionId: '0123456789abcdef0123456789abcdef',
		callRevision: 42,
		httpsOrigin: 'https://10.96.210.191'
	});
	const duplicateConnection = client.connect({
		media: 'ready',
		url: 'wss://192.168.100.1/qmodem-voip/media?group=sip_modem_a&token=untrusted',
		sessionId: '0123456789abcdef0123456789abcdef',
		callRevision: 43,
		httpsOrigin: 'https://10.96.210.191'
	});
	await Promise.resolve();

	assert.deepEqual(issueRequests, [ {
		session_id: '0123456789abcdef0123456789abcdef',
		call_revision: 42,
		https_origin: 'https://10.96.210.191'
	} ]);
	assert.equal(sockets.length, 1);
	const socket = sockets[0];
	assert.deepEqual(socket.protocol, [ 'qmodem-voip', 'qmodem-voip-token.0123456789abcdefghijkl' ]);
	const endpoint = new URL(socket.url);
	assert.equal(endpoint.origin, 'wss://10.96.210.191');
	assert.equal(endpoint.pathname, '/qmodem-voip/media');
	assert.equal(endpoint.searchParams.has('token'), false);
	assert.equal(endpoint.searchParams.get('group'), 'sip_modem_a');
	assert.equal(endpoint.searchParams.get('session_id'), '0123456789abcdef0123456789abcdef');

	socket.readyState = 1;
	socket.onopen();
	assert.equal(await connection, socket);
	assert.equal(await duplicateConnection, socket);
	assert.equal(await client.connect({
		media: 'ready',
		url: 'wss://192.168.100.1/qmodem-voip/media?group=sip_modem_a&token=untrusted',
		sessionId: '0123456789abcdef0123456789abcdef',
		callRevision: 44,
		httpsOrigin: 'https://10.96.210.191'
	}), socket, 'call state revisions must reuse the established transport');
	assert.equal(client.isConnected(), true);
	assert.equal(client.hasAudio(), false);
	assert.deepEqual(socket.sent, [], 'the authenticated token is header-only; startup must not send a text frame');
	client.disconnect();
	assert.equal(client.isConnected(), false);
	assert.equal(client.hasAudio(), false);

	const reconnect = client.connect({
		media: 'ready',
		url: 'wss://router.example:9443/media',
		sessionId: '0123456789abcdef0123456789abcdef',
		callRevision: 42,
		httpsOrigin: 'https://router.example'
	});
	await Promise.resolve();
	const secondSocket = sockets[1];
	secondSocket.readyState = 1;
	secondSocket.onopen();
	assert.equal(await reconnect, secondSocket);
	secondSocket.readyState = 3;
	secondSocket.onclose({ code: 1006 });
	assert.equal(client.isConnected(), false);
	assert.equal(disconnects, 1);

	client.close();

	const cancelledClient = media.createMediaClient({
		issueToken: async () => ({ token: 'cancelledtoken1234567890', call_revision: 51 }),
		webSocketFactory: FakeWebSocket,
		socketOpenDelay: 0
	});
	const cancelledConnection = cancelledClient.connect({
		media: 'ready',
		url: 'wss://router.example:9443/media',
		sessionId: 'fedcba9876543210fedcba9876543210',
		callRevision: 51,
		httpsOrigin: 'https://router.example'
	});
	const cancelledResult = cancelledConnection.catch((error) => error);
	await Promise.resolve();
	const cancelledSocket = sockets[2];
	assert.equal(cancelledSocket.readyState, 0);
	cancelledClient.disconnect();
	assert.equal(cancelledSocket.readyState, 0,
		'cancelling an opening transport must not call WebSocket.close()');
	cancelledSocket.onopen();
	assert.equal(cancelledSocket.readyState, 3,
		'a cancelled transport is closed only after its handshake settles');
	assert.equal((await cancelledResult).code, 'cancelled');
	console.log('PASS: authenticated browser media handshake contract');
})().catch((error) => {
	console.error(error);
	process.exitCode = 1;
});
