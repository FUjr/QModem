# QModem AT 指令 testcases（fixture）

本目录收集各 vendor 模组的真实 AT 指令输入与原始输出，用于在无硬件环境回放测试 vendor 脚本的解析逻辑。

## 目录结构

```
testcases/
  <vendor>/                          # 与 vendor/dynamic_load.json 的厂商名一致
    AT_CGSN-7c58b773.json            # 一条指令的采集记录（文件名：指令净化名-md5前8位）
    expected/
      get_imei.json                  # 可选：采集时记录的方法级黄金输出（jq -S 比对）
```

## fixture 格式

```json
{
  "vendor": "quectel",
  "command": "AT+CGSN",
  "response_hex": "41542b4347534e0d0d0a3836303030303030303030303031320d0a0d0a4f4b0d0a",
  "tool": "at",
  "rc": 0,
  "timestamp": "2026-08-07T00:00:00Z",
  "sanitized": true
}
```

- `command`：实际发送的完整 AT 指令（含参数）。
- `response_hex`：模组原始 stdout 的十六进制编码，由 `xxd -p` 生成；可无损保存 CR/LF、尾部换行及任意二进制字节。
- `tool`：`at` 或 `fastat`；`rc`：发送工具的退出码。
- `sanitized`：`qmodem_collect pack` 默认脱敏（≥11 位数字串保留头2尾2、中间置 0，长度不变），标记为 true；`pack --raw` 可关闭脱敏（注意隐私）。

## 采集与提交

设备端：

```sh
uci set qmodem.main.testcase_collect=1 && uci commit qmodem
# 通过 LuCI / ubus / CLI 触发各功能（base_info、cell_info、锁频、锁小区……）
qmodem_collect status        # 查看已采集数量
qmodem_collect pack          # 打包并脱敏到 /tmp/qmodem_testcases_<时间戳>.tar.gz
qmodem_collect clear         # 清空采集目录（下一轮采集前）
```

开发机：

```sh
scp root@<device>:/tmp/qmodem_testcases_*.tar.gz .
scripts/import_testcases.sh qmodem_testcases_*.tar.gz
git add testcases && git commit
```

## 本地回放测试

```sh
bash application/qmodem/tests/test_vendor_fixtures.sh
```

三层校验：

1. 每条 fixture 的指令头必须仍存在于对应 `cmds/<vendor>.sh`（防指令漂移）；
2. 用 fixture 回放 `at`/`fastat`，vendor 只读方法必须退出码 0 且输出合法 JSON；
3. 存在 `expected/<method>.json` 时，方法输出经 `jq -S` 归一化后与快照精确比对。

末尾会打印 cmds 指令的 fixture 覆盖报告（仅提示，不失败——覆盖率依赖真机捐赠）。
