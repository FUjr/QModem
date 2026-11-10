'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require rpc';
const sipStatus = rpc.declare({object:'qmodem.sip',method:'status',expect:{}});
const migrationStatus = rpc.declare({object:'qmodem.sip.provision',method:'migration_status',expect:{}});
const migrate = rpc.declare({object:'qmodem.sip.provision',method:'migrate',params:['modem_id'],expect:{}});
const preview = rpc.declare({object:'qmodem.sip.provision',method:'preview',params:['config','modem_id','interface'],expect:{}});
const apply = rpc.declare({object:'qmodem.sip.provision',method:'apply',params:['config','modem_id','interface'],expect:{}});

return view.extend({
 load() {
  return Promise.all([uci.load('qmodem'), uci.load('network'), uci.load('qmodem_sip'), L.resolveDefault(sipStatus(), {}), migrationStatus(), L.resolveDefault(uci.load('qmodem_voip'), null)]);
 },
 createMap() {
  const map = new form.Map('qmodem_sip', _('SIP'), _('Configure an account once, then select voice and SMS routes for its modem. Each modem uses independent accounts.'));
  map.chain('qmodem_voip');
  const tabs = map.section(form.NamedSection, 'main', 'sipd');
  for (const [id, title] of [['connections', _('SIP connections')], ['voice', _('Voice')], ['sms', _('SMS')], ['advanced', _('Advanced')]]) tabs.tab(id, title);
  const grid = (tab, title) => {
   const field = tabs.taboption(tab, form.SectionValue, '_' + tab, form.GridSection, 'direction', title);
   field.subsection.anonymous = true;
   field.subsection.addremove = tab === 'connections';
   field.subsection.filter = id => !!uci.get('qmodem_sip', id, 'group') || !!uci.get('qmodem_sip', id, 'direction');
   return field.subsection;
  };
  const connections = grid('connections', _('Accounts and modem binding'));
  let o = connections.option(form.Value, 'label', _('Name')); o.editable = true;
  o = connections.option(form.ListValue, '_modem', _('Modem')); o.editable = true; o.rmempty = false;
  for (const device of uci.sections('qmodem', 'modem-device')) o.value(device['.name'], device.name || device['.name']);
  o.cfgvalue = id => uci.get('qmodem_sip', uci.get('qmodem_sip', id, 'group'), 'modem_id');
  o.write = (id, modem) => {
   const existing = uci.sections('qmodem_sip', 'group').find(g => g.modem_id === modem);
   const group = existing ? existing['.name'] : 'sip_' + modem;
   if (!existing) uci.add('qmodem_sip', 'group', group);
   uci.set('qmodem_sip', group, 'modem_id', modem);
   uci.set('qmodem_sip', id, 'group', group);
  };
  o = connections.option(form.ListValue, 'direction', _('Connection type')); o.editable = true; o.default = 'outbound'; o.rmempty = false;
  o.value('inbound', _('Client direct connection')); o.value('outbound', _('External SIP server'));
  for (const [key, title] of [['server', _('Server')], ['port', _('Server TLS port')], ['username', _('Account')], ['password', _('Password')], ['realm', _('Realm')]]) {
   o = connections.option(form.Value, key, title); o.modalonly = true;
   if (['server', 'port', 'realm'].includes(key)) o.depends('direction', 'outbound');
   if (key === 'password') o.password = true;
   if (key === 'port') { o.datatype = 'port'; o.default = '5061'; }
   if (key === 'server') o.datatype = 'host';
   if (key === 'username' || key === 'password' || key === 'server') o.rmempty = false;
  }
  for (const [tab, title, flags] of [
   ['voice', _('Voice routes'), [['receive_voice', _('Ring on cellular incoming calls')], ['send_voice', _('Allow cellular outgoing calls')]]],
   ['sms', _('SMS routes'), [['sms_enabled', _('Allow sending SMS')], ['receive_sms', _('Forward received SMS')]]]
  ]) {
   const section = grid(tab, title);
   for (const [key, title] of [['label', _('Connection')], ['_modem', _('Modem')], ['direction', _('Connection type')]]) { const field = section.option(form.DummyValue, key, title); if (key === '_modem') field.cfgvalue = id => uci.get('qmodem_sip', uci.get('qmodem_sip', id, 'group'), 'modem_id'); }
   for (const [key, title] of flags) { o = section.option(form.Flag, key, title); o.rmempty = false; o.default = '0'; o.editable = true; }
   if (tab === 'sms') {
    o = section.option(form.Value, 'sms_recipient_uri', _('Receive destination SIP URI')); o.editable = true;
    o.placeholder = _('Automatic for SIP Gateway Manager');
    o.validate = (id, value) => !value || /^sips?:[^\s@]+@[^\s]+$/.test(value) || _('Enter a valid SIP URI.');
   }
  }
  const advanced = grid('advanced', _('Connection settings'));
  advanced.option(form.DummyValue, 'label', _('Connection'));
  o = advanced.option(form.ListValue, 'interface', _('Network interface')); o.editable = true;
  o.value('', _('Automatic (LAN for direct clients, WAN for external server)'));
  o.rmempty = true;
  for (const network of uci.sections('network', 'interface')) o.value(network['.name']);
  o = advanced.option(form.Value, 'listen_port', _('Local SIP port')); o.editable = true; o.datatype = 'range(1024,65535)'; o.placeholder = _('Automatic');
  o.description = _('Automatic ports start at 5060 in connection order. Set a fixed port for direct clients.');
  o = advanced.option(form.Value, 'rtp_start', _('Local RTP port')); o.editable = true; o.datatype = 'range(1024,65534)'; o.placeholder = _('Automatic');
  o = advanced.option(form.Value, 'register_interval', _('Registration interval')); o.editable = true; o.datatype = 'range(60,3600)'; o.default = '300';
  const parse = map.parse.bind(map);
  map.parse = async () => {
   if (this.migrationPending) throw new Error(_('Complete the legacy SIP migration before editing connections.'));
   await parse();
   const accounts = new Map(), routes = new Set(), ports = new Set(), rtps = new Set();
   const directions = uci.sections('qmodem_sip', 'direction').filter(d => d.group);
   for (const c of directions) {
    if (c.listen_port) { if (ports.has(+c.listen_port)) throw new Error(_('Local SIP ports must be unique.')); ports.add(+c.listen_port); }
    if (c.rtp_start) { const p = +c.rtp_start; if (rtps.has(p) || rtps.has(p + 1)) throw new Error(_('Local RTP ports must not overlap.')); rtps.add(p); rtps.add(p + 1); }
   }
   for (const c of directions) {
    const id = c['.name'], modem = uci.get('qmodem_sip', c.group, 'modem_id');
    const route = modem + ':' + c.direction;
    if (!modem || routes.has(route)) throw new Error(_('Use one direct and one external SIP account per modem.'));
    routes.add(route);
    const voice = c.receive_voice === '1' || c.send_voice === '1';
    uci.set('qmodem_sip', id, 'voip_enabled', voice ? '1' : '0');
    uci.set('qmodem_sip', id, 'transport', c.direction === 'inbound' ? 'udp_tcp' : 'tls');
    if (!c.interface) uci.set('qmodem_sip', id, 'interface', c.direction === 'inbound' ? 'lan' : 'wan');
    if (!c.realm) uci.set('qmodem_sip', id, 'realm', '*');
    if (!c.port) uci.set('qmodem_sip', id, 'port', '5061');
    let port = c.direction === 'inbound' ? 5060 : 5061, rtp = 40000;
    while (ports.has(port) || rtps.has(port)) port++;
    while (rtps.has(rtp) || rtps.has(rtp + 1) || ports.has(rtp) || ports.has(rtp + 1)) rtp += 4;
    if (!c.listen_port) { if (port > 65535) throw new Error(_('No free SIP port.')); uci.set('qmodem_sip', id, 'listen_port', '' + port); ports.add(port); }
    if (!c.rtp_start) { if (rtp > 65534) throw new Error(_('No free RTP port.')); uci.set('qmodem_sip', id, 'rtp_start', '' + rtp); rtps.add(rtp); rtps.add(rtp + 1); }
    if (!(voice || c.sms_enabled === '1' || c.receive_sms === '1')) continue;
    if (!/^[A-Za-z0-9_.-]{1,63}$/.test(c.username || '') || !/^[!-~]{8,127}$/.test(c.password || '')) throw new Error(_('Configure a valid account and a password of 8 to 127 printable characters without spaces.'));
    if (c.direction === 'outbound' && !c.server) throw new Error(_('Enter a SIP server.'));
    const key = c.direction + ':' + (c.server || '') + ':' + c.username;
    if (accounts.has(key) && accounts.get(key) !== modem) throw new Error(_('Different modems must use independent SIP accounts.'));
    accounts.set(key, modem);
   }
   for (const port of ports) if (rtps.has(port)) throw new Error(_('SIP and RTP ports must not overlap.'));
   // Keep voice workers independent of SIP registration and SMS readiness.
   if (uci.get('qmodem_voip', 'main')) {
    for (const group of uci.sections('qmodem_sip', 'group')) {
     const bound = directions.filter(d => d.group === group['.name']);
     if (!uci.get('qmodem_voip', group['.name'])) uci.add('qmodem_voip', 'modem', group['.name']);
     uci.set('qmodem_voip', group['.name'], 'modem_id', group.modem_id);
     uci.set('qmodem_voip', group['.name'], 'enabled', bound.some(d => d.receive_voice === '1' || d.send_voice === '1') ? '1' : '0');
     if (!uci.get('qmodem_voip', group['.name'], 'interface')) uci.set('qmodem_voip', group['.name'], 'interface', 'lan');
    }
   }
  };
  return map;
 },
 async render(data) {
  const modems = uci.sections('qmodem', 'modem-device'), networks = uci.sections('network', 'interface');
  const text=E('textarea',{class:'cbi-input-textarea',rows:10,placeholder:_('Paste gateway provisioning JSON here')});
  const modem=E('select',{class:'cbi-input-select'},modems.map(m=>E('option',{value:m['.name']},[m.name+' ('+m['.name']+')'])));
  const network=E('select',{class:'cbi-input-select'},networks.map(n=>E('option',{value:n['.name']},[n['.name']])));
  const result=E('div');
  const upload=E('input',{type:'file',accept:'.json,application/json',change:async ev=>{
   const file=ev.target.files[0];if(!file)return;if(file.size>16384){ui.addNotification(null,E('p',{},[_('Configuration file is too large.')]),'error');return;}text.value=await file.text();
  }});
  const importButton=E('button',{class:'cbi-button cbi-button-apply',click:async()=>{
   try {
    const p=await preview(text.value,modem.value,network.value);
    if(p.status!=='preview')throw new Error(p.error||_('Invalid provisioning'));
    ui.showModal(_('Confirm SIP enrollment'),[
     E('p',{},[`${p.modem_id} → ${p.username}@${p.server}:${p.port}`]),
     E('p',{},[`${_('Network')}: ${p.interface}; ${_('Voice')}: ${p.voip_enabled}; SMS: ${p.sms_enabled}`]),
     E('p',{},[_('Only the selected modem group is updated. Existing database SMS mode is preserved.')]),
     E('div',{class:'right'},[
      E('button',{class:'btn',click:ui.hideModal},[_('Cancel')]),
      E('button',{class:'btn cbi-button-apply',click:async()=>{
       try {const r=await apply(text.value,modem.value,network.value);if(r.status!=='success')throw new Error(r.error);ui.hideModal();text.value='';result.replaceChildren(E('p',{},[_('Enrollment saved. SIP connects independently of voice readiness.')]));await uci.unload('qmodem_sip');location.reload();}
       catch(e){ui.addNotification(null,E('p',{},[e.message]),'error');}
      }},[_('Apply')])])]);
   } catch(e) {ui.addNotification(null,E('p',{},[e.message]),'error');}
  }},[_('Preview and enroll')]);
  const migration = data[4] || {};
  this.migrationPending = !['current', 'none'].includes(migration.status);
  const messages = {
   pending_changes: _('Apply or revert pending modem and SIP settings before migrating.'),
   select_modem: _('Select the modem used by the legacy SIP configuration.'),
   invalid_modem: _('The selected modem no longer exists.'),
   modem_missing: _('The modem referenced by the legacy configuration no longer exists.'),
   voice_sms_modem_mismatch: _('Legacy voice and SMS use different modems. Resolve the binding before migrating.'),
   multiple_sms_destinations: _('Legacy SMS routes have different modems or destinations. Resolve these routes before migrating.'),
   invalid_sms_route: _('A legacy SIP SMS route is invalid. Correct its direction and destination first.'),
   sms_connection_missing: _('A legacy SMS route has no configured SIP connection.'),
   sms_connection_disabled: _('A legacy SMS route refers to a disabled SIP connection.'),
   duplicate_direction: _('Legacy connections share the same modem and direction. Resolve duplicate accounts before migrating.'),
   duplicate_account: _('Different modems must use independent SIP accounts.'),
   duplicate_port: _('SIP and RTP ports must be unique and must not overlap.'),
   connection_validation_failed: _('Legacy credentials or ports do not meet the new connection requirements. Correct them before migrating.'),
   write_failed: _('Could not write the staged configuration. Existing settings are unchanged.')
  };
  let notice = null;
  if (this.migrationPending) {
   const modem = E('select', { class: 'cbi-input-select' }, [E('option', { value: '' }, [_('Automatic')])]);
   for (const device of uci.sections('qmodem', 'modem-device')) modem.appendChild(E('option', { value: device['.name'] }, [device.name || device['.name']]));
   const detail = E('p', {}, [messages[migration.reason] || _('Legacy SIP settings are ready to migrate. Accounts, ports and routes will be preserved.')]);
   const button = E('button', { class: 'btn cbi-button-positive', click: async () => {
    button.disabled = true;
    try {
     const result = await migrate(modem.value);
     if (['migrated', 'current', 'none'].includes(result.status)) {
      ui.showModal(_('SIP configuration migrated'), [E('p', {}, [_('Reloading SIP services. This page will refresh shortly.')])]);
      window.setTimeout(() => window.location.reload(), 4000);
     } else { detail.textContent = messages[result.reason] || _('Migration failed. Existing settings are unchanged.'); button.disabled = false; }
    } catch (e) { detail.textContent = e.message; button.disabled = false; }
   } }, [_('Migrate legacy SIP settings')]);
   notice = E('div', { class: 'alert-message warning' }, [detail, modem, ' ', button]);
  }
  const rows = (data[3]?.directions || []).map(state => E('li', {}, [
   (uci.get('qmodem_sip', state.group, 'modem_id') || state.group) + ' / ' + state.direction + ': ' +
   (state.registered ? _('Registered') : state.running ? _('Running') : state.enabled ? _('Waiting') : _('Disabled'))]));
  return E('div', {}, [notice, E('ul', {}, rows), E('div', { class: 'cbi-section' }, [E('h3', {}, [_('Quick enrollment')]), E('p', {}, [_('Import an account exported from SIP Gateway Manager to manage Asterisk voice and SMS routing on the web.')]), E('a', { href: 'https://github.com/FUjr/sip-gateway-manager', target: '_blank', rel: 'noopener noreferrer' }, ['SIP Gateway Manager']), modem, network, upload, text, importButton, result]), await this.createMap().render()].filter(Boolean));
 }
});
