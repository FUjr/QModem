# QModem SMS Forward Service

短信转发服务允许您将接收到的短信自动转发到各种外部服务，如Telegram、ServerChan、自定义Webhook或执行自定义脚本。

## 功能特点

- 支持多个转发实例，可监听不同的端口
- 轮询间隔可配置（15秒-10分钟）
- 支持多种转发方式：
  - Telegram Bot
  - ServerChan API
  - 通用 Webhook
  - 自定义脚本

## 配置步骤

### 1. 启用Ubus（推荐）

在调制解调器配置页面，建议启用"Use Ubus"选项以获得更好的性能。

### 2. 配置转发服务

访问 "调制解调器" -> "短信" -> "短信转发" 页面：

1. 启用"短信转发服务"
2. 添加转发实例
3. 配置实例参数：
   - 实例名称：用于标识的名称
   - 监听端口：选择要监听的AT端口
   - 轮询间隔：检查新短信的时间间隔
   - 转发API类型：选择转发方式
   - API配置：JSON格式的配置

### 3. API配置示例

#### Telegram Bot
```json
{
  "bot_token": "your_bot_token",
  "chat_id": "your_chat_id"
}
```

#### ServerChan
```json
{
  "token": "SCT123456TCxyz...",
  "channel": "9|66",
  "noip": "1",
  "openid": "openid1,openid2"
}
```

#### 通用 Webhook
```json
{
  "webhook_url": "https://your.webhook.url",
  "headers": "Authorization: Bearer your_token"
}
```

#### 自定义脚本
```json
{
  "script_path": "/path/to/your/script.sh"
}
```

### 4. 自定义脚本环境变量

自定义脚本运行时可访问以下环境变量：
- `$sms_body`: 短信内容
- `$sms_sender`: 发送者号码
- `$sms_time`: 时间戳
- `$raw_pdu`: 原始PDU数据

示例脚本请参考: `/usr/share/qmodem/sms_forward_example.sh`

## 服务管理

可以通过以下方式管理服务：

```bash
# 启动服务
/etc/init.d/sms_forward start

# 停止服务
/etc/init.d/sms_forward stop

# 重启服务
/etc/init.d/sms_forward restart

# 查看状态
/etc/init.d/sms_forward status
```

## 日志

服务运行日志会记录到系统日志中，可以通过以下命令查看：

```bash
logread | grep sms_forward
```

## 注意事项

1. 确保监听的端口是有效的AT端口
2. 轮询间隔过短可能影响性能，建议不低于30秒
3. 自定义脚本需要有执行权限
4. 网络转发需要确保网络连接正常
5. Telegram Bot需要先创建机器人并获取token和chat_id
