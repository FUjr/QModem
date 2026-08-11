# QModem RPCD 接口

## 概述

QModem RPCD 接口通过 ubus 系统提供调制解调器控制功能的访问。这允许其他服务和 Web 界面通过 ubus 系统与调制解调器交互。

## 安装

rpcd 脚本随 qmodem 软件包自动安装:
- 脚本位置: `/usr/libexec/rpcd/qmodem`
- ACL 配置: `/usr/share/rpcd/acl.d/qmodem.json`

安装后,重启 rpcd:
```bash
killall -HUP rpcd
```

## 可用方法

### 信息方法 (只读)

#### base_info
获取基本调制解调器信息。
```bash
ubus call qmodem base_info '{"config_section":"modem1"}'
```

#### cell_info
获取蜂窝网络信息。
```bash
ubus call qmodem cell_info '{"config_section":"modem1"}'
```

#### info
获取全面的调制解调器信息。
```bash
ubus call qmodem info '{"config_section":"modem1"}'
```

#### network_info
获取网络连接信息。
```bash
ubus call qmodem network_info '{"config_section":"modem1"}'
```

#### sim_info
获取 SIM 卡信息。
```bash
ubus call qmodem sim_info '{"config_section":"modem1"}'
```

#### get_at_cfg
获取 AT 命令配置和可用端口。
```bash
ubus call qmodem get_at_cfg '{"config_section":"modem1"}'
```

#### get_copyright
获取版权信息。
```bash
ubus call qmodem get_copyright '{"config_section":"modem1"}'
```

#### get_disabled_features
获取此调制解调器的禁用功能列表。
```bash
ubus call qmodem get_disabled_features '{"config_section":"modem1"}'
```

#### get_dns
获取 DNS 服务器信息。
```bash
ubus call qmodem get_dns '{"config_section":"modem1"}'
```

#### get_imei
获取调制解调器 IMEI 号码。
```bash
ubus call qmodem get_imei '{"config_section":"modem1"}'
```

#### get_lockband
获取当前频段锁定配置。
```bash
ubus call qmodem get_lockband '{"config_section":"modem1"}'
```

#### get_mode
获取当前网络模式 (LTE/5G/等)。
```bash
ubus call qmodem get_mode '{"config_section":"modem1"}'
```

#### get_neighborcell
获取邻区信息。
```bash
ubus call qmodem get_neighborcell '{"config_section":"modem1"}'
```

#### get_network_prefer
获取网络偏好设置。
```bash
ubus call qmodem get_network_prefer '{"config_section":"modem1"}'
```

#### get_current_band_capabilities
查询当前模组厂商适配是否支持 `get_current_band`。
```bash
ubus call qmodem get_current_band_capabilities '{"config_section":"modem1"}'
```

响应示例:
```json
{
  "current_band_capabilities": {
    "supported": true,
    "vendor": "fibocom",
    "method": "AT+GTCCINFO?",
    "schema": "current_band"
  }
}
```

#### get_current_band
获取当前连接的服务小区频段。返回结构与厂商无关；第一版支持 Quectel 和 Fibocom。
```bash
ubus call qmodem get_current_band '{"config_section":"modem1"}'
```

响应示例:
```json
{
  "current_band": {
    "status": "ok",
    "vendor": "quectel",
    "network_mode": "EN-DC",
    "cells": [
      {
        "role": "pcc",
        "rat": "LTE",
        "band": "3",
        "band_name": "LTE B3",
        "channel": "1300",
        "channel_type": "EARFCN",
        "pci": "123",
        "ul_bandwidth": "20",
        "dl_bandwidth": "20",
        "scs": ""
      },
      {
        "role": "nsa",
        "rat": "NR",
        "band": "78",
        "band_name": "NR n78",
        "channel": "627264",
        "channel_type": "NR-ARFCN",
        "pci": "293",
        "ul_bandwidth": "",
        "dl_bandwidth": "100",
        "scs": "30kHz"
      }
    ]
  }
}
```

返回字段:
- `status`: `ok`、`not_registered` 或 `unsupported`。
- `vendor`: 生成该结果的厂商适配实现。
- `network_mode`: 归一化网络模式，例如 `LTE`、`WCDMA`、`NR5G-SA`、`EN-DC`。
- `cells`: 当前服务小区列表，所有厂商使用同一结构。
- `role`: `pcc` 表示主服务小区，`scc` 表示载波聚合辅小区，`nsa` 表示 EN-DC 中的 NR 链路。
- `rat`: 无线接入制式，目前为 `WCDMA`、`LTE` 或 `NR`。
- `band` / `band_name`: 归一化频段号和展示名称。
- `channel` / `channel_type`: 频点号和类型，例如 `EARFCN`、`UARFCN`、`NR-ARFCN`。
- `pci`、`ul_bandwidth`、`dl_bandwidth`、`scs`: 可选值；空字符串表示厂商命令未返回该值。

#### get_reboot_caps
获取可用的重启方法 (硬重启/软重启)。
```bash
ubus call qmodem get_reboot_caps '{"config_section":"modem1"}'
```

#### get_sms
获取短信消息。
```bash
ubus call qmodem get_sms '{"config_section":"modem1"}'
```

#### get_traffic_reset_schedule
读取流量自动清零计划。若未配置，返回完整默认结构。
```bash
ubus call qmodem get_traffic_reset_schedule '{"config_section":"modem1"}'
```

响应示例:
```json
{
  "enabled": false,
  "reset_type": "monthly",
  "hour": 0,
  "day": 1,
  "minute": 0,
  "line": null
}
```

