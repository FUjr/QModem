# QModem 用户文档

本组文档面向安装、配置和维护 QModem 的 OpenWrt 用户。阅读顺序取决于当前任务：

1. 初次安装从[安装指南](installation.zh-cn.md)开始。
2. 已安装但尚未联网，按照[首次配置](first-setup.zh-cn.md)逐项验证。
3. 已经工作但出现异常，使用[故障排查](troubleshooting.zh-cn.md)。
4. 选择模组前，查看[硬件支持列表](../support_list.md)。

旧版[完整用户手册](../user-guide.zh-cn.md)保留了各页面和历史插件的详细字段说明。在内容冲突时，以当前 LuCI 页面、UCI 配置和本组文档为准。

## 使用 QModem 前需要知道

- QModem 包含模组管理、拨号和 LuCI 集成，但目标固件仍需提供匹配的内核驱动。
- 同一型号可能有多个硬件版本、USB composition 和固件版本，端口布局不一定相同。
- `luci-app-qmodem-next` 是推荐主界面。不要同时安装它和旧版 `luci-app-qmodem` 主界面。
- 支持列表描述项目配置能力，不代表所有项目都经过维护者实机验证。
- 自定义 AT 命令、锁频和锁小区可能让模组暂时失去网络；操作前记录原配置和恢复命令。

## 常见任务

| 目标 | 文档 |
| --- | --- |
| 编译进固件 | [安装指南：源码树集成](installation.zh-cn.md#从-openwrt-源码树构建) |
| 安装 Release 软件包 | [安装指南：预编译包](installation.zh-cn.md#安装预编译包) |
| 添加第一张模组 | [首次配置](first-setup.zh-cn.md) |
| 选择 QMI、MBIM、NCM | [首次配置：拨号协议](first-setup.zh-cn.md#4-配置拨号) |
| 扫描不到设备 | [故障排查：发现问题](troubleshooting.zh-cn.md#扫描不到模组) |
| 拨号后不能访问网络 | [故障排查：数据连接](troubleshooting.zh-cn.md#拨号成功但不能访问网络) |
| 提交 Issue | [故障排查：反馈信息](troubleshooting.zh-cn.md#提交问题前收集信息) |

## 术语

- **模组**：4G/5G 蜂窝通信模块，也称 Modem。
- **AT 端口**：发送控制命令和读取响应的串口。
- **数据接口**：QMI、MBIM、NCM、ECM、RNDIS 或其他承载 IP 数据的接口。
- **卡槽**：USB 拓扑路径或 PCIe 地址，用于稳定识别模组的物理位置。
- **PDP context**：模组中的数据连接配置，通常包含 APN 和 IP 类型。
- **RAT**：无线接入制式，例如 LTE、NSA 5G、SA 5G。
