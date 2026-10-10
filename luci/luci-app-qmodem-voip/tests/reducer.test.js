'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
global._ = (value) => value;
const contract = require('../htdocs/luci-static/resources/qmodem-voip/contract.js');
const reducer = require('../htdocs/luci-static/resources/qmodem-voip/reducer.js');

assert.deepEqual(Object.values(contract.METHODS), [ 'status', 'capabilities', 'enable', 'disable', 'originate', 'answer', 'reject', 'hangup', 'send_dtmf', 'call_history', 'issue_media_token' ]);
assert.deepEqual(contract.PARAMS.status, []);
assert.deepEqual(contract.PARAMS.capabilities, []);
assert.deepEqual(contract.PARAMS.enable, []);
assert.deepEqual(contract.PARAMS.disable, []);
assert.deepEqual(contract.PARAMS.originate, [ 'endpoint', 'number' ]);
assert.deepEqual(contract.PARAMS.answer, [ 'endpoint' ]);
assert.deepEqual(contract.PARAMS.reject, [ 'endpoint' ]);
assert.deepEqual(contract.PARAMS.hangup, [ 'endpoint' ]);
assert.deepEqual(contract.PARAMS.sendDtmf, [ 'endpoint', 'digit' ]);
assert.deepEqual(contract.PARAMS.callHistory, []);
assert.deepEqual(contract.PARAMS.issueMediaToken, [ 'session_id', 'call_revision', 'https_origin' ]);
assert.ok(contract.ERROR_CODES.includes('invalid_dtmf'));
assert.equal(contract.OBJECT, 'qmodem_voip');
assert.equal(contract.EVENT_TOPIC, 'qmodem_voip.call');

const supported = { status: 'experimental', supported: true, support_state: 'supported', media: 'ready' };
const unsupported = { status: 'experimental', supported: false, support_state: 'unsupported', media: 'not_ready' };

function snapshot(state, revision, overrides) {
	return Object.assign({ state, enabled: true, origin: 'none', endpoint: 'none', answer_owner: 'none', number_present: false, caller_id_withheld: false, revision, restart_epoch: 1, sequence: revision, drop_count: 0, reconcile_pending: false }, overrides || {});
}

function model(capabilities, current) {
	let state = reducer.initialState();
	state = reducer.reduce(state, { type: 'CAPABILITIES', value: capabilities });
	state = reducer.reduce(state, { type: 'SNAPSHOT', value: current });
	return state;
}

assert.equal(reducer.viewModel(model(unsupported, snapshot('disabled', 0, { enabled: false }))).supported, false);
assert.equal(reducer.viewModel(model(supported, snapshot('disabled', 0, { enabled: false }))).state, 'disabled');
assert.equal(reducer.viewModel(model(supported, snapshot('idle', 1))).canOriginate, true);
assert.equal(reducer.viewModel(model(supported, snapshot('outgoing_setup', 2, { origin: 'browser', endpoint: 'cellular', number_present: true }))).canHangup, true);
assert.equal(reducer.viewModel(model(supported, snapshot('incoming_ringing', 3, { caller_id_withheld: true }))).canAnswer, true);
const activeBrowser = reducer.viewModel(model(supported, snapshot('active', 4, {
	answer_owner: 'browser', number_present: true, remote_number: '10086', call_duration_seconds: 42
})));
assert.equal(activeBrowser.canMute, true);
assert.equal(activeBrowser.canKeypad, true);
assert.equal(activeBrowser.remoteNumber, '10086');
assert.equal(activeBrowser.callDurationSeconds, 42);
assert.equal(reducer.viewModel(model(supported, snapshot('active', 4, { answer_owner: 'lan_sip' }))).canKeypad, false);
assert.equal(reducer.viewModel(model(supported, snapshot('recovering', 5, { reconcile_pending: true }))).canHangup, false);
assert.equal(reducer.viewModel(model(supported, snapshot('fault', 6))).canOriginate, false);

