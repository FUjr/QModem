# QModem

English | [简体中文](README.zh-cn.md)

[![OpenWrt SDK build](https://github.com/FUjr/modem_feeds/actions/workflows/main.yml/badge.svg)](https://github.com/FUjr/modem_feeds/actions/workflows/main.yml)

QModem is a cellular modem management and dialing stack for OpenWrt and ImmortalWrt. It discovers USB and PCIe modems, manages AT and data interfaces, and provides dialing, status, SMS, and vendor-specific controls through LuCI.

It is intended for custom 4G/5G routers, embedded gateways, and multi-modem devices. It is not a desktop ModemManager replacement and cannot compensate for kernel drivers missing from the target firmware.

## Capabilities

| Area | Scope |
| --- | --- |
| Discovery | USB and PCIe modems with physical-slot binding |
| Data sessions | QMI, MBIM, NCM, ECM, RNDIS, and others depending on modem and driver |
| Status | SIM, registration, signal, cell, and firmware information |
| Advanced controls | RAT preference, band/cell locking, SIM switching, depending on vendor and model |
| SMS | Send, receive, PDU, and optional forwarding; long-SMS behavior varies by modem |
| OpenWrt integration | UCI, ubus, rpcd, procd, and LuCI |

An entry in the [support list](docs/support_list.md) means that a matching project profile exists. It does not mean every firmware, interface composition, or advanced operation has been verified on hardware by the maintainers.

## Architecture

```text
LuCI
  |
rpcd / ubus
  |
QModem control and dialer ---- modem_scand discovery daemon
  |
generic + vendor adapters
  |
shared AT command wrappers
  |
ubus-at-daemon / tom_modem
  |
USB / PCIe cellular modem
```

The core package is `qmodem`. The pure-JavaScript `luci-app-qmodem-next` is the recommended UI. The legacy `luci-app-qmodem` and separate SMS, MWAN, and TTL packages remain available, but the two main UIs should not be installed together.

## Quick start

Add the feed to `feeds.conf.default` in an OpenWrt source tree:

```text
src-git qmodem https://github.com/FUjr/QModem.git;main
```

Then run:

```sh
./scripts/feeds update qmodem
./scripts/feeds install -a -p qmodem
make menuconfig
```

Select `luci-app-qmodem-next` under `LuCI -> Applications`. The target firmware must also contain USB, serial, QMI, MBIM, or MHI drivers matching the modem, protocol, kernel, and hardware topology.

The detailed English manuals are currently maintained in the existing [user guide](docs/user-guide.md) and [developer guide](docs/developer-guide.md). The new structured documentation is being introduced in Chinese first:

- [User documentation](docs/user/index.zh-cn.md)
- [Developer documentation](docs/developer/index.zh-cn.md)
- [Supported hardware](docs/support_list.md)
- [rpcd API](docs/qmodem-rpcd-interface.md)
- [AT fixture development](testcases/README.md)

## Important boundaries

- Do not let multiple management applications read and write the same AT port concurrently.
- Band locking, cell locking, IMEI changes, and modem resets can disrupt service; confirm model support and recovery steps first.
- Kernel packages from a release must match the target firmware ABI. Do not treat `--force-depends` as a compatibility solution.
- A successful package build does not prove that AT operations or data sessions work on a specific modem.

## Reporting issues

Include the router model, firmware and QModem versions, exact modem model, USB/PCIe topology, dialing protocol, and reproducible steps. Redact IMEI, IMSI, ICCID, phone numbers, APNs, credentials, and SMS content before publishing logs or fixtures.

## Contributing

AT commands used by vendor and dialing implementations must be defined through `cmd_*` wrappers under `application/qmodem/files/usr/share/qmodem/cmds/`. CI enforces this boundary. Real-device, redacted fixtures are preferred over screenshots or model-name-only support claims.

## License

The repository [LICENSE](LICENSE) contains the Mozilla Public License 2.0 text plus an additional restriction prohibiting commercial use. It is therefore not an unmodified standard MPL 2.0 grant. Read the complete license before using, distributing, or integrating the project.

## Acknowledgments

QModem uses or builds on work from the 5G-Modem-Support, luci-app-4gmodem, sms_tool, gl-modem-at, sendat, and qosmio/nss-packages communities. Consult the files and Git history in each component for exact provenance and licensing.
