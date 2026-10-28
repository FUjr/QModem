'use strict';
'require baseclass';

const STATES = Object.freeze([
	'disabled', 'idle', 'outgoing_setup', 'incoming_ringing', 'early_media',
	'active', 'terminating', 'recovering', 'fault'
]);
const LOCAL_ENDPOINTS = Object.freeze([ 'browser', 'lan_sip' ]);
const TERMINAL_STATES = Object.freeze([ 'disabled', 'idle', 'fault' ]);

function initialState() {
	return {
		capabilities: null,
		snapshot: null,
		error: null,
		mediaStatus: 'not_ready',
		mediaUrl: '',
		mediaPermission: 'unknown',
		requiresResnapshot: false,
		lastStatusKey: ''
	};
}

function asBoolean(value) {
	return value === true || value === 1 || value === '1';
}

function counter(value) {
	try {
		return BigInt(String(value ?? 0));
	}
	catch (error) {
		return 0n;
	}
}

function copySnapshot(input) {
	if (!input || typeof input !== 'object' || STATES.indexOf(input.state) === -1)
		return null;

	return {
		state: input.state,
		enabled: asBoolean(input.enabled),
		origin: String(input.origin || 'none'),
		endpoint: String(input.endpoint || 'none'),
		answer_owner: String(input.answer_owner || 'none'),
		number_present: asBoolean(input.number_present),
		caller_id_withheld: asBoolean(input.caller_id_withheld),
		remote_number: String(input.remote_number || ''),
		call_duration_seconds: Math.max(0, Number(input.call_duration_seconds) || 0),
		revision: input.revision ?? 0,
		restart_epoch: input.restart_epoch ?? 0,
		sequence: input.sequence ?? 0,
		drop_count: input.drop_count ?? 0,
		reconcile_pending: asBoolean(input.reconcile_pending),
		media: String(input.media || ''),
		media_engine: String(input.media_engine || ''),
		browser_media: String(input.browser_media || ''),
		media_url: String(input.media_url || '')
	};
}

function statusKey(snapshot) {
	return snapshot ? `${snapshot.state}:${snapshot.enabled}:${snapshot.revision}` : 'loading';
}

function applySnapshot(state, input, source, eventName) {
	const snapshot = copySnapshot(input);
	if (!snapshot)
		return state;

	const previous = state.snapshot;
	/* Status polling can enrich the same call revision after media_sync()
	 * starts the browser WebSocket listener.  Ignore only genuinely older
	 * revisions so media_url/browser_media changes are not lost. */
	if (previous && counter(snapshot.revision) < counter(previous.revision))
		return state;

	const epochChanged = previous && counter(snapshot.restart_epoch) !== counter(previous.restart_epoch);
	const revisionGap = previous && counter(snapshot.revision) > counter(previous.revision) + 1n;
	const recovering = snapshot.state === 'recovering' || snapshot.reconcile_pending;
	const eventRequiresResnapshot = source === 'event' && (epochChanged || revisionGap || recovering || eventName === 'event_gap');
	const clearAfterSnapshot = source === 'snapshot' && !recovering;

	return Object.assign({}, state, {
		snapshot,
		error: null,
		mediaStatus: snapshot.media || snapshot.media_engine || state.mediaStatus,
		mediaUrl: snapshot.media_url,
		requiresResnapshot: clearAfterSnapshot ? false : (state.requiresResnapshot || Boolean(eventRequiresResnapshot)),
		lastStatusKey: statusKey(snapshot)
	});
}

