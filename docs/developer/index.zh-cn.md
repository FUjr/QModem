# QModem 开发者文档

本组文档面向维护 QModem、适配新模组、开发 LuCI/RPC 或集成板级功能的开发者。

## 阅读路径

1. [系统架构](architecture.zh-cn.md)：理解各组件的职责和调用链。
2. [模组适配](modem-adaptation.zh-cn.md)：添加厂商、型号、端口规则和 AT 能力。
3. [测试与验证](testing.zh-cn.md)：区分静态测试、fixture、SDK 构建和硬件验证。
4. [rpcd 接口](../qmodem-rpcd-interface.zh-cn.md)：前后端调用约定。
5. [AT fixture](../../testcases/README.md)：采集、脱敏和回放真实模组响应。

旧版[开发者指南](../developer-guide.zh-cn.md)保留为历史参考。代码路径、RPC 方法和适配步骤发生冲突时，以当前源码和本组文档为准。

## 设计原则

- 使用 OpenWrt 原生的 UCI、ubus、rpcd、procd 和 LuCI 机制。
- 物理设备发现、运行状态、用户配置和厂商能力必须分开建模。
- 通用行为放在 generic 层；只有真实存在的厂商差异才进入 vendor 层。
- Vendor 和拨号脚本不能直接发送 AT 指令，只能调用 `cmds/` 中的 `cmd_*` 封装。
- 硬件支持声明必须说明验证层级，不能用编译成功代替实机结果。
- 配置和日志中可能存在设备身份及用户数据，测试资料进入仓库前必须脱敏。

## 仓库主要目录

| 路径 | 职责 |
| --- | --- |
| `application/qmodem/` | 核心 shell、rpcd、UCI、服务和板级脚本 |
| `application/modem_scan/` | C 实现的设备扫描守护进程及客户端 |
| `application/ubus_at_daemon/` | 串口复用与 ubus AT 服务 |
| `application/tom_modem/` | AT 和短信底层工具 |
| `application/qmodem-seal/` | 反馈包加密工具 |
| `luci/` | 新旧 LuCI 主界面及可选插件 |
| `driver/` | 厂商 USB、QMI、MHI 和 NSS 驱动包 |
| `testcases/` | 按厂商、平台和型号隔离的 AT fixture |
| `scripts/` | 文档生成、fixture 导入和维护脚本 |

## 提交要求

一个完整的模组适配提交通常应包含配置变化、命令封装、解析实现、脱敏 fixture、预期输出、支持列表更新和验证记录。驱动、扫描、拨号、LuCI 等独立问题应尽量拆分提交，便于回归和回退。
