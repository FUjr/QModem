# ubus_benchmark.py 使用说明

## 简介

`scripts/ubus_benchmark.py` 是一个基于 UBUS RPC 的 AT 命令并发压测脚本，主要用于：

1. **适配新模块**：批量发送常用 AT 命令，快速确认模块基本功能和串口通信正常。
2. **故障排查**：并发压测指定命令，定位模块或 `at-daemon` 在高负载下的异常行为（如串口锁死、响应超时、队列溢出等）。

---

## 依赖

```bash
pip install requests
```

运行环境：Python 3.7+，需能访问 OpenWrt 设备的 `/ubus` 接口（HTTP 80 端口）。

---

## 快速开始

编辑脚本顶部的配置项，然后直接运行：

```bash
python3 scripts/ubus_benchmark.py
```

---

## 配置项说明

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `IP` | `10.0.0.1` | OpenWrt 设备 IP 地址 |
| `AT_PORT` | `/dev/ttyUSB3` | 模块 AT 串口路径 |
| `AT_COMMANDS` | `["ATI", ...]` | 待测 AT 命令列表，随机轮询发送 |
| `NUM_CALL` | `100` | 总请求次数 |
| `NUM_THREAD` | `10` | 并发线程数 |
| `LOGIN_USERNAME` | `root` | OpenWrt 登录用户名 |
| `LOGIN_PASSWORD` | *(空)* | OpenWrt 登录密码 |

## 不同场景的推荐命令集

### 新模块基础验证

确认模块能正常识别、注网、查询信号：

```python
AT_COMMANDS = [
    "ATI",          # 模块型号信息
    "AT+CGMM",      # 产品型号
    "AT+CGMI",      # 厂商名称
    "AT+CGSN",      # IMEI
    "AT+CSQ",       # 信号强度 (RSSI)
    "AT+CPIN?",     # SIM 卡状态
    "AT+CREG?",     # CS 注网状态
    "AT+CGREG?",    # PS 注网状态
    "AT+CGDCONT?",  # PDP 上下文配置
]
```

### 压测串口并发稳定性

用于排查 `at-daemon` 在高并发下是否出现串口锁或队列堆积：

```python
AT_COMMANDS = ["AT+CSQ", "ATI"]
NUM_CALL    = 1000
NUM_THREAD  = 50
```

### 排查特定命令超时

针对某条可疑命令做集中测试：

```python
AT_COMMANDS = ["AT+COPS=3,2;AT+COPS?"]   # 耗时较长的命令
NUM_CALL    = 200
NUM_THREAD  = 20
```

---

## 输出说明

脚本运行后输出：

1. **请求统计**：总数、成功数、失败数、成功率。
2. **响应时间分布**：AT 响应时间（ms）和 HTTP 请求耗时的最小 / 最大 / 平均值。
3. **响应内容分组**：按 `AT命令 + 响应内容` 分组，便于发现异常响应（如 `ERROR`、空响应）。
4. **失败原因统计**：汇总所有失败类型及对应线程编号。
5. **AT 命令分布统计**：每条命令的成功率与响应时间。

结果同时保存至：

```
ubus_test_results_<YYYYMMDD_HHMMSS>.json
```

---

## 常见错误处理

| 错误信息 | 含义 | 排查方向 |
|----------|------|----------|
| `RPC error -32002: Access denied` | token 无权限调用 `at-daemon` | 检查设备 `/usr/share/rpcd/acl.d/` 中是否有对应 ACL，执行 `/etc/init.d/rpcd restart` |
| `登录失败，UBUS 错误码: 6` | 用户名或密码错误 | 确认 `LOGIN_USERNAME` / `LOGIN_PASSWORD` |
| `Request timeout` | 请求超时（默认 30s） | 检查网络连通性；串口可能被占用或模块无响应 |
| `UBUS call failed: ...` | at-daemon 返回非 success 状态 | 查看设备日志 `logread \| grep at-daemon` |
如果RPC error -32002 可以尝试以下命令
```
cat << EOF >/usr/share/rpcd/acl.d/at-daemon.json

{
  "at-daemon": {
    "description": "at-daemon access",
    "read": {
      "ubus": {
        "at-daemon": ["sendat"]
      }
    }
  }
}

EOF
/etc/init.d/rpcd restart
```
