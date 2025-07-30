# QModem (中文)

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

## 🏠 相关项目：Home Assistant 集成

想要在 Home Assistant 中监控您的 OpenWrt 路由器和 QModem 状态吗？请查看我们的配套项目：

### [OpenWrt Ubus Integration for Home Assistant](https://github.com/FUjr/homeassistant-openwrt-ubus)

一个自定义的 Home Assistant 集成，通过 ubus 接口连接到 OpenWrt 路由器，提供：

- **📱 设备跟踪**: 实时监控无线设备和 DHCP 客户端
- **📊 系统监控**: 跟踪正常运行时间、负载平均值、内存使用情况
- **📡 QModem 支持**: 监控 4G/LTE 调制解调器状态、信号强度和连接详情
- **📶 无线站点**: 跟踪站点关联和信号信息
- **🔧 简易设置**: 通过 Home Assistant UI 进行简单配置

![QModem Integration](https://github.com/FUjr/homeassistant-openwrt-ubus/blob/main/imgs/qmodem_info.png)

完美地将您的 QModem 驱动的 OpenWrt 路由器集成到智能家居生态系统中！

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
