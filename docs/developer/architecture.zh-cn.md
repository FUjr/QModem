# 系统架构

QModem 是一组协作的软件包，不是单一进程。核心职责可以分成设备发现、控制面、AT 传输、数据拨号和用户界面五层。

## 组件关系

```text
                         +----------------------+
                         | LuCI / external ubus |
                         +----------+-----------+
                                    |
                              rpcd ACL + API
                                    |
                         +----------v-----------+
                         | QModem control layer |
                         | generic + vendor     |
                         +----+------------+----+
                              |            |
                       cmds wrappers   dial lifecycle
                              |            |
                    +---------v---+    network/firewall
                    | AT transport |
                    | tom / ubus   |
                    +---------+----+
                              |
   hotplug --> modem_scand -->+--> USB / PCIe modem
```

## 设备发现流程

```text
USB/PCIe hotplug 或手动扫描
  -> modem_scanc 提交事件
  -> modem_scand 队列、去重和延迟执行
  -> 枚举物理卡槽、串口和数据接口
  -> 应用 modem_port_rule.json
  -> 并行探测可用 AT 端口
  -> 识别型号并匹配 modem_support.json
  -> 创建或更新 UCI modem-device
  -> 执行初始化和拨号服务
```

卡槽用于描述物理位置，`modem-device` 描述当前识别到的设备。代码不能假设 `/dev/ttyUSB2` 永远属于同一张模组。

`modem_port_rule.json` 用于处理特定 `VID:PID` 的 interface allowlist 和 option 驱动绑定。应基于真实 USB composition 配置规则，不能因为某个诊断口会回应 `AT` 就把它加入候选端口。

## 控制调用流程

```text
LuCI
  -> ubus qmodem method
  -> /usr/libexec/rpcd/qmodem
  -> 读取 UCI modem-device
  -> 加载 generic.sh
  -> 按 dynamic_load.json 加载 vendor 脚本
  -> 调用 cmds/<vendor>.sh 中的命令封装
  -> modem_util.sh 选择 tom_modem 或 ubus-at-daemon
  -> 解析响应并返回 JSON
```

### Generic 层

定义通用实现、默认返回和所有 vendor 都必须具备的兼容函数。Vendor 未覆盖某项能力时应得到明确的“不支持”结果，而不是调用不存在的函数。

### Vendor 层

负责解释厂商 AT 语义和响应，不负责串口实现。按平台或型号分支前，应先确认差异确实来自厂商固件，而不是端口、网络状态或测试环境。

### Cmds 层

保存所有实际发送的 AT 命令。Vendor、generic、工具和拨号脚本只能调用 `cmd_*` 方法，这使命令能够被采集、回放和静态检查。

### AT 传输层

`tom_modem` 提供底层请求；`ubus-at-daemon` 用于集中管理串口和减少多个进程争用。任何方案都必须保证同一 AT 端口只有一个响应读取者，并正确区分命令响应和异步 URC。

## 数据拨号

拨号层根据配置和设备 profile 选择 QMI、MBIM、NCM、ECM、RNDIS、MHI 等实现，并管理接口、路由、DNS、IPv6 和服务生命周期。AT 控制成功不代表数据接口已建立；两条链路必须分别验证。

## 配置、状态和缓存

- 持久用户配置保存在 UCI。
- 自动识别结果只有在需要跨重启复用时才进入 UCI。
- 进程状态和日志放在 `/var/run/qmodem/` 等运行目录。
- 短期查询缓存必须按模组隔离、加锁并原子更新。
- 临时文件必须使用私有目录或 `mktemp`，不能让多个模组共享固定文件名。

## 安全边界

- rpcd ACL 应区分只读状态和会改变模组/网络的写操作。
- Unix Socket 和运行目录不应对所有本地用户开放写权限。
- 外部输入不得拼接给 `eval`、`system()` 或 `sh -c`。
- AT 调试本质上是高权限能力，前端隐藏按钮不构成权限控制。
- 日志、fixture 和反馈包需要对 IMEI、IMSI、ICCID、号码、凭据和短信内容脱敏。
