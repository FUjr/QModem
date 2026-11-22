# Outbound SIP usage

This document describes the outbound SIP configuration and verification
contract. Outbound signaling is TLS-only and server certificates are verified
against the system CA bundle.

## RM520N USB audio

RM520N defaults to `qmodem_voip.main.audio_policy=uac`, including when that
option is absent on an older installation. An explicit `auto` setting still
permits serial PCM fallback; `serial_pcm` remains an explicit alternative.
UAC mode must not silently substitute serial PCM when USB audio fails.

After a modem USB reboot, discard the AT daemon's old connection to the
rediscovered serial endpoint before restoring audio settings. A reused tty
name does not mean its old file descriptor remains usable. This reconnect
affects the selected modem only, without restarting the shared AT daemon.

Verify that status reports `media_backend=uac`, the USB sound card has active
capture, and a real call delivers non-silent audio. Registration and RTP packet
counts alone are insufficient. Repeat the call after service and modem
restarts before accepting a configuration as stable.

## Prepare the interface

Set `interface` to the local OpenWrt network interface that owns the source
address. If the cable is on physical `lan4` and that port is assigned to the
WAN network, use `wan`, not `lan4` and not the Asterisk IP:

```sh
uci set qmodem_sip.outbound.interface='wan'
```

## Configure an Asterisk account

Replace the example values with the account created on Asterisk. Do not put
these values in a support bundle or public repository.

```sh
uci set qmodem_sip.outbound.enabled='1'
uci set qmodem_sip.outbound.server='pbx.example.net'
uci set qmodem_sip.outbound.port='5061'
uci set qmodem_sip.outbound.transport='tls'
uci set qmodem_sip.outbound.username='device-1001'
uci set qmodem_sip.outbound.password='REPLACE_ME'
uci set qmodem_sip.outbound.realm=''
uci set qmodem_sip.outbound.register_interval='300'
uci commit qmodem_sip
chmod 600 /etc/config/qmodem_sip
/etc/init.d/qmodem_voip_sipd reload
```

## Verification checklist

Verify in this order:

1. `ubus call qmodem.sip status` reports the outbound instance running and
   `logread -e qmodem_voip_sipd` reports registration success.
2. Asterisk shows the endpoint as reachable and sends an inbound test call.
3. The call status exposes a Call-ID and both RTP packet counters increase.
4. A restart produces one registration and one media process, with no stale
   transaction after the old process exits.
