# QModem
[![Auto compile with OpenWrt SDK](https://github.com/FUjr/modem_feeds/actions/workflows/main.yml/badge.svg)](https://github.com/FUjr/modem_feeds/actions/workflows/main.yml)

以前我在github上抄代码，作者跟我说点个star，我都会说好好好，但是编译完了刷机后也没想起来点star，其实这样挺不好的。
现在作者跟我说点个star，除非代码真的很好到我想打好评的程度，否则我就会在issue直接说，抱歉我不想star，然后直接抄。作为一个有讨好倾向的人，这就是我锻炼真诚和勇气的方式

[English](README.en.md)

这是一个模组管理插件，兼容 Openwrt 21及之后的版本，使用 lua 开发，因此同时兼容 QWRT/LEDE/Immortalwrt/Openwrt

(使用 js luci 时请添加 luci-compat 软件包)

[支持模组列表](./docs/support_list.md)

[toc]

# 快速开始

## 增加 feed 源

要使用 QModem，首先需要在 OpenWRT 中添加一个 feed 源：

```shell
echo >> feeds.conf.default
echo 'src-git qmodem https://github.com/FUjr/QModem.git;main' >> feeds.conf.default
./scripts/feeds update qmodem
./scripts/feeds install -a -p qmodem
```

强制更新库驱动 (使用本库驱动):

```shell
./scripts/feeds install -a -f -p qmodem
```

## 集成软件包

在终端中运行以下命令以打开配置菜单：

```shell
make menuconfig
```

## 选择和安装软件包

在配置菜单中，您可以选择以下软件包：（均在 Luci/Application 下）


| 软件包名                              |                                                                                                                  功能                                                                                                                  |
| ------------------------------------- | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------: |
| **luci-app-qmodem**                   |                                                          有模组信息、拨号设置、高级设置三大功能块。由于主程序在这里，因此其他功能依赖该程序（原谅我将后端程序也放在了这里）。                                                          |
| **Add Lua Luci Homepage**             |                                                                       添加 Lua Luci 首页。luci2（Js Luci）首页默认已添加，若使用luci2时勾选了这个，会有两个首页                                                                       |
| **QMI Driver Selection**              |                                                                              可选择 Generic QMI driver（通用QMI驱动）或 Vendor QMI driver（厂商QMI驱动）                                                                              |
| **Quectel Connect Manager Selection** | 可选择以下三种之一：<br>- Tom customized Quectel CM：使用本仓库定制的Quectel CM，支持屏蔽添加默认路由、屏蔽修改resolv.conf等功能<br>- QWRT Quectel-CM-5G：使用 QWRT 仓库的 quectel-CM-5G<br>- NORMAL Quectel-CM：使用普通的 quectel-cm |
| **Add PCIe Modem SUPPORT**            |                                                                                                 勾选 PCIe 驱动，需要feeds里有kmod_mhi                                                                                                 |
| **Add Qfirehose SUPPORT**             |                                                                                             添加 Qfirehose 支持，用于高通芯片模组固件升级                                                                                             |
| **luci-app-qmodem-hc**                |                                                                                              支持 hc-g80 SIM 卡切换，该插件为设备专属插件                                                                                              |
| **luci-app-qmodem-mwan**              |                                                                                                           支持多 WAN 设置。                                                                                                           |
| **luci-app-qmodem-sms**               |                                                                                                              短信收发功能                                                                                                              |
| **luci-app-qmodem-ttl**               |                                                                                                              TTL 重写功能                                                                                                              |

# 项目介绍

## 为什么选择该项目

- **稳定性**：通过缓存和减少 AT 指令的次数，提高了系统的稳定性。
- **可扩展性**：最小化 API 端点和统一后端程序设计，便于二次开发和扩展。
- **可靠性**：功能分离设计，确保核心功能的稳定性，即使其他功能出现问题也不影响主要使用。
- **多模组支持**: 根据 slot 定位模组，模组和配置有一对一的绑定关系，即使重启或热插拔模组也不会造成模组和配置混淆。
- **短信支持**: 长短信合并、中文短信发送
- **多语言支持**: 开发时将语言资源分离，可以添加需要的语言
- **IPV6支持**: 部分支持ipv6 ，测试条件 （移动卡 rm50xq qmi/rmnet/mbim 驱动，使用quectel-CM-M拨号，使用扩展前缀模式）
- **优化的quectel-CM**：原版quectel-CM会覆盖resolv.conf 覆盖默认路由，本仓库提供改进版，增加了对应的开关选项
- **[全新实现的AT工具](docs/tom_modem.cn.md)**：尽管 sendat、sms_tool 和 gl_modem_at 这三个工具在大多数情况下表现出色，能够满足大部分需求，但它们在超时机制、mhi_DUN 和短信支持方面各自存在一些小问题。如果想要同时使用所有功能，就必须内置这三个 AT 工具，这显然不够优雅，因此我参考这三个工具，实现了一个包含所有功能的at工具。

## 模组信息

<img src="imgs/homepage.png" style="zoom: 25%;" alt="在首页显示（Lua)" />

<img src="imgs/modem_info.png" style="zoom: 25%;" />

## 模组高级设置

可对模组进行拨号模式、制式偏号、IMEI设置、锁小区、锁频段等设置

<img src="imgs/modem_debug_lock_cell.png" style="zoom:25%;" />

<img src="imgs/modem_debug_lock_band.png" style="zoom:25%;" />

## 拨号总览

<img src="imgs/dial_overview.png" style="zoom:25%;" />

### 全局配置

提供全局性的配置选项，允许用户进行统一的模组配置。

- **重新加载拨号**：重新加载模组的配置文件，确保配置生效。
- **拨号总开关**: 拨号总开关，启用后才会进行拨号

### 配置列表

- 插槽id为模组标识符与配置文件关联（即同一个端口即使更换模组也会使用同一套配置，同一个模组更换了端口也需要重新配置）
- 拨号相关配置修改后需要重拨才会生效
- 网络接口的名称是模组别名，若模组别名留空则为插槽id

## 短信

![](imgs/modem_sms.png)

## Mwan配置

该页面是 **MWAN 配置** 界面，帮助用户管理多 WAN 连接，通过监控特定 IP 来确保网络的稳定性和可靠性。用户可以根据需求自定义连接的优先级和接口，从而实现负载均衡或故障转移


| 功能          | 描述                                                                                                                          |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| **启用 MWAN** |                                                                                                                               |
| 相同源地址    | 选中此框后，路由器将在一定时间内使用相同的 WAN 端口处理来自同一源的流量。                                                     |
| **IPv4 配置** |                                                                                                                               |
| 接口          | 选择要添加的 WAN 接口（如`wan`、`usb0` 等），以便于配置不同的网络连接。                                                       |
| 跟踪IP        | 输入特定的 IP 地址或域名。                                                                                                    |
| 优先级        | 设置连接的优先级，范围为 1 到 255，数值越低优先级越高。优先级一致会根据权重负载均衡，只有优先级高的故障才会启用低优先级的接口 |

## QModem 设置


| 配置项                    | 描述                                                                 |
| ------------------------- | -------------------------------------------------------------------- |
| **禁用自动加载/移除模组** | 关闭以下所有功能。                                                   |
| **启用 PCIe 模块扫描**    | 选中后，系统会在开机时扫描 PCIe 接口。（耗时较长）                   |
| **启用 USB 模块扫描**     | 选中后，系统会在开机时扫描 USB 接口。（耗时较长）                    |
| **监控设置的 USB 接口**   | 系统会在开机时扫描插槽配置里的 USB 端口，同时监控 USB 的热插拔事件。 |
| **监控设置的 PCIe 接口**  | 系统会在开机时扫描插槽配置里的 PCIe 端口。                           |

### 插槽配置

该页面允许用户对每个插槽进行一些设置


| 配置项               | 描述                                                                                  |
| -------------------- | ------------------------------------------------------------------------------------- |
| **插槽类型**         | 选择插槽的类型（PCIe/USB），用于识别设备。                                            |
| **插槽 ID**          | 输入设备的唯一标识符（如`0001:11:00.0[pcie]`），用于设备识别。                        |
| **SIM 卡指示灯**     | 绑定插槽与相应的指示灯，以显示 SIM 卡的状态。                                         |
| **网络指示灯**       | 绑定插槽的网络状态指示灯，以便监控网络连接的状态。                                    |
| **启用 5G 转网络口** | 启用后，支持的模组通过网络接口与主机通信，以提高性能。                                |
| **关联的 USB**       | 配置该项可将 USB 端口与 PCIe 端口关联，使用兼容性更好的 USB serial 驱动进行 AT 通信。 |

### 模组配置

该页面允许用户修改模组的配置，属于高级功能，错误使用可能会导致设备无法正常工作。主要用途为手动添加某些不在兼容列表中的模组。
在该配置项中，引入了 `post_init` 和 `pre_dial` 两个选项，允许用户在模组启动后或拨号前设置自定义延迟和发送自定义的 AT 命令。其余内容均为字面意思，不做过多介绍。

## 开发计划

欢迎大家参与贡献，目前计划如下：
| 计划                         | 进度 |
| ---------------------------- | ---- |
| 将后端程序与luci-app完全分离 | 0    |
| 切换js luci                  | 5%   |
| 支持更多模组                 | 0    |
| 使用at_daemon 用于监听模组主动发送的at事件 | 5% |
| 电话功能 | 0 |
| 完善（开发和使用）文档 | 0 |
| 增加诊断功能，便于用户复制信息 | 0 |
|在代码中添加贡献者和维护者信息 | 0 |

# 鸣谢

在模组管理插件的开发过程中，参考了以下仓库


| 项目                                         |       参考内容       |
| -------------------------------------------- | :------------------: |
| https://github.com/Siriling/5G-Modem-Support | 模组列表和部分at实现 |
| https://github.com/fujr/luci-app-4gmodem     | 沿用该项目大部分思想 |
| https://github.com/obsy/sms_tool             |    AT命令发送工具    |
| https://github.com/gl-inet/gl-modem-at       |    AT命令发送工具    |
| https://github.com/ouyangzq/sendat           |    AT命令发送工具    |

#
