'use strict';
'require baseclass';

const OBJECT = 'qmodem_voip';
const EVENT_TOPIC = 'qmodem_voip.call';
const METHODS = Object.freeze({
	status: 'status',
	capabilities: 'capabilities',
	enable: 'enable',
	disable: 'disable',
	originate: 'originate',
	answer: 'answer',
	reject: 'reject',
	hangup: 'hangup',
	sendDtmf: 'send_dtmf',
	callHistory: 'call_history',
	issueMediaToken: 'issue_media_token'
});

const PARAMS = Object.freeze({
	status: [],
	capabilities: [],
	enable: [],
	disable: [],
	originate: [ 'endpoint', 'number' ],
	answer: [ 'endpoint' ],
	reject: [ 'endpoint' ],
	hangup: [ 'endpoint' ],
	sendDtmf: [ 'endpoint', 'digit' ],
	callHistory: [],
	issueMediaToken: [ 'session_id', 'call_revision', 'https_origin' ]
});

const SNAPSHOT_FIELDS = Object.freeze([
	'state', 'enabled', 'origin', 'endpoint', 'answer_owner', 'modem_id', 'group',
	'number_present', 'caller_id_withheld', 'remote_number',
	'call_duration_seconds', 'revision', 'restart_epoch',
	'sequence', 'drop_count', 'reconcile_pending', 'media', 'media_engine',
	'audio_policy', 'media_backend', 'selection_state', 'fallback_reason', 'audio_firmware', 'last_error', 'firmware_verified',
	'browser_media', 'media_url', 'browser_downlink_frames',
	'browser_downlink_empty', 'browser_downlink_write_errors'
]);

const ERROR_CODES = Object.freeze([
	'invalid_endpoint', 'invalid_number', 'busy', 'invalid_state',
	'at_failed', 'invalid_dtmf', 'unsupported', 'restore_failed', 'invalid_credentials',
	'activation_failed', 'history_unavailable'
]);

const api = Object.freeze({ OBJECT, EVENT_TOPIC, METHODS, PARAMS, SNAPSHOT_FIELDS, ERROR_CODES });

if (typeof module !== 'undefined' && module.exports && typeof baseclass === 'undefined')
	module.exports = api;

else
	return baseclass.extend(api);
