'use strict';
import { cursor } from 'uci';
import { readfile } from 'fs';

// Work only on the caller's private staging directory, never live UCI files.
const ctx = cursor(ARGV[0], ARGV[0] + '/.uci');
const override = ARGV[1];
function result(status, reason) {
 print(sprintf('%J\n', { status, reason: reason || '' }));
 exit(0);
}
let existing = [];
ctx.foreach('qmodem_sip', 'connection', s => push(existing, s));
let groups = [];
ctx.foreach('qmodem_sip', 'group', s => push(groups, s));
if (length(groups) && !length(existing) && ctx.get('qmodem_sip', 'main', 'schema_version') == '3') result('current');

let modems = {}, eligible = [];
ctx.foreach('qmodem', 'modem-device', s => {
 modems[s['.name']] = s;
 if ((s.name == 'rm520n-gl' || s.name == 'rg500q-ea') && s.data_interface == 'usb')
  push(eligible, s['.name']);
});
if (override && !modems[override]) result('invalid', 'invalid_modem');
let voiceModem = ctx.get('qmodem_voip', 'main', 'modem_id');
const journal = readfile(getenv('QMODEM_VOIP_JOURNAL') || '/var/lib/qmodem_voip/modem-safety.journal') || '';
const slot = match(journal, /(^|\n)slot=([0-9.-]+)(\n|$)/);
if (!voiceModem && slot)
 for (let id, modem in modems)
  if (replace(modem.path || '', /\/$/, '') == '/sys/bus/usb/devices/' + slot[2]) voiceModem = id;

let directions = {}, forwards = [];
for (let direction in ['inbound', 'outbound']) {
 let old = ctx.get_all('qmodem_sip', direction);
 if (old) directions[direction] = old;
}
const oldest = ctx.get_all('qmodem_voip', 'sip');
if (oldest) {
 const direction = oldest.mode == 'outbound' ? 'outbound' : 'inbound';
 let old = directions[direction];
 if (!old || (old.enabled != '1' && !(old.username && old.password))) {
  old = { enabled: oldest.enabled || '0', interface: oldest.interface,
   username: oldest.username, password: oldest.password, voip_enabled: '1',
   sms_enabled: '0', listen_port: oldest.listen_port || (direction == 'inbound' ? '5060' : '5061') };
  if (direction == 'outbound')
   for (let key in ['server', 'port', 'transport', 'username', 'password', 'realm', 'register_interval'])
    old[key] = oldest['outbound_' + key];
  directions[direction] = old;
 }
}
if (ctx.get('sms_forwarder', 'sms_forward', 'enable') == '1')
 ctx.foreach('sms_forwarder', 'sms_forward_instance', s => {
  if (s.enable != '1' || s.api_type != 'sip') return;
  let config;
  try { config = json(s.api_config || '{}'); }
  catch (e) { result('conflict', 'invalid_sms_route'); }
  if (!config || (config.direction != 'inbound' && config.direction != 'outbound') || !config.recipient_uri)
   result('conflict', 'invalid_sms_route');
  push(forwards, { id: s['.name'], modem: s.modem_cfg, direction: config.direction, uri: config.recipient_uri });
 });