let state = model(supported, snapshot('idle', 1));
assert.equal(state.mediaStatus, 'ready');
state = reducer.reduce(state, { type: 'SNAPSHOT', value: snapshot('active', 2, { media_engine: 'ready', browser_media: 'ready', media_url: 'wss://router.example:9443/media' }) });
assert.equal(state.mediaUrl, 'wss://router.example:9443/media');
assert.equal(state.snapshot.browser_media, 'ready');
state = reducer.reduce(state, { type: 'MEDIA_RESULT', value: { status: 'error', error: 'not_ready', message: 'connection failed' } });
assert.equal(state.mediaStatus, 'ready', 'a browser connection failure must not hide a ready modem media backend');
state = reducer.reduce(state, { type: 'EVENT', value: snapshot('active', 3, { event: 'event_gap', restart_epoch: 2, reconcile_pending: true }) });
assert.equal(state.requiresResnapshot, true);
assert.equal(reducer.viewModel(state).canMute, false);
state = reducer.reduce(state, { type: 'SNAPSHOT', value: snapshot('idle', 4, { restart_epoch: 2, sequence: 2 }) });
assert.equal(state.requiresResnapshot, false);
state = reducer.reduce(state, { type: 'ERROR', value: { status: 'error', error: 'busy', message: 'another endpoint answered' } });
assert.match(reducer.viewModel(state).errorText, /Another endpoint/);
assert.match(reducer.errorMessage({ error: 'invalid_dtmf' }), /DTMF key/);

const resourceDir = path.resolve(__dirname, '../htdocs/luci-static/resources');
const resources = [];
function collect(directory) {
	for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
		const fullPath = path.join(directory, entry.name);
		if (entry.isDirectory()) collect(fullPath);
		else if (entry.name.endsWith('.js')) resources.push(fs.readFileSync(fullPath, 'utf8'));
	}
}
collect(resourceDir);
assert.equal(resources.some((source) => /external[_]sip|localStorage|sessionStorage|console\.log|password.*console|token.*console/i.test(source)), false);

