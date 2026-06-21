# QModem (中文)

那些希望使用纯净的JS Luci的用户（测试版本）

应大家都需求，QModem推出了纯JS Luci的前端，可以不再依赖luci-compat，减少很多Luci 21后的兼容性问题。

### 使用方法：
- 更新feeds并安装feeds新增的软件包。
- 导航到Luci -> Application -> luci-app-qmodem。
- 移除luci-app-qmodem以及luci-app-qmodem-sms/mwam/ttl等。
- 选择luci-app-qmodem-next。

### 功能改动：
1. 优化了拨号配置界面，重新设计了拨号日志和拨号状态的显示逻辑。
2. 优化了短信，目前暂未将短信功能单独拆分。短信功能以对话框形式呈现，自动导出到路由的文件系统，支持记录已发信息。
3. 优化了AT调试、模组高级功能的界面。
4. 优化了所有设置界面。
5. 使用脚本+AI提取待翻译的字符串，翻译覆盖率有较大提升。
6. 短信转发：已读短信也会转发。

### 兼容性与局限性说明：
1. 功能的删除：MWAN、TTL功能在这一版本中被暂时无限期移除。
2. 短信功能的稳定性：为了节省开发时间，目前短信后端实现的较为简陋，采用JSON作为数据库。
3. 短信管理：不支持在UI设置短信储存位置，不支持在UI删除短信。仅可选择自动删除短信。
4. 短信显示：已知问题：短信拼接基于timestamp+reference ID，但是由于部分运营商和模组提供的timestamp并不可靠，导致长信息无法拼接。

---

# 针对部分使用webui的用户和开发者的特别提示：
模组端的atd是一个古老的设计，并且不同厂商有非常不同的实现，在兼容性和并发、返回完整性甚至atd服务的稳定性上都表现较差。
因此当你同时使用 webui 和 qmodem （或者多个不同模组管理插件）时，会增加同时发送at指令的概率，造成 信息不全、atd服务崩溃（这通常是atd开发者的问题） 导致乱码、at卡死、模组掉线。
如果你是用户，建议二选一，不要同时使用多个模组管理插件
如果你是 webui 的开发者，我推荐你使用我开发的 ubus atd 插件来代替在模组端使用自建的 atd 服务，这样可以让qmodem兼容你的项目，并且节省您开发时间 [参考说明](docs/rpcd-at-daemon-userguide-cn.md)

**中文 README** | **[English README](README.md)**

[![使用 OpenWrt SDK 自动编译](https://github.com/FUjr/modem_feeds/actions/workflows/main.yml/badge.svg)](https://github.com/FUjr/modem_feeds/actions/workflows/main.yml)

**QModem** 是一个为基于OpenWRT的路由器设计的蜂窝调制解调器（Modem）综合管理系统。它提供了一个基于LuCI的Web界面，用于轻松管理和高级控制各种蜂窝调制解调器。

本项目旨在为OpenWRT集成蜂窝网络连接提供一个稳定、可扩展且用户友好的解决方案。

## 功能特性

-   **广泛的硬件支持**: 管理来自Quectel、Fibocom等供应商的多种USB和PCIe蜂窝调制解调器。
-   **直观的Web界面**: 简洁的LuCI界面，方便进行状态监控和配置。
-   **高级调制解调器控制**: 通过锁频段、锁小区和网络模式选择等功能微调您的网络连接。
-   **短信与多WAN**: 包含用于发送/接收短信和配置多WAN故障转移/负载均衡的可选插件。
-   **健壮稳定**: 通过基于卡槽的设备绑定和优化的AT命令处理等功能，确保系统可靠性。

有关功能和能力的完整列表，请参阅[用户指南](docs/user-guide.zh-cn.md)。

## 相关项目： Home Assistant 的 OpenWrt 管理插件

[**在 GitHub 上查看 →**](https://github.com/FUjr/homeassistant-openwrt-ubus)

## 快速开始

### 安装

要安装QModem，请将自定义Feed源添加到您的OpenWRT编译环境，并在 `make menuconfig` 中选择 `luci-app-qmodem` 相关软件包。

有关详细的、分步的安装说明，请参阅 **[安装指南](docs/user-guide.zh-cn.md#安装)**。

### 配置

安装后，可以通过LuCI Web界面的 "网络" -> "QModem" 菜单配置QModem。

有关Web界面和所有配置选项的完整演练，请参阅 **[用户指南](docs/user-guide.zh-cn.md)**。

## 文档

本项目维护了全面的文档，以帮助用户和开发者。

-   **[用户指南](docs/user-guide.zh-cn.md)**: 主要面向用户的文档。它涵盖了安装、配置以及Web界面的所有功能。
-   **[开发者指南](docs/developer-guide.zh-cn.md)**: 面向希望贡献代码、适配新调制解调器或了解项目内部工作原理的开发者。它详细介绍了项目结构、核心脚本和适配流程。
-   **[硬件支持列表](docs/support_list.md)**: 已知与QModem兼容的调制解调器列表。

## 参与贡献

我们欢迎各种形式的贡献！无论是增加对新调制解调器的支持、修复错误还是改进文档，我们都非常感谢您的帮助。

请首先阅读 **[开发者指南](docs/developer-guide.zh-cn.md)** 以了解项目结构和如何开始。

## 许可证

本项目采用 Mozilla Public License Version 2.0 许可。详情请参阅 [LICENSE](LICENSE) 文件。

---

**文档说明**: 本文档由AI生成。我们欢迎社区根据实际使用经验贡献更新和改进建议。

**注意**: 未经事先许可，严禁将本软件用于商业用途。

## 致谢

本项目的开发建立在多个其他开源项目和社区的工作之上。我们向以下项目的开发者和贡献者表示感谢：
- [Siriling/5G-Modem-Support](https://github.com/Siriling/5G-Modem-Support)
- [fujr/luci-app-4gmodem](https://github.com/fujr/luci-app-4gmodem)
- [obsy/sms_tool](https://github.com/obsy/sms_tool)
- [gl-inet/gl-modem-at](https://github.com/gl-inet/gl-modem-at)
- [ouyangzq/sendat](https://github.com/ouyangzq/sendat)
- [qosmio/nss-packages](https://github.com/qosmio/nss-packages) — 感谢作者为 Qualcomm NSS 驱动包所做的出色工作
