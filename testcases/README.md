# QModem AT 指令 testcases（fixture）

本目录收集各 vendor 模组的真实 AT 指令输入与原始输出，用于在无硬件环境回放测试 vendor 脚本的解析逻辑。

## 目录结构

```
testcases/
  recognition/                       # vendor/model 尚未识别时发送的探测指令
    <resolved-vendor>/<platform>/<model-profile>/
      ATI-9226517c.json               # 保留采集时身份并记录 expected_identity
  <vendor>/                          # 与 vendor/dynamic_load.json 的厂商名一致
    <platform>/                      # qualcomm / mediatek / unisoc / ...
      <model-slug>-<model-md5前8位>/ # 同名、空格和特殊字符不会造成目录冲突
        AT_CGSN-7c58b773.json        # 一条指令的采集记录
        expected/
          default/
            get_imei.json            # 该场景专属的业务层黄金输出
```

## fixture 格式

```json
{
  "schema_version": 2,
  "vendor": "quectel",
  "platform": "qualcomm",
  "model": "RM500Q-AE",
  "command": "AT+CGSN",
  "tool": "at",
  "responses": [
    {
      "scenario": "default",
      "sequence": 0,
      "capture_sequence": 0,
      "response_hex": "41542b4347534e0d0d0a3836303030303030303030303031320d0a0d0a4f4b0d0a",
      "rc": 0,
      "timestamp": "2026-08-07T00:00:00Z",
      "source": "device",
      "assertions": [
        {
          "parser": "quectel.cgsn",
          "context": {},
          "expected": {"imei": "860000000000012"},
          "expected_rc": 0
        }
      ]
    }
  ]
}
```

- `command`：实际发送的完整 AT 指令（含参数）。
- `vendor`、`platform`、`model`：采集时的厂商、平台和 UCI `name`（Modem Model）。回放以三者组成的设备画像为边界；同一条 AT 指令可以在不同画像中保存不同响应。
- `responses[]`：同一命令可保存多个响应和场景；回放按 `scenario` 隔离，并按 `sequence` 从 0 依次消费，队列耗尽会失败而不是重复最后一条。
- `response_hex`：单次模组原始 stdout 的十六进制编码，由 `xxd -p` 生成；可无损保存 CR/LF、尾部换行及任意二进制字节。
- `tool`：`at` 或 `fastat`；响应内的 `rc` 是发送工具退出码。真机采集写 `source: device`，人工样本必须写 `source: synthetic`。
- `assertions[]`：同一原始响应可交给多个稳定 parser ID 独立解析。每项显式给出 `context`、规范化语义 JSON `expected`，并可用 `expected_rc` 断言失败路径。ID 只经过静态 registry 分发，不作为 shell 函数名执行。
- `sanitized`：`qmodem_collect pack` 默认脱敏（≥11 位数字串保留头2尾2、中间置 0，长度不变），标记为 true；`pack --raw` 可关闭脱敏（注意隐私）。
- `capabilities.modes`：仅用于不在 `modem_support.json` 中的合成 fixture；真实型号的拨号模式由 runner 从能力表读取。

识别前的指令先写入设备上的 `recognition/pending/<config-section>/`。打包时，
采集器读取该 section 最终识别出的 vendor、platform 和 model，将记录移动到
`recognition/<vendor>/<platform>/<model-profile>/`，并写入
`expected_identity`。无法解析最终身份的 pending 记录会保留，但导入脚本会拒绝
它们，避免把未归属样本误并入仓库。

## 采集与提交

设备端：

```sh
uci set qmodem.main.testcase_collect=1 && uci commit qmodem
# 通过 LuCI / ubus / CLI 触发各功能（base_info、cell_info、锁频、锁小区……）
qmodem_collect status        # 查看已采集数量
qmodem_collect pack          # 默认脱敏并加密到 /tmp/qmodem_feedback_<时间戳>.tar
qmodem_collect pack --unencrypted # 明确要求生成未加密 tar.gz
qmodem_collect clear         # 清空采集目录（下一轮采集前）
```

默认编译选项会安装 `qmodem-seal`。加密打包结束后会显示一个仅属于本次
反馈的“审阅密码/密钥”（`review key`），提交者可用输出中的命令解密并检查
内容。它是随机生成的高强度密钥，而不是要求用户记忆的密码。上传反馈包时
不要同时公开该密钥。维护者使用未公开的 identity token 解密同一文件。

反馈者应在提交前使用 review key 解密反馈包，确认其中只包含愿意公开的指令
响应，并确认默认脱敏结果符合预期。加密用于保护公开传输和存储过程，不能
代替反馈者自己的内容检查。反馈包中的数据可能被维护者选入仓库 testcase；
正式合入前还会再次人工审阅和脱敏，但这也不能替代提交前检查。

其他维护者需要处理反馈时，可只解压并把 `manifest.json` 发给 identity token
持有者。token 持有者无需下载较大的 `payload.enc`，执行下列命令即可恢复该包
的 review key，再通过私密渠道交给维护者：

```sh
qmodem-seal review-key --manifest manifest.json
```

如果固件编译时取消了 `qmodem-seal`，`pack` 会明确警告并回退到未加密
tar.gz；请在上传前自行检查。`--unencrypted` 可在已安装加密组件时主动要求
明文包。正式发布 recipient 尚未配置时，加密打包会拒绝执行，不会静默生成
明文。

开发机：

```sh
scp root@<device>:/tmp/qmodem_feedback_*.tar .
# 维护者先执行 qmodem-seal decrypt，得到 qmodem_testcases_*.tar.gz
scripts/import_testcases.sh qmodem_testcases_*.tar.gz
git add testcases && git commit
```

## 本地回放测试

```sh
bash application/qmodem/tests/test_vendor_fixtures.sh
bash application/qmodem/tests/test_parser_fixtures.sh
bash application/qmodem/tests/test_recognition_fixtures.sh
```

单独调试 parser 时，原始响应从 stdin 输入，设备上下文必须显式传入：

```sh
xxd -r -p response.hex | \
  application/qmodem/files/usr/share/qmodem/parsers/parse.sh \
    quectel.cops.operator --platform qualcomm --model RM500Q-AE \
    --context-json '{}'
```

成功时输出单行规范化 JSON；无法解析返回退出码 1 和结构化错误 JSON，参数或
parser ID 非法返回退出码 2。registry 只允许静态列出的稳定 ID，同一份 stdin
可以由不同 ID 分别调用，不会把 fixture 内容当作 shell 函数执行。

三层校验：

1. fixture 的路径必须与 `vendor/platform/model` 元数据一致，且指令头仍存在于对应 `cmds/<vendor>.sh`；
2. 每个设备画像和 scenario 建立独立命令响应队列，用 fixture 回放 `at`/`fastat`；不同型号、平台、场景不会互相覆盖；
3. 每条 parser assertion 都从原始 `response_hex` 重新解码，允许同一响应由多个 parser 独立解析，并精确比较退出码及规范化语义 JSON；
4. vendor 只读方法必须退出码 0 且输出合法 JSON；
5. 存在画像专属 `expected/<scenario>/<method>.json` 时，业务方法输出经 `jq -S` 归一化后与快照精确比对。parser testcase 不绑定最终接口字段，因此业务 JSON 政名不要求修改单命令 parser assertion。

末尾会打印 cmds 指令的 fixture 覆盖报告（仅提示，不失败——覆盖率依赖真机捐赠）。