### 控制方法 (写入)

#### clear_dial_log
清除拨号日志。
```bash
ubus call qmodem clear_dial_log '{"config_section":"modem1"}'
```

#### delete_sms
按索引删除短信消息。
```bash
ubus call qmodem delete_sms '{"config_section":"modem1","index":"1 2 3"}'
```

#### do_reboot
重启调制解调器。
```bash
# 硬重启
ubus call qmodem do_reboot '{"config_section":"modem1","params":{"method":"hard"}}'

# 软重启
ubus call qmodem do_reboot '{"config_section":"modem1","params":{"method":"soft"}}'
```

#### set_traffic_reset_schedule
设置流量自动清零计划。写入时会先移除旧计划，再按最新参数更新 UCI 和 cron；若 `enabled` 为 `false`，则仅清除旧计划。
```bash
ubus call qmodem set_traffic_reset_schedule '{
  "config_section":"modem1",
  "enabled":true,
  "reset_type":"monthly",
  "hour":3,
  "day":1
}'
```

响应示例:
```json
{
  "result": true,
  "config_section": "modem1",
  "enabled": true,
  "reset_type": "monthly",
  "hour": 3,
  "day": 1,
  "minute": 0,
  "line": "0 3 1 * * QMODEM_TRAFFIC_RESET_SECTION='modem1' ubus call qmodem clear_stats '{\"config_section\":\"modem1\"}' >/dev/null 2>&1"
}
```

#### send_at
向调制解调器发送 AT 命令。
```bash
ubus call qmodem send_at '{"config_section":"modem1","params":{"at":"AT+CGMM","port":"/dev/ttyUSB2"}}'
```

#### send_raw_pdu
发送原始 PDU 格式短信。
```bash
ubus call qmodem send_raw_pdu '{"config_section":"modem1","cmd":"<PDU_STRING>"}'
```

#### send_sms
发送短信消息。
```bash
ubus call qmodem send_sms '{
  "config_section":"modem1",
  "params":{
    "phone_number":"+1234567890",
    "message_content":"你好世界"
  }
}'
```

#### set_imei
设置调制解调器 IMEI (如果支持)。
```bash
ubus call qmodem set_imei '{"config_section":"modem1","imei":"123456789012345"}'
```

#### set_lockband
设置频段锁定配置。
```bash
ubus call qmodem set_lockband '{
  "config_section":"modem1",
  "params":{
    "bands":"1,3,7,20"
  }
}'
```

#### set_mode
设置网络模式。
```bash
ubus call qmodem set_mode '{"config_section":"modem1","mode":"auto"}'
```

#### set_neighborcell
配置邻区设置。
```bash
ubus call qmodem set_neighborcell '{
  "config_section":"modem1",
  "params":{
    "enable":"1"
  }
}'
```

#### set_network_prefer
设置网络偏好。
```bash
ubus call qmodem set_network_prefer '{
  "config_section":"modem1",
  "params":{
    "prefer":"lte"
  }
}'
```

#### set_sms_storage
设置短信存储位置。
```bash
ubus call qmodem set_sms_storage '{"config_section":"modem1","storage":"SM"}'
```

## 通过 RPCD 的 HTTP 访问

您也可以通过 rpcd 通过 HTTP 访问这些方法:

```bash
# 示例: 获取调制解调器信息
curl -X POST http://192.168.1.1/ubus \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "call",
    "params": [
      "<session_id>",
      "qmodem",
      "info",
      {"config_section":"modem1"}
    ]
  }'
```

## 配置

### UCI 配置节
`config_section` 参数指向 `/etc/config/qmodem` 中的 UCI 配置节。例如:

```
config modem 'modem1'
    option manufacturer 'Quectel'
    option platform 'RG500Q'
    option at_port '/dev/ttyUSB2'
    option path '1-1.4'
    ...
```

### ACL 权限
编辑 `/usr/share/rpcd/acl.d/qmodem.json` 为不同用户组配置访问控制。

## 缓存

许多信息方法使用缓存(默认 10 秒)以避免过度查询调制解调器。缓存文件存储在 `/tmp/cache_*`。

## 故障排除

1. 检查 rpcd 是否正在运行:
```bash
ps | grep rpcd
```

2. 列出可用的 ubus 对象:
```bash
ubus list qmodem
```

3. 检查 rpcd 日志:
```bash
logread | grep rpcd
```

4. 验证脚本权限:
```bash
ls -l /usr/libexec/rpcd/qmodem
```
脚本应该是可执行的。

5. 直接测试脚本:
```bash
echo '{"config_section":"modem1"}' | /usr/libexec/rpcd/qmodem call info
```

## 从 modem_ctrl.sh 迁移

rpcd 接口取代了对 `modem_ctrl.sh` 的直接调用:

**旧方式:**
```bash
/usr/share/qmodem/modem_ctrl.sh info modem1
```

**新方式:**
```bash
ubus call qmodem info '{"config_section":"modem1"}'
```

## 依赖项

- libubox/jshn.sh - JSON 处理
- uci - 配置管理
- jq - JSON 处理
- tom_modem - 调制解调器通信工具
- `/usr/share/qmodem/vendor/` 中的供应商特定脚本

## 注意事项

- 所有方法都需要一个有效的 `config_section` 参数
- config_section 必须存在于 `/etc/config/qmodem` 中
- 供应商特定功能根据调制解调器制造商从 `/usr/share/qmodem/vendor/` 加载
- AT 命令语言(中文/英文)根据系统语言设置自动选择
