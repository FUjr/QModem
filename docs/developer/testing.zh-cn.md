# 测试与验证

QModem 同时涉及 shell、C、LuCI、OpenWrt 服务、内核驱动和真实蜂窝网络。单一测试层不能证明整个系统工作。

## 验证层级

| 层级 | 能证明 | 不能证明 |
| --- | --- | --- |
| 语法与静态检查 | shell/JS/JSON 可解析，命令边界符合规则 | 响应解析和硬件行为正确 |
| AT fixture 回放 | 已采集响应的解析结果未回归 | 未采集固件、网络状态和时序 |
| 主机单元测试 | 独立算法和工具行为 | OpenWrt ABI 与目标服务集成 |
| OpenWrt SDK 构建 | 目标工具链、依赖和包安装内容成立 | 模组能识别、拨号或联网 |
| 模拟 RPC/LuCI | 前后端字段和状态转换成立 | 真实 AT 命令被模组接受 |
| 真实模组测试 | 指定型号、固件、composition 下的功能 | 其他固件和同名硬件版本 |
| 整机测试 | 供电、热插拔、重拨、路由和长期运行 | 所有板型和运营商环境 |

所有发布或 PR 说明都应列出实际执行的层级和未覆盖部分。

## 仓库现有检查

命令边界和核心封装：

```sh
application/qmodem/tests/test_vendor_cmds_boundary.sh
application/qmodem/tests/test_core_cmds.sh
```

Fixture 字节保真、profile 隔离和厂商回放：

```sh
application/qmodem/tests/test_fixture_collection_bytes.sh
application/qmodem/tests/test_fixture_profiles.sh
application/qmodem/tests/test_vendor_fixtures.sh
```

反馈包加密测试需要先构建 `qmodem-seal`，具体命令以 `.github/workflows/vendor-fixtures.yml` 为准。

通用提交检查：

```sh
git diff --check
find application/qmodem/files/usr/share/qmodem/cmds \
     application/qmodem/files/usr/share/qmodem/vendor \
     -type f -name '*.sh' -exec sh -n {} +
```

## Fixture 覆盖率

Fixture 必须按厂商、平台和型号 profile 隔离。测试脚本报告“command heads without fixtures”时，目前属于覆盖提醒而非失败。这意味着测试通过只证明已有 fixture 没有回归，不能理解成该厂商所有命令均有覆盖。

优先补充：

1. 身份、SIM、网络、信号和小区等高频只读命令。
2. 不同固件返回格式存在差异的命令。
3. 曾经引发解析回归的响应。
4. 超时、`ERROR`、缺字段和 URC 混入等异常样本。

写操作 fixture 只能验证命令生成和返回解析，默认不应在自动测试中对真实模组执行破坏性操作。

## SDK 构建

至少选择项目支持的一个稳定 OpenWrt 分支和一个当前 snapshot；涉及架构或驱动的改动应覆盖相应 target。检查生成包中的文件、权限、依赖和目标 ELF 架构，而不只检查 `make` 返回码。

## 真实设备验收

记录以下上下文：

- 板型、供电和 USB/PCIe 拓扑。
- 模组型号、硬件版本、固件版本和 composition。
- OpenWrt target、内核和 QModem commit。
- SIM 和运营商环境，但不记录可识别用户的秘密数据。

建议测试矩阵：

1. 冷启动发现和身份识别。
2. AT 命令并发、超时和 URC。
3. IPv4、IPv6、双栈拨号。
4. DNS、默认路由、防火墙和 LAN 转发。
5. 主动重拨、异常断线和服务恢复。
6. USB 热插拔或 PCIe/MHI 复位。
7. 锁频、锁小区的设置、查询和恢复。
8. 长时间运行、流量统计和多模组隔离。

## 结果表述

推荐使用明确措辞：

- “静态检查通过”。
- “Quectel/Qualcomm/某型号 fixture 回放通过”。
- “OpenWrt 23.05 aarch64 SDK 构建通过”。
- “某型号某固件在某板型完成 QMI 双栈拨号验证”。
- “未验证真实模组热插拔”。

避免仅使用“全部测试通过”或“完全支持”，因为它们隐藏了实际覆盖边界。
