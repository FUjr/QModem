# 适配新模组

模组适配的目标不是让名称出现在页面中，而是建立从物理端口、身份识别、AT 能力到数据连接的可验证 profile。

## 1. 收集硬件事实

在修改代码前记录：

- 厂商、完整型号、硬件版本和固件版本。
- USB `VID:PID` 或 PCIe ID。
- USB configuration 和每个 interface number 的 class、driver、tty/net 设备。
- PCIe/MHI 控制、AT 和数据设备映射。
- `ATI`、`AT+CGMI`、`AT+CGMM`、`AT+CGMR` 的原始响应。
- 实际可用的拨号协议和 PDP context 要求。

同一型号在不同 USB composition 下必须分别记录端口布局。

## 2. 判断适配层级

### 已有厂商和平台

优先只增加 `modem_support.json` profile。只有现有解析或命令确实不适用时，才增加型号分支。

### 已有厂商、新平台

复用 vendor 文件，在 `cmds/<vendor>.sh` 增加平台命令封装，在 vendor 解析层增加最小分支，并补充 fixture。

### 新厂商

需要：

1. `cmds/<vendor>.sh` 命令封装。
2. `vendor/<vendor>.sh` 响应解析和控制实现。
3. `vendor/dynamic_load.json` 映射。
4. `modem_support.json` profile。
5. 真实设备 fixture 和只读方法预期输出。

不要简单复制另一厂商的整个脚本后只修改名称。

## 3. 配置端口规则

只有默认扫描不能正确筛选接口时才修改 `modem_port_rule.json`。`include` 应列出确认过的 interface number，排除 AP/CP diag、GNSS、ADB 和其他非 AT 控制接口。

规则必须以真实 `VID:PID + composition + interface` 证据为依据。只知道 USB vendor ID 不足以建立可靠规则。

## 4. 添加设备 profile

在 `modem_support.json` 中描述：

- 规范化型号名称。
- 厂商和平台。
- 支持的 USB/PCIe 拨号模式。
- 建议 PDP index。
- 可配置频段能力。

配置中存在某个 mode 只表示 QModem 可以尝试该实现。只有完成实机数据连接、重拨和路由验证后，才能在提交说明中写“拨号验证通过”。

## 5. 实现 AT 能力

所有命令先进入 `cmds/`：

```sh
cmd_example_query()
{
    at "$1" 'AT+EXAMPLE?'
}
```

Vendor 层调用封装并解析结果。解析器应处理：

- CR/LF 差异和命令 echo。
- `OK`、`ERROR`、`+CME ERROR`、`+CMS ERROR`。
- 缺字段、未知枚举和不同固件增加的字段。
- 响应中间混入 URC。
- 空响应和超时。

不支持的功能通过 `vendor_get_disabled_features` 或明确错误返回表达，不能伪造成功或空数据。

## 6. 采集 fixture

在测试设备上开启采集：

```sh
uci set qmodem.main.testcase_collect=1
uci commit qmodem
```

触发待验证的只读功能后执行：

```sh
qmodem_collect pack
```

在开发机导入：

```sh
scripts/import_testcases.sh archive.tar.gz
```

提交前按 [fixture 文档](../../testcases/README.md)检查 profile 路径、原始字节、返回码和脱敏结果。对于 `base_info`、`get_mode` 等稳定只读方法，可在 profile 的 `expected/` 中增加规范化 JSON 快照。

## 7. 验证和记录结论

最低提交检查：

```sh
application/qmodem/tests/test_vendor_cmds_boundary.sh
application/qmodem/tests/test_core_cmds.sh
application/qmodem/tests/test_vendor_fixtures.sh
git diff --check
```

随后完成目标 OpenWrt SDK 包构建。声称硬件支持时还应记录扫描、身份识别、AT 功能、拨号、IP/路由/DNS、重拨和热插拔结果。

支持列表目前由 `modem_support.json` 生成，但没有表达完整的硬件验证等级。提交说明必须明确区分“配置已添加”“fixture 已回放”“SDK 已构建”和“真实模组已验证”。
