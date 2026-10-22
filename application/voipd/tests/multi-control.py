"""Real ubus routing in a disposable x86_64 OpenWrt container."""
from pathlib import Path
import subprocess,os,tempfile,json
stage=Path(os.environ['OPENWRT_TEST_STAGE']).resolve()
cc=os.environ['CC']
root=Path(__file__).resolve().parents[1]
os.environ['STAGING_DIR']=str(stage)
with tempfile.TemporaryDirectory() as directory:
 d=Path(directory);(d/'config').mkdir()
 (d/'config/qmodem_voip').write_text("config modem 'first'\n option modem_id 'm1'\nconfig modem 'second'\n option modem_id 'm2'\n")
 for name,source in [('control',root/'src/voice_control.c'),('fixture',root/'tests/multi-control-fixture.c')]:
  subprocess.run([cc,'-Wall','-Wextra','-Werror','-I'+str(stage/'usr/include'),str(source),'-o',str(d/name),'-L'+str(stage/'usr/lib'),'-Wl,-rpath-link,'+str(stage/'usr/lib'),'-lubus','-lubox','-lblobmsg_json','-luci'],check=True)
 script='''mkdir -p /var/run/ubus
runner() { /openwrt/lib/ld-musl-x86_64.so.1 --library-path /openwrt/lib:/openwrt/usr/lib "$@"; }
runner /openwrt/sbin/ubusd &
sleep 1
runner /test/fixture &
runner /test/control &
sleep 1
runner /openwrt/bin/ubus call qmodem_voip status
runner /openwrt/bin/ubus call qmodem_voip status '{"modem_id":"m2"}'
runner /openwrt/bin/ubus call qmodem_voip originate '{"modem_id":"m1","number":"123"}'
if runner /openwrt/bin/ubus call qmodem_voip originate '{"number":"123"}'; then exit 2; fi
if runner /openwrt/bin/ubus call qmodem_voip originate '{"modem_id":"missing","number":"123"}'; then exit 3; fi
printf "config modem 'first'\n option modem_id 'm1'\n" > /etc/config/qmodem_voip
runner /openwrt/bin/ubus call qmodem_voip originate '{"number":"123"}'
'''
 r=subprocess.run(['docker','run','--rm','--entrypoint','/bin/sh','-v',str(stage/'root-x86')+':/openwrt:ro','-v',str(d)+':/test:ro','-v',str(d/'config')+':/etc/config',os.getenv('UCODE_TEST_IMAGE','debian:trixie-slim'),'-c',script],capture_output=True,text=True)
 assert r.returncode==0,r.stderr
 decoder=json.JSONDecoder();records=[];remaining=r.stdout.strip()
 while remaining:
  record,count=decoder.raw_decode(remaining);records.append(record);remaining=remaining[count:].strip()
 assert len(records[0]['modems'])==2 and records[0]['require_modem_id']
 assert records[1]['modem_id']=='m2' and records[1]['group']=='second'
 assert records[2]['modem_id']=='m1' and records[3]['modem_id']=='m1'
 print('PASS: real ubus aggregate, explicit per-modem control, ambiguous/unknown selection rejection, single-modem compatibility')
