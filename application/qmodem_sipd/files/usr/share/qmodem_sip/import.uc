'use strict';
import { cursor } from 'uci';
import { stat, readfile, writefile, chmod, unlink, popen, mkdtemp, rmdir } from 'fs';

function reject(message) { die(message); }
function identifier(value) { return type(value) == 'string' && match(value, /^[a-zA-Z0-9_]{1,48}$/); }
function bounded(value, low, high) { return type(value) == 'int' && value >= low && value <= high; }
function checked(value, pattern, label) {
 if (type(value) != 'string' || !match(value, pattern)) reject(`Invalid ${label}`);
 return value;
}
let staging;
try {
 let request = json(readfile('/dev/stdin'));
 if (type(request) != 'object' || !identifier(request.modem_id) || !identifier(request.interface)) reject('Choose a local modem and network');
 if (type(request.config) != 'string' || length(request.config) > 16384) reject('Invalid JSON size');
 let value = json(request.config);
 let fields = ['schema_version','account_id','server','port','transport','username','password','realm','register_interval','sms_enabled','voip_enabled','sms_ingress_uri'];
 if (type(value) != 'object' || length(keys(value)) != length(fields)) reject('Unexpected or missing provisioning fields');
 for (let key in keys(value)) if (index(fields,key) < 0) reject(`Unsupported field ${key}`);
 if (value.schema_version != 1 || type(value.schema_version) != 'int' || value.transport != 'tls') reject('Only provisioning v1 with verified TLS is supported');
 checked(value.account_id,/^[a-z][a-z0-9_]{0,47}$/,'account ID');
 checked(value.username,/^[a-z][a-z0-9_]{0,47}$/,'username');
 checked(value.password,/^[A-Za-z0-9_-]{16,128}$/,'password');
 checked(value.server,/^[A-Za-z0-9][A-Za-z0-9.-]{0,251}[A-Za-z0-9]$/,'hostname');
 checked(value.realm,/^[A-Za-z0-9_.-]{1,64}$/,'realm');
 if (!bounded(value.port,1024,65535) || !bounded(value.register_interval,60,3600)) reject('Invalid port or interval');
 if (type(value.sms_enabled) != 'bool' || type(value.voip_enabled) != 'bool') reject('Feature flags must be boolean');
 let expected = sprintf('sips:sms@%s:%d;transport=tls',value.server,value.port);
 if (value.sms_ingress_uri != expected) reject('SMS ingress must use the same verified TLS server');
 let ctx = cursor();
 let modem = ctx.get_all('qmodem',request.modem_id);
 if (!modem || modem['.type'] != 'modem-device') reject('Local modem does not exist');
 if (ctx.get('network',request.interface) != 'interface') reject('Local network does not exist');
 if (value.voip_enabled && (modem.name != 'rm520n-gl' || modem.data_interface != 'usb' || !modem.at_port || !modem.voice_pcm_port)) reject('This local modem has no supported voice AT/PCM profile');
 if(length(request.modem_id)>40)reject('Local modem ID is too long for a SIP group');
 let group = 'sip_' + request.modem_id;
 let duplicates = [];
 ctx.foreach('qmodem_sip','group', s => { if (s.modem_id == request.modem_id && s['.name'] != group) push(duplicates,s['.name']); });
 if (length(duplicates)) reject('Modem already belongs to another SIP group');
 let port=5061,rtp=40000;
 let existing=ctx.get_all('qmodem_sip',group+'_out');
 if(existing){port=int(existing.listen_port);rtp=int(existing.rtp_start);}
 else {
  let used=[],rtps=[];
  ctx.foreach('qmodem_sip','direction',s=>{push(used,int(s.listen_port));push(rtps,int(s.rtp_start));});
  while(index(used,port)>=0) port++;
  while(index(rtps,rtp)>=0 || index(rtps,rtp+1)>=0) rtp+=4;
 }
 if(port>65535 || rtp>65530)reject('No free local SIP/RTP ports');
 let summary={status:'preview',group,modem_id:request.modem_id,interface:request.interface,server:value.server,port:value.port,username:value.username,sms_enabled:value.sms_enabled,voip_enabled:value.voip_enabled,listen_port:port,rtp_start:rtp};
 if(ARGV[0]=='preview'){print(sprintf('%J\n',summary));exit(0);}
 if (value.voip_enabled && (!stat('/etc/init.d/qmodem_voip') || !stat('/etc/config/qmodem_voip'))) reject('Install qmodem-voip for voice enrollment');
 if (value.sms_enabled && (!stat('/etc/init.d/qmodem-smsd') || !stat('/etc/init.d/sms_forwarder') || !stat('/etc/config/sms_forwarder'))) reject('Install qmodem-smsd and sms-forwarder-next for SMS enrollment');
 let names=['qmodem_sip','qmodem'];
 if(stat('/etc/config/qmodem_voip'))push(names,'qmodem_voip');
 if(stat('/etc/config/sms_forwarder'))push(names,'sms_forwarder');
 let backup={};
 for(let name in names)backup[name]=readfile('/etc/config/'+name);
 staging=mkdtemp('/tmp/qmodem-sip-import.XXXXXX');
 if(!staging)reject('Unable to create private staging directory');
 chmod(staging,0700);
 ctx=cursor('/etc/config',staging);
 function set(config,section,option,value){if(!(option == null ? ctx.set(config,section,value) : ctx.set(config,section,option,value)))reject('Unable to stage '+config);}
 set('qmodem_sip',group,null,'group');set('qmodem_sip',group,'modem_id',request.modem_id);
 let section=group+'_out';
 set('qmodem_sip',section,null,'direction');
 let options={group,direction:'outbound',interface:request.interface,listen_port:''+port,rtp_start:''+rtp,transport:'tls',server:value.server,port:''+value.port,username:value.username,password:value.password,realm:value.realm,register_interval:''+value.register_interval,sms_enabled:value.sms_enabled?'1':'0',voip_enabled:value.voip_enabled?'1':'0'};
 for(let key in keys(options))set('qmodem_sip',section,key,options[key]);
 if(value.sms_enabled){
  set('qmodem',request.modem_id,'use_ubus','1');
  if(!modem.sms_mode || modem.sms_mode=='direct')set('qmodem',request.modem_id,'sms_mode','database_poll');
  set('sms_forwarder','sms_forward',null,'sms_forward');set('sms_forwarder','sms_forward','enable','1');
  set('sms_forwarder',section,null,'sms_forward_instance');
  set('sms_forwarder',section,'enable','1');set('sms_forwarder',section,'modem_cfg',request.modem_id);
  set('sms_forwarder',section,'api_type','sip');set('sms_forwarder',section,'poll_interval','30');
  set('sms_forwarder',section,'api_config',sprintf('%J',{group,direction:'outbound',recipient_uri:expected}));
 } else if(ctx.get('sms_forwarder',section))set('sms_forwarder',section,'enable','0');
 if(index(names,'qmodem_voip')>=0){
  set('qmodem_voip',group,null,'modem');set('qmodem_voip',group,'modem_id',request.modem_id);
  set('qmodem_voip',group,'enabled',value.voip_enabled?'1':'0');set('qmodem_voip',group,'interface',request.interface);
 }
 try {
  for(let name in names)if(!ctx.commit(name))reject('Commit failed for '+name);
  chmod('/etc/config/qmodem_sip',0600);
 } catch(e) {
  for(let name in names){if(backup[name] != null)writefile('/etc/config/'+name,backup[name]);else unlink('/etc/config/'+name);}
  reject('Import rolled back: '+e);
 }
 for(let name in names)unlink(staging+'/'+name);
 rmdir(staging);staging=null;
 // Fixed command, no downloaded shell input. procd updates only changed instances.
 let command='/etc/init.d/qmodem_sipd reload';
 if(index(names,'qmodem_voip')>=0)command+=' && /etc/init.d/qmodem_voip reload';
 if(value.sms_enabled)command+=' && /etc/init.d/qmodem-smsd reload && /etc/init.d/sms_forwarder reload';
 let process=popen(command,'r');
 let code=1;
 if(process){process.read('all');code=process.close();}
 if(code != 0){
  for(let name in names){if(backup[name] != null)writefile('/etc/config/'+name,backup[name]);else unlink('/etc/config/'+name);}
  process=popen(command,'r');if(process){process.read('all');process.close();}
  reject('Service update failed; previous configuration restored');
 }
 summary.status='success';print(sprintf('%J\n',summary));
} catch(e) {
 if(staging){for(let name in ['qmodem_sip','qmodem','qmodem_voip','sms_forwarder'])unlink(staging+'/'+name);rmdir(staging);}
 print(sprintf('%J\n',{status:'error',error:''+e}));
}
