'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require rpc';

const status = rpc.declare({object:'qmodem.sip',method:'status',expect:{}});
const preview = rpc.declare({object:'qmodem.sip.provision',method:'preview',params:['config','modem_id','interface'],expect:{}});
const apply = rpc.declare({object:'qmodem.sip.provision',method:'apply',params:['config','modem_id','interface'],expect:{}});

return view.extend({
 load: function() { return Promise.all([uci.load('qmodem'),uci.load('qmodem_sip'),uci.load('network'),L.resolveDefault(status(),{})]); },
 render: function(data) {
  const modems=uci.sections('qmodem','modem-device'), networks=uci.sections('network','interface');
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
  const map=new form.Map('qmodem_sip',_('SIP service'),_('Each group binds one local modem. SMS or voice enables its SIP direction. TLS server certificates are verified.'));
  let s=map.section(form.GridSection,'group',_('Modem groups'));s.addremove=true;s.anonymous=false;
  let o=s.option(form.ListValue,'modem_id',_('Local modem'));o.rmempty=false;modems.forEach(m=>o.value(m['.name'],m.name+' ('+m['.name']+')'));
  s=map.section(form.GridSection,'direction',_('SIP directions'));s.addremove=true;s.anonymous=false;
  o=s.option(form.ListValue,'group',_('Modem group'));o.rmempty=false;uci.sections('qmodem_sip','group').forEach(g=>o.value(g['.name']));
  o=s.option(form.ListValue,'direction',_('Direction'));o.value('inbound',_('Inbound'));o.value('outbound',_('Outbound'));o.rmempty=false;
  ['sms_enabled','voip_enabled'].forEach(key=>{o=s.option(form.Flag,key,key==='sms_enabled'?_('SMS'):_('Voice'));o.default='0';o.rmempty=false;});
  o=s.option(form.ListValue,'interface',_('Network'));networks.forEach(n=>o.value(n['.name']));o.rmempty=false;
  o=s.option(form.Value,'listen_port',_('Local SIP port'));o.datatype='range(1024,65535)';o.rmempty=false;
  o=s.option(form.Value,'rtp_start',_('Local RTP port'));o.datatype='range(1024,65534)';o.rmempty=false;
  o=s.option(form.ListValue,'transport',_('Transport'));o.value('udp_tcp','UDP/TCP');o.value('tls','TLS');o.rmempty=false;
  ['server','port','username','password','realm','register_interval'].forEach(key=>{o=s.option(form.Value,key,_(key));o.password=key==='password';if(key==='port')o.datatype='port';if(key==='register_interval'){o.datatype='range(60,3600)';o.default='300';}});
  const originalSave=map.save.bind(map);
  map.save=async function() {
   await originalSave();
   try { await uci.load('qmodem_voip'); } catch(e) { return; }
   for(const g of uci.sections('qmodem_sip','group')) {
    const directions=uci.sections('qmodem_sip','direction').filter(d=>d.group===g['.name']);
    if(!uci.get('qmodem_voip',g['.name']))uci.add('qmodem_voip','modem',g['.name']);
    uci.set('qmodem_voip',g['.name'],'modem_id',g.modem_id);
    uci.set('qmodem_voip',g['.name'],'enabled',directions.some(d=>d.voip_enabled==='1')?'1':'0');
    if(directions[0])uci.set('qmodem_voip',g['.name'],'interface',directions[0].interface);
   }
   await uci.save();
  };
  const rows=(data[3].directions||[]).map(d=>E('tr',{},[E('td',{},[d.group]),E('td',{},[d.direction]),E('td',{},[d.running?(d.registered?_('Registered'):_('Running')):(d.enabled?_('Waiting'):_('Disabled'))])]));
  return map.render().then(node=>E('div',{},[
   E('h2',{},[_('SIP service')]),
   E('table',{class:'table'},[E('tr',{class:'tr table-titles'},[E('th',{},[_('Group')]),E('th',{},[_('Direction')]),E('th',{},[_('Status')])]),...rows]),
   E('div',{class:'cbi-section'},[E('h3',{},[_('Quick enrollment')]),E('p',{},[_('Import the configuration generated for a gateway modem account.')]),modem,network,upload,text,importButton,result]),node
  ]));
 }
});