let planned = [];
if (length(groups) && !length(existing)) ctx.foreach('qmodem_sip', 'direction', c => {
 if (!c.group) return;
 c.modem_id = ctx.get('qmodem_sip', c.group, 'modem_id');
 if (!modems[c.modem_id]) result('conflict', 'modem_missing');
 c.enabled = '1';
 c.send_voice ??= c.voip_enabled || '0'; c.receive_voice ??= c.voip_enabled || '0';
 let routes = filter(forwards, route => route.modem == c.modem_id && route.direction == c.direction);
 for (let route in routes) {
  if (c.sms_recipient_uri && c.sms_recipient_uri != route.uri) result('conflict', 'multiple_sms_destinations');
  c.sms_recipient_uri = route.uri;
 }
 c.receive_sms ??= length(routes) ? '1' : '0';
 push(planned, { id: c['.name'], values: c });
});
for (let connection in existing) {
 if (!modems[connection.modem_id]) result('conflict', 'modem_missing');
 push(planned, { id: connection['.name'], values: connection });
}
for (let direction in (length(existing) || length(groups)) ? [] : ['inbound', 'outbound']) {
 const old = directions[direction];
 const routes = filter(forwards, s => s.direction == direction);
 if (!old || (old.enabled != '1' && !(old.username && old.password))) {
  if (length(routes)) result('conflict', 'sms_connection_missing');
  continue;
 }
 let modem = old.sms_modem || override || (old.voip_enabled == '1' ? voiceModem : null);
 if (!modem && length(routes)) modem = routes[0].modem;
 if (!modem && length(eligible) == 1) modem = eligible[0];
 if (!modem) result('needs_modem', 'select_modem');
 if (!modems[modem]) result('conflict', 'modem_missing');
 if (old.voip_enabled == '1' && voiceModem && modem != voiceModem)
  result('conflict', 'voice_sms_modem_mismatch');
 let uri;
 for (let route in routes) {
  if (route.modem != modem || (uri && uri != route.uri)) result('conflict', 'multiple_sms_destinations');
  uri = route.uri;
 }
 let connection = { modem_id: modem, direction, enabled: old.enabled || '0',
  label: direction == 'inbound' ? 'Local SIP' : 'External SIP',
  transport: direction == 'inbound' ? 'udp_tcp' : 'tls',
  voip_enabled: old.voip_enabled == '1' ? '1' : '0',
  receive_voice: old.voip_enabled == '1' ? (old.receive_voice || '1') : '0',
  send_voice: old.voip_enabled == '1' ? (old.send_voice || '1') : '0',
  sms_enabled: old.sms_enabled || '0', receive_sms: length(routes) ? '1' : '0' };
 if (length(routes) && connection.enabled != '1') result('conflict', 'sms_connection_disabled');
 for (let key in ['interface', 'listen_port', 'server', 'port', 'username', 'password', 'realm', 'register_interval'])
  if (old[key] != null) connection[key] = old[key];
 if (uri) connection.sms_recipient_uri = uri;
 push(planned, { id: 'legacy_' + direction, values: connection });
}
if (!length(planned)) result('none');
for (let route in forwards) {
 let matches = filter(planned, p => p.values.modem_id == route.modem && p.values.direction == route.direction);
 if (length(matches) != 1) result('conflict', 'sms_connection_missing');
 let c = matches[0].values;
 if (c.enabled != '1') result('conflict', 'sms_connection_disabled');
 if (c.sms_recipient_uri && c.sms_recipient_uri != route.uri) result('conflict', 'multiple_sms_destinations');
 c.receive_sms = '1'; c.sms_recipient_uri = route.uri;
}
if (!ctx.get_all('qmodem_sip', 'main')) ctx.set('qmodem_sip', 'main', 'sipd');
let bindings = {}, routes = {}, ports = [], rtps = [], accounts = {};
for (let g in groups) {
 if (bindings[g.modem_id]) result('conflict', 'duplicate_direction');
 bindings[g.modem_id] = g['.name'];
}
// Validate the complete plan before modifying even the private staged files.
for (let plan in planned) {
 let c = plan.values, modem = c.modem_id, group = bindings[modem] || 'sip_' + modem;
 if (length(group) > 47) result('invalid', 'invalid_modem');
 if (c.direction != 'inbound' && c.direction != 'outbound') result('invalid', 'invalid_sms_route');
 let key = group + ':' + c.direction;
 if (routes[key]) result('conflict', 'duplicate_direction');
 routes[key] = true; bindings[modem] = group;
 if (c.listen_port) push(ports, int(c.listen_port));
 if (c.rtp_start) push(rtps, int(c.rtp_start));
 if (c.enabled == '1') {
  let account = c.direction + ':' + (c.server || '') + ':' + c.username;
  if (accounts[account] && accounts[account] != modem) result('conflict', 'duplicate_account');
  accounts[account] = modem;
 }
}
for (let plan in planned) {
 let c = plan.values, modem = c.modem_id, group = bindings[modem];
 let port = c.direction == 'inbound' ? 5060 : 5061, rtp = 40000;
 while (index(ports, port) >= 0 || index(rtps, port) >= 0 || index(rtps, port - 1) >= 0) port++;
 while (index(rtps, rtp) >= 0 || index(rtps, rtp - 1) >= 0 || index(rtps, rtp + 1) >= 0 || index(ports, rtp) >= 0 || index(ports, rtp + 1) >= 0) rtp += 4;
 if (!c.listen_port) { c.listen_port = '' + port; push(ports, port); }
 if (!c.rtp_start) { c.rtp_start = '' + rtp; push(rtps, rtp); }
 const enabled = c.enabled == '1';
 ctx.set('qmodem_sip', group, 'group');
 ctx.set('qmodem_sip', group, 'modem_id', modem);
 // Replace each connection in place. No parallel schema remains active.
 if (ctx.get('qmodem_sip', plan.id)) ctx.delete('qmodem_sip', plan.id);
 ctx.set('qmodem_sip', plan.id, 'direction');
 for (let key in ['label', 'interface', 'listen_port', 'rtp_start', 'server', 'port', 'username', 'password', 'realm', 'register_interval', 'sms_recipient_uri'])
  if (c[key] != null) ctx.set('qmodem_sip', plan.id, key, c[key]);
 ctx.set('qmodem_sip', plan.id, 'group', group);
 ctx.set('qmodem_sip', plan.id, 'direction', c.direction);
 ctx.set('qmodem_sip', plan.id, 'transport', c.direction == 'inbound' ? 'udp_tcp' : 'tls');
 ctx.set('qmodem_sip', plan.id, 'interface', c.interface || (c.direction == 'inbound' ? 'lan' : 'wan'));
 ctx.set('qmodem_sip', plan.id, 'port', c.port || '5061');
 ctx.set('qmodem_sip', plan.id, 'realm', c.realm || '*');
 ctx.set('qmodem_sip', plan.id, 'register_interval', c.register_interval || '300');
 for (let key in ['voip_enabled', 'send_voice', 'receive_voice', 'sms_enabled', 'receive_sms'])
  ctx.set('qmodem_sip', plan.id, key, enabled && c[key] == '1' ? '1' : '0');
 if (enabled && (c.sms_enabled == '1' || c.receive_sms == '1')) {
  ctx.set('qmodem', modem, 'use_ubus', '1');
  if (!modems[modem].sms_mode || modems[modem].sms_mode == 'direct') ctx.set('qmodem', modem, 'sms_mode', 'database_poll');
 }
 if (ctx.get_all('qmodem_voip', 'main')) {
  if (!ctx.get('qmodem_voip', group)) ctx.set('qmodem_voip', group, 'modem');
  ctx.set('qmodem_voip', group, 'modem_id', modem);
  if (enabled && c.voip_enabled == '1') ctx.set('qmodem_voip', group, 'enabled', '1');
  else if (!ctx.get('qmodem_voip', group, 'enabled')) ctx.set('qmodem_voip', group, 'enabled', '0');
  ctx.set('qmodem_voip', group, 'interface', ctx.get('qmodem_voip', group, 'interface') || ctx.get('qmodem_voip', 'main', 'interface') || 'lan');
 }
}
// Old sections without a group are ignored by the new service, retained for diagnosis.
ctx.set('qmodem_sip', 'main', 'schema_version', '3');
for (let route in forwards) ctx.set('sms_forwarder', route.id, 'enable', '0');
for (let package in ['qmodem_sip', 'qmodem_voip', 'sms_forwarder', 'qmodem'])
 if (!ctx.commit(package)) result('invalid', 'write_failed');
result('ready');