function reduce(state, action) {
	const current = state || initialState();
	if (!action || typeof action.type !== 'string')
		return current;

	switch (action.type) {
	case 'CAPABILITIES':
		return Object.assign({}, current, {
			capabilities: action.value || null,
			mediaStatus: action.value?.media || action.value?.media_engine || 'not_ready',
			mediaUrl: action.value?.media_url || current.mediaUrl,
			error: null
		});
	case 'SNAPSHOT':
		return applySnapshot(current, action.value, 'snapshot', '');
	case 'EVENT':
		return applySnapshot(current, action.value, 'event', action.value?.event || '');
	case 'ERROR':
		return Object.assign({}, current, { error: action.value || null });
	case 'MEDIA_RESULT':
		return Object.assign({}, current, {
			mediaStatus: action.value?.status === 'error' && action.value.message === 'not_ready' ? 'not_ready' : current.mediaStatus,
			error: action.value?.status === 'error' ? action.value : null
		});
	case 'MEDIA_PERMISSION':
		return Object.assign({}, current, { mediaPermission: action.value });
	case 'CLEAR_ERROR':
		return Object.assign({}, current, { error: null });
	default:
		return current;
	}
}

function errorMessage(error) {
	const messages = {
		invalid_endpoint: _('This call endpoint is not available.'),
		invalid_number: _('The destination contains unsupported characters.'),
		busy: _('Another endpoint answered this call first.'),
		invalid_state: _('The call changed state before this command completed.'),
		at_failed: _('The modem call command failed.'),
		invalid_dtmf: _('The selected DTMF key is not supported.'),
		unsupported: _('This operation is not ready for the current capability state.'),
		restore_failed: _('The modem could not restore its baseline state.'),
		history_unavailable: _('Call history is temporarily unavailable.')
	};
	if (!error)
		return '';
	return messages[error.error] || error.message || _('The operation failed.');
}

function viewModel(state) {
	const capabilities = state.capabilities || {};
	const snapshot = state.snapshot || { state: 'disabled', enabled: false };
	const capabilityPending = !state.capabilities || Object.keys(capabilities).length === 0;
	const supported = !capabilityPending && capabilities.supported === true && capabilities.support_state === 'supported';
	const stable = !state.requiresResnapshot && snapshot.state !== 'recovering' && !snapshot.reconcile_pending;
	const enabled = supported && snapshot.enabled === true;
	const canControl = enabled && stable;
	const commandStates = Object.freeze({
		canOriginate: canControl && snapshot.state === 'idle',
		canAnswer: canControl && snapshot.state === 'incoming_ringing',
		canReject: canControl && [ 'incoming_ringing', 'early_media' ].indexOf(snapshot.state) !== -1,
		canHangup: canControl && [ 'outgoing_setup', 'early_media', 'active' ].indexOf(snapshot.state) !== -1,
		canMute: canControl && snapshot.state === 'active',
		canKeypad: canControl && snapshot.state === 'active' &&
			(snapshot.origin === 'browser' || snapshot.answer_owner === 'browser')
	});

	let disabledReason = '';
	if (capabilityPending)
		disabledReason = _('Waiting for modem discovery. Call controls will become available when the modem is ready.');
	else if (!supported)
		disabledReason = _('Unsupported hardware: call controls are unavailable.');
	else if (state.requiresResnapshot || snapshot.state === 'recovering' || snapshot.reconcile_pending)
		disabledReason = _('State recovery is in progress. Refreshing the call snapshot.');
	else if (!enabled)
		disabledReason = _('Enable the experimental call service first.');

	return Object.assign({
		supported,
		capabilityPending,
		hardware: typeof capabilities.hardware === 'string' ? capabilities.hardware : '',
		enabled,
		stable,
		disabledReason,
		state: snapshot.state,
		callTimerVisible: [ 'outgoing_setup', 'early_media', 'active', 'terminating' ].indexOf(snapshot.state) !== -1,
		remoteNumber: snapshot.caller_id_withheld ? '' : snapshot.remote_number,
		callDurationSeconds: snapshot.call_duration_seconds,
		media: state.mediaStatus,
		permission: state.mediaPermission,
		errorText: errorMessage(state.error)
	}, commandStates);
}

const api = Object.freeze({ STATES, LOCAL_ENDPOINTS, TERMINAL_STATES, initialState, reduce, copySnapshot, viewModel, errorMessage });

if (typeof module !== 'undefined' && module.exports && typeof baseclass === 'undefined')
	module.exports = api;

else
	return baseclass.extend(api);
