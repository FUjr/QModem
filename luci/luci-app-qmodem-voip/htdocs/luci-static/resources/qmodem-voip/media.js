'use strict';
'require baseclass';

function mediaError(code, message) {
	const error = new Error(message || code);
	error.code = code;
	return error;
}

function createMediaClient(dependencies) {
	const deps = dependencies || {};
	let socket = null;
	let audioContext = null;
	let audioSource = null;
	let audioNode = null;
	let scriptNode = null;
	let audioStream = null;
	let token = null;
	let playbackSamples = [];
	let captureSamples = [];
	let captureSequence = 0;
	let muted = false;
	let connectionAttempt = null;
	let connectionKey = null;

	function cancelConnectionAttempt() {
		const attempt = connectionAttempt;
		if (!attempt)
			return;
		connectionAttempt = null;
		attempt.cancelled = true;
		if (attempt.timeout)
			clearTimeout(attempt.timeout);
		if (attempt.reject) {
			const reject = attempt.reject;
			attempt.reject = null;
			reject(mediaError('cancelled', 'browser media connection cancelled'));
		}
		/* Closing a CONNECTING WebSocket makes browsers report the misleading
		 * "closed before established" error. Let the handshake settle, then
		 * close it before it can become the active transport. */
		if (attempt.socket && attempt.socket.readyState === 0) {
			const candidate = attempt.socket;
			candidate.onopen = () => candidate.close();
			candidate.onerror = null;
			candidate.onclose = null;
		}
	}

	function closeSocket() {
		cancelConnectionAttempt();
		if (socket) {
			socket.onopen = null;
			socket.onmessage = null;
			socket.onerror = null;
			socket.onclose = null;
			socket.close();
		}
		socket = null;
		token = null;
		connectionKey = null;
	}

	function close() {
		closeSocket();
		if (audioSource)
			audioSource.disconnect();
		if (audioStream)
			audioStream.getTracks().forEach((track) => track.stop());
		if (audioNode)
			audioNode.disconnect();
		if (scriptNode)
			scriptNode.disconnect();
		if (audioContext && audioContext.state !== 'closed')
			audioContext.close();
		audioSource = null;
		audioStream = null;
		audioNode = null;
		scriptNode = null;
		audioContext = null;
		playbackSamples = [];
		captureSamples = [];
		captureSequence = 0;
		muted = false;
	}

	function enqueuePlayback(frame) {
		if (!(frame instanceof ArrayBuffer))
			return;
		const view = new DataView(frame);
		if (view.byteLength < 24 || view.getUint32(0, true) !== 0x514d5650 ||
			view.getUint32(8, true) !== 48000)
			return;
		for (let offset = 24; offset + 1 < view.byteLength; offset += 2)
			playbackSamples.push(view.getInt16(offset, true) / 32768);
	}

	function makeCaptureFrame(samples) {
		const frame = new ArrayBuffer(24 + samples.length * 2);
		const view = new DataView(frame);
		view.setUint32(0, 0x514d5650, true);
		view.setUint8(4, 1);
		view.setUint8(5, 1);
		view.setUint8(6, 1);
		view.setUint32(8, 48000, true);
		view.setUint32(12, captureSequence++, true);
		view.setUint32(16, Math.floor(performance.now()) >>> 0, true);
		view.setUint32(20, samples.length, true);
		for (let index = 0; index < samples.length; index++)
			view.setInt16(24 + index * 2,
				Math.max(-32768, Math.min(32767, Math.round(samples[index] * 32767))), true);
		return frame;
	}

	function sendCapture(samples) {
		if (!socket || socket.readyState !== 1)
			return;
		for (const sample of samples)
			captureSamples.push(muted ? 0 : sample);
		while (captureSamples.length >= 480) {
			const frame = captureSamples.splice(0, 480);
			socket.send(makeCaptureFrame(frame));
		}
	}

	async function connect(options) {
		if (options.media !== 'ready')
			throw mediaError('not_ready', 'not_ready');
		if (!options.url || !options.httpsOrigin ||
			!String(options.httpsOrigin).startsWith('https://'))
			throw mediaError('not_ready', 'media endpoint not supplied');
		/* A call advances revision while moving through setup, early media, and
		 * active. Keep one transport for the authenticated LuCI session; idle
		 * call cleanup on both peers is the boundary between calls. */
		const requestedKey = options.sessionId;
		if (socket && socket.readyState === 1 && connectionKey === requestedKey)
			return socket;
		if (connectionAttempt && connectionAttempt.key === requestedKey)
			return connectionAttempt.promise;
		closeSocket();

		const attempt = { cancelled: false, key: requestedKey, reject: null, socket: null, timeout: null };
		connectionAttempt = attempt;
		attempt.promise = (async () => {
			const response = await deps.issueToken(options.sessionId, options.callRevision, options.httpsOrigin);
			if (attempt.cancelled)
				throw mediaError('cancelled', 'browser media connection cancelled');
			if (!response || response.status === 'error' || !response.token)
				throw mediaError(response?.error || 'not_ready', response?.message || 'not_ready');

			const WebSocketCtor = deps.webSocketFactory || globalThis.WebSocket;
			if (!WebSocketCtor)
				throw mediaError('unsupported', 'WebSocket is unavailable');
			token = response.token;
			const socketOpenDelay = deps.socketOpenDelay == null ? 100 : deps.socketOpenDelay;
			if (socketOpenDelay > 0)
				await new Promise((resolve) => setTimeout(resolve, socketOpenDelay));
			if (attempt.cancelled)
				throw mediaError('cancelled', 'browser media connection cancelled');
			const advertisedEndpoint = new URL(options.url, options.httpsOrigin);
			if (advertisedEndpoint.protocol !== 'wss:')
				throw mediaError('not_ready', 'media endpoint must use WSS');
			/* uhttpd terminates WSS on every management address. Preserve the
			 * advertised path but force the authenticated HTTPS page origin so a
			 * LAN address cannot break a WAN management session or redirect media. */
			const endpoint = new URL(advertisedEndpoint.pathname, options.httpsOrigin);
			endpoint.protocol = 'wss:';
			const modem = advertisedEndpoint.searchParams.get('group');
			if (modem !== null) {
				if (!/^[A-Za-z0-9_]{1,47}$/.test(modem)) throw mediaError('not_ready', 'invalid modem binding');
				endpoint.searchParams.set('group', modem);
			}
			endpoint.searchParams.set('session_id', options.sessionId);
			const connectingSocket = new WebSocketCtor(endpoint.toString(),
				[ 'qmodem-voip', `qmodem-voip-token.${token}` ]);
			attempt.socket = connectingSocket;
			connectingSocket.binaryType = 'arraybuffer';
			await new Promise((resolve, reject) => {
				attempt.reject = reject;
				attempt.timeout = setTimeout(() => {
					attempt.timeout = null;
					attempt.cancelled = true;
					attempt.reject = null;
					reject(mediaError('not_ready', 'browser media connection timed out'));
				}, 5000);
				connectingSocket.onopen = () => {
					if (attempt.timeout)
						clearTimeout(attempt.timeout);
					attempt.timeout = null;
					attempt.reject = null;
					if (attempt.cancelled) {
						connectingSocket.close();
						return;
					}
					socket = connectingSocket;
					connectionKey = requestedKey;
					token = null;
					resolve();
				};
				connectingSocket.onerror = () => {
					if (attempt.timeout)
						clearTimeout(attempt.timeout);
					attempt.timeout = null;
					attempt.reject = null;
					reject(mediaError('not_ready', 'browser media connection failed'));
				};
				connectingSocket.onclose = () => {
					if (attempt.timeout)
						clearTimeout(attempt.timeout);
					attempt.timeout = null;
					attempt.reject = null;
					reject(mediaError('not_ready', 'browser media connection closed'));
				};
			});
			connectingSocket.onerror = null;
			connectingSocket.onclose = (event) => {
				if (socket !== connectingSocket)
					return;
				socket = null;
				token = null;
				connectionKey = null;
				if (typeof deps.onDisconnect === 'function')
					deps.onDisconnect(event);
			};
			connectingSocket.onmessage = (event) => {
				if (!(event.data instanceof ArrayBuffer))
					return;
				if (audioNode)
					audioNode.port.postMessage({ type: 'pcm', frame: event.data }, [ event.data ]);
				else
					enqueuePlayback(event.data);
			};
			return connectingSocket;
		})().finally(() => {
			if (connectionAttempt === attempt)
				connectionAttempt = null;
		});
		return attempt.promise;
	}

	async function attachAudio(stream, workletUrl, AudioContextCtor) {
		if (audioContext && audioStream) {
			await resumeAudio();
			return;
		}
		const Context = AudioContextCtor || globalThis.AudioContext;
		if (!Context || !stream)
			throw mediaError('unsupported', 'browser audio is unavailable');
		audioContext = new Context({ sampleRate: 48000 });
		if (audioContext.sampleRate !== 48000)
			throw mediaError('unsupported', '48 kHz audio is unavailable');
		audioStream = stream;
		audioSource = audioContext.createMediaStreamSource(stream);
		let workletReady = false;
		try {
			await Promise.race([
				audioContext.audioWorklet.addModule(workletUrl),
				new Promise((resolve, reject) => setTimeout(() => reject(new Error('audio worklet timeout')), 1500))
			]);
			workletReady = true;
		} catch (error) {
			workletReady = false;
		}
		if (workletReady) {
			audioNode = new globalThis.AudioWorkletNode(audioContext, 'qmodem-voip-audio', {
				numberOfInputs: 1,
				numberOfOutputs: 1,
				outputChannelCount: [ 1 ]
			});
			audioSource.connect(audioNode);
			audioNode.connect(audioContext.destination);
			audioNode.port.onmessage = (event) => {
				if (socket && socket.readyState === 1 && event.data?.type === 'pcm')
					socket.send(event.data.frame);
			};
		} else {
			/* Some Safari/WebKit builds leave addModule() pending forever.  Keep
			 * browser media usable with the older, synchronous Web Audio node. */
			scriptNode = audioContext.createScriptProcessor(1024, 1, 1);
			scriptNode.onaudioprocess = (event) => {
				const input = event.inputBuffer.getChannelData(0);
				const output = event.outputBuffer.getChannelData(0);
				sendCapture(input);
				for (let index = 0; index < output.length; index++)
					output[index] = playbackSamples.shift() || 0;
			};
			audioSource.connect(scriptNode);
			scriptNode.connect(audioContext.destination);
		}
		await resumeAudio();
	}

	async function resumeAudio() {
		if (!audioContext || audioContext.state !== 'suspended')
			return;
		try {
			await Promise.race([
				audioContext.resume(),
				new Promise((resolve) => setTimeout(resolve, 500))
			]);
		}
		catch (error) {
			/* A later user gesture can resume playback. */
		}
	}

	function setMuted(value) {
		muted = value === true;
		if (audioNode)
			audioNode.port.postMessage({ type: 'mute', muted });
	}

	function isConnected() {
		return Boolean(socket && socket.readyState === 1);
	}

	function hasAudio() {
		return Boolean(audioContext && audioStream);
	}

	return Object.freeze({
		connect,
		attachAudio,
		resume: resumeAudio,
		disconnect: closeSocket,
		setMuted,
		isConnected,
		hasAudio,
		close
	});
}

const api = Object.freeze({ createMediaClient });

if (typeof module !== 'undefined' && module.exports && typeof baseclass === 'undefined')
	module.exports = api;

else
	return baseclass.extend(api);
