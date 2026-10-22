#!/usr/bin/env python3
"""Exercise real ucode/UCI in a disposable Docker filesystem, never a DUT.
OPENWRT_TEST_ROOT must point to an x86_64 OpenWrt root with ucode/uci/fs.
"""
import json,os,subprocess,tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[1]
openwrt=Path(os.environ['OPENWRT_TEST_ROOT']).resolve()
image=os.getenv('UCODE_TEST_IMAGE','debian:trixie-slim')
with tempfile.TemporaryDirectory(prefix='qmodem-import-') as directory:
    fixture=Path(directory);config=fixture/'config';init=fixture/'init.d';config.mkdir();init.mkdir()
    files={
        'qmodem':"config modem-device 'm1'\n option name 'rm520n-gl'\n option data_interface 'usb'\n option at_port '/dev/ttyUSB2'\n option voice_pcm_port '/dev/ttyUSB1'\n option sms_mode 'database_urc'\nconfig modem-device 'm2'\n option name 'other'\n option sms_mode 'database_poll'\n",
        'network':"config interface 'wan'\n",
        'qmodem_sip':"config sipd 'main'\n option schema_version '2'\n",
        'qmodem_voip':"config main 'main'\n option enabled '0'\n",
        'sms_forwarder':"config sms_forward 'sms_forward'\n option enable '0'\n",
    }
    for name,content in files.items():(config/name).write_text(content)
    for name in ('qmodem_sipd','qmodem_voip','qmodem-smsd','sms_forwarder'):
        (init/name).write_text('#!/bin/sh\nexit 0\n');(init/name).chmod(0o755)
    value={'schema_version':1,'account_id':'modem1','server':'sip.test','port':5061,'transport':'tls','username':'modem1','password':'test-protocol-password-123','realm':'sip-gateway','register_interval':300,'sms_enabled':True,'voip_enabled':True,'sms_ingress_uri':'sips:sms@sip.test:5061;transport=tls'}
    def run(mode='preview',provision=None,modem='m1'):
        request={'config':json.dumps(value if provision is None else provision),'modem_id':modem,'interface':'wan'}
        result=subprocess.run(['docker','run','--rm','-i','--user',f'{os.getuid()}:{os.getgid()}','--entrypoint','/openwrt/lib/ld-musl-x86_64.so.1','-v',str(openwrt)+':/openwrt:ro','-v',str(config)+':/etc/config','-v',str(init)+':/etc/init.d','-v',str(root/'files/usr/share/qmodem_sip')+':/app:ro',image,'--library-path','/openwrt/lib:/openwrt/usr/lib','/openwrt/usr/bin/ucode','-L','/openwrt/usr/lib/ucode/*.so','/app/import.uc',mode],input=json.dumps(request),capture_output=True,text=True,check=True)
        return json.loads(result.stdout)
    before={p.name:p.read_bytes() for p in config.iterdir()}
    preview=run();assert preview['status']=='preview' and 'password' not in preview
    assert before=={p.name:p.read_bytes() for p in config.iterdir()}
    assert run(provision={**value,'command':'malicious'})['status']=='error'
    assert run(modem='missing')['status']=='error'
    assert run(modem='m2')['status']=='error'
    assert run('apply')['status']=='success'
    modem_config=(config/'qmodem').read_text();assert 'database_urc' in modem_config
    assert modem_config.split("config modem-device 'm2'")[1].split()==files['qmodem'].split("config modem-device 'm2'")[1].split()
    assert (config/'qmodem_sip').stat().st_mode & 0o777 == 0o600
    saved={p.name:p.read_bytes() for p in config.iterdir()}
    (init/'qmodem_sipd').write_text('#!/bin/sh\nexit 1\n')
    result=run('apply',{**value,'username':'changed'});assert result['status']=='error' and 'restored' in result['error']
    assert saved=={p.name:p.read_bytes() for p in config.iterdir()}
print('PASS: real UCI preview, strict import, modem isolation, database mode preservation, service-failure rollback')
