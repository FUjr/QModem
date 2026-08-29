# QModem

[English](README.md) | 简体中文

[![OpenWrt SDK build](https://github.com/FUjr/modem_feeds/actions/workflows/main.yml/badge.svg)](https://github.com/FUjr/modem_feeds/actions/workflows/main.yml)

QModem 是面向 OpenWrt 和 ImmortalWrt 的蜂窝模组管理与拨号组件。它负责发现 USB、PCIe 模组，管理 AT 端口和数据接口，并通过 LuCI 提供拨号、状态监控、短信和厂商高级功能。

QModem 适合自制 4G/5G 路由器、工业网关和多模组设备。它不是通用桌面 ModemManager，也不能替代目标固件缺失的内核驱动。

## 主要能力

| 能力 | 说明 |
| --- | --- |
| 模组发现 | USB、PCIe，按物理卡槽稳定绑定 |
| 数据连接 | QMI、MBIM、NCM、ECM、RNDIS 等，具体取决于模组和驱动 |
| 模组状态 | SIM、注册网络、信号、小区和固件信息 |
| 高级控制 | 网络制式、锁频、锁小区、SIM 切换等，具体取决于厂商和型号 |
| 短信 | 收发、PDU 和可选转发；部分模组的长短信行为存在差异 |
| 多模组 | 独立配置、拨号、状态和物理卡槽管理 |
| OpenWrt 集成 | UCI、ubus、rpcd、procd 和 LuCI |

模组出现在[支持列表](docs/support_list.md)中，表示项目中存在对应配置，不等同于所有固件、接口模式和高级功能都经过维护者实机验证。

## 软件组成

```text
LuCI
  |
rpcd / ubus
  |
QModem 控制与拨号层 ---- modem_scand 设备扫描器
  |
generic + vendor 厂商适配层
  |
cmds 统一 AT 命令层
  |
ubus-at-daemon / tom_modem
  |
USB / PCIe 蜂窝模组
```

核心包为 `qmodem`。推荐使用纯 JavaScript 前端 `luci-app-qmodem-next`。旧版 `luci-app-qmodem` 及短信、MWAN、TTL 等独立 LuCI 包仍保留，但功能分布和兼容状态不同，不应同时安装两套主界面。

## 快速开始

在 OpenWrt 源码树的 `feeds.conf.default` 中添加：

```text
src-git qmodem https://github.com/FUjr/QModem.git;main
```

然后更新 Feed：

```sh
./scripts/feeds update qmodem
./scripts/feeds install -a -p qmodem
make menuconfig
```

在 `LuCI -> Applications` 中选择 `luci-app-qmodem-next`。目标设备仍需具备与模组、拨号协议和当前内核匹配的 USB、串口、QMI、MBIM 或 MHI 驱动。

完整步骤见[安装指南](docs/user/installation.zh-cn.md)和[首次配置](docs/user/first-setup.zh-cn.md)。

## 使用边界

- 同一 AT 端口不应由多个模组管理程序同时读写，否则可能出现响应残缺、超时和模组掉线。
- 锁频、锁小区、改 IMEI 和模组重启会改变无线行为，执行前应确认目标型号及恢复方法。
- Release 中的内核驱动包必须与固件的内核 ABI 匹配，不建议使用 `--force-depends` 绕过内核依赖。
- 构建成功只能证明软件包可生成，不能证明具体模组的 AT 命令和数据连接已经通过实机测试。

## 文档

### 用户

- [用户文档入口](docs/user/index.zh-cn.md)
- [安装指南](docs/user/installation.zh-cn.md)
- [首次配置](docs/user/first-setup.zh-cn.md)
- [故障排查](docs/user/troubleshooting.zh-cn.md)
- [硬件支持列表](docs/support_list.md)
- [旧版完整用户手册](docs/user-guide.zh-cn.md)

### 开发者

- [开发者文档入口](docs/developer/index.zh-cn.md)
- [系统架构](docs/developer/architecture.zh-cn.md)
- [适配新模组](docs/developer/modem-adaptation.zh-cn.md)
- [测试与验证](docs/developer/testing.zh-cn.md)
- [rpcd 接口](docs/qmodem-rpcd-interface.zh-cn.md)
- [AT fixture 格式与回放](testcases/README.md)

## 反馈问题

提交 Issue 前，请先阅读[故障排查](docs/user/troubleshooting.zh-cn.md)。至少提供路由器型号、固件版本、QModem 版本、模组完整型号、USB/PCIe 连接方式、拨号协议和复现步骤。日志、配置和 AT 响应可能包含 IMEI、IMSI、ICCID、手机号、APN 或短信内容，公开前必须脱敏。

QModem 支持在设备上采集 AT fixture 和反馈包。开发者应优先提交可回放、已脱敏的 fixture，而不是只提交截图。

## 贡献

新增厂商或型号前，请阅读[模组适配流程](docs/developer/modem-adaptation.zh-cn.md)。Vendor 和拨号实现发送的 AT 指令必须通过 `application/qmodem/files/usr/share/qmodem/cmds/` 中的 `cmd_*` 封装；CI 会检查该边界。

## 许可证

仓库的 [LICENSE](LICENSE) 以 Mozilla Public License 2.0 正文为基础，并附加了禁止商业使用的条款。因此它不是未经修改的标准 MPL 2.0 授权。使用、分发或集成本项目之前，请阅读完整许可证；项目维护者后续应统一许可证名称和 README 表述。

## 致谢

QModem 使用或参考了 5G-Modem-Support、luci-app-4gmodem、sms_tool、gl-modem-at、sendat 和 qosmio/nss-packages 等社区项目。具体来源和许可证应以各目录中的文件及 Git 历史为准。