const surfaceSource = fs.readFileSync(path.resolve(__dirname, '../htdocs/luci-static/resources/qmodem-voip/surface.js'), 'utf8');
assert.match(surfaceSource, /class: `cbi-button cbi-button-\$\{style \|\| 'neutral'\}`/);
assert.match(surfaceSource, /new ui\.Textfield/);
assert.doesNotMatch(surfaceSource, /new ui\.Checkbox/);
assert.match(surfaceSource, /ui\.showModal\(_\('Incoming call'\)/);
assert.match(surfaceSource, /ui\.hideModal\(\)/);
assert.doesNotMatch(surfaceSource, /Generate credentials|SIP account/);
assert.match(surfaceSource, /Call history/);
assert.match(surfaceSource, /dialForm\.addEventListener\('submit', \(event\) => context\.originate\(event\)\)/);
assert.match(surfaceSource, /button\(_\('Call'\), 'action', null, 'submit'\)/);
assert.doesNotMatch(surfaceSource, /button\(_\('Call'\)[^\n]+context\.originate/);
assert.match(surfaceSource, /key\.disabled = true/);
assert.match(surfaceSource, /key\.setAttribute\('aria-describedby', 'qvoip-keypad-help'\)/);
assert.match(surfaceSource, /context\.refs\.callDetail,/);
assert.match(surfaceSource, /context\.refs\.dialForm,/);
assert.match(surfaceSource, /context\.refs\.actions,/);
assert.doesNotMatch(surfaceSource, /role: 'alertdialog'/);
assert.doesNotMatch(surfaceSource, /type:\s*'checkbox'/);
assert.match(surfaceSource, /context\.sendDtmf\(value\)/);
assert.match(surfaceSource, /context\.refs\.remoteParty/);

const viewSource = fs.readFileSync(path.resolve(__dirname, '../htdocs/luci-static/resources/view/qmodem-voip/call.js'), 'utf8');
assert.match(viewSource, /'require rpc as luciRpc';/);
assert.doesNotMatch(viewSource, /'require uci';/);
assert.match(viewSource, /luciRpc\.getSessionID\(\)/);
assert.match(viewSource, /rpc\[action\]\(\.\.\.\(Array\.isArray\(payload\) \? payload : \[\]\)\)/);
assert.match(viewSource, /this\.run\('originate', \[ 'browser', number \]\)/);
assert.match(viewSource, /this\.run\('answer', \[ 'browser' \]\)/);
assert.match(viewSource, /this\.run\('sendDtmf', \[ 'browser', digit \]\)/);
assert.doesNotMatch(viewSource, /generateSipCredentials|qmodem_sip/);
assert.match(viewSource, /rpc\.callHistory\(\)/);
assert.match(viewSource, /await this\.prepareBrowserAudio\(\);[\s\S]+this\.run\('originate'/);
assert.match(viewSource, /const snapshot = this\.state\.snapshot/);
assert.doesNotMatch(viewSource, /syncMedia\(snapshot\)/);
assert.match(viewSource, /await this\.syncMedia\(\)/);
assert.match(viewSource, /\(!this\.pendingMediaStream && !this\.media\.hasAudio\(\)\)/);
assert.match(viewSource, /this\.media\.isConnected\(\)/);
assert.match(viewSource, /if \(this\.mediaStartRequest\)\s+await this\.mediaStartRequest;/);
assert.match(viewSource, /this\.mediaStreamRequest = navigator\.mediaDevices\.getUserMedia/);
assert.match(viewSource, /this\.mediaStartRequest = \(async \(\) =>/);
assert.doesNotMatch(viewSource, /capabilityRetryDeadline/);
assert.match(viewSource, /startMedia\(\) \{[\s\S]+if \(this\.state\.mediaStatus !== 'ready'\)/);
assert.match(viewSource, /this\.refs\.mediaAction\.disabled = this\.state\.mediaStatus !== 'ready'/);
assert.doesNotMatch(viewSource, /\[ 'idle', 'disabled' \]\.indexOf\(model\.state\)[\s\S]+this\.refs\.dial\.value = ''/);
assert.doesNotMatch(viewSource, /crypto\.randomUUID\(\)/);
assert.match(viewSource, /new form\.Map\('qmodem_voip'\)/);
assert.match(viewSource, /voiceMap\.section\(form\.NamedSection, 'main', 'main'/);
assert.match(viewSource, /section\.option\(form\.Flag, 'enabled'/);
assert.match(viewSource, /await this\.createServiceMap\(\)\.render\(\)/);
assert.doesNotMatch(viewSource, /Date\.now\(\)\s*-\s*this\.(call|active)/);
assert.match(viewSource, /this\.updateTimer\(model\.callDurationSeconds\)/);
const cssSource = fs.readFileSync(path.resolve(__dirname, '../htdocs/luci-static/resources/qmodem-voip/qmodem-voip.css'), 'utf8');
assert.doesNotMatch(cssSource, /--qvoip-(surface|text|accent|status)/);
assert.match(cssSource, /\.qvoip-page \.cbi-section/);
assert.match(cssSource, /\.qvoip-keypad \.cbi-button/);

const rpcSource = fs.readFileSync(path.resolve(__dirname, '../htdocs/luci-static/resources/qmodem-voip/rpc.js'), 'utf8');
assert.match(rpcSource, /modem_id/);
assert.match(rpcSource, /selectModem/);
assert.doesNotMatch(rpcSource, /generate_credentials/);

const sipViewSource = fs.readFileSync(path.resolve(__dirname, '../../luci-app-qmodem-sipd/htdocs/luci-static/resources/view/qmodem-sipd/sip.js'), 'utf8');
assert.match(sipViewSource, /new form\.Map\('qmodem_sip'/);
assert.match(sipViewSource, /form\.GridSection,'group'/);
assert.match(sipViewSource, /form\.GridSection,'direction'/);
assert.match(sipViewSource, /uci\.sections\('network','interface'\)/);
assert.match(sipViewSource, /qmodem\.sip\.provision/);
assert.match(sipViewSource, /Preview and enroll/);

const menu = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../root/usr/share/luci/menu.d/luci-app-qmodem-voip.json'), 'utf8'));
assert.ok(menu['admin/modem/qmodem/qmodem-voip']);
assert.equal(menu['admin/modem/qmodem/qmodem-sipd'], undefined);
const sipMenu = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../../luci-app-qmodem-sipd/root/usr/share/luci/menu.d/luci-app-qmodem-sipd.json'), 'utf8'));
assert.ok(sipMenu['admin/modem/qmodem/qmodem-sipd']);
assert.equal(menu['admin/modem/advanced/qmodem-voip'].title, undefined);
assert.deepEqual(menu['admin/modem/advanced/qmodem-voip'].action, {
	type: 'alias',
	path: 'admin/modem/qmodem/qmodem-voip'
});

console.log('PASS: qmodem voip reducer contract');
