# 独立 SIP 服务与多模组

SIP 页面由 `luci-app-qmodem-sipd` 提供，运行服务为 `/etc/init.d/qmodem_sipd`。
它不依赖语音包启动；每个 direction 的 `sms_enabled` 或 `voip_enabled` 任一为 1 即运行。
短信包及语音包按所需能力分别安装。两项都为 0 时不运行对应 SIP worker。
旧服务名仅作为兼容入口，不再重复启动进程，也不等待语音准备完成。

## 分组

`/etc/config/qmodem_sip` 的 group 显式绑定一个本机 `qmodem` modem-device。
每组最多一个 inbound 和一个 outbound；重复绑定同一模组、方向或监听端口会被拒绝。
各方向应配置互不重叠的本地 SIP/RTP 端口及对应网络。没有可用接口地址时等待网络。

```uci
config group 'sip_modem1'
 option modem_id 'modem1'

config direction 'sip_modem1_out'
 option group 'sip_modem1'
 option direction 'outbound'
 option interface 'wan'
 option listen_port '5061'
 option rtp_start '40000'
 option transport 'tls'
 option server 'sip.example.com'
 option port '5061'
 option username 'modem1'
 option password 'replace-with-generated-secret'
 option realm 'sip-gateway'
 option register_interval '300'
 option sms_enabled '1'
 option voip_enabled '0'
```

inbound 使用 `udp_tcp`，必须设置独立用户名和强密码。不要在互联网上暴露未保护的
UDP/TCP 服务。outbound 固定 TLS 并验证证书；设备 CA 信任和系统时间必须正确。

SIP worker 的 ubus 对象为 `qmodem.sip.<group>.<direction>`；独立 PID、凭据和 outbound
配置在 `/var/run/qmodem_sip/`。聚合对象 `qmodem.sip` 返回所有方向状态。
短信转发指定 group/direction；未指定时只有唯一分组允许兼容选择。

## 快速入网

从 `FUjr/sip-gateway-manager` WebUI 导出设备账号 JSON，在 SIP 页面选择本机模组和网络，
粘贴或上传，先预览后应用。JSON 不携带本机串口、ADB、PCM、监听地址或执行命令。
未知字段、错误版本、非法 URI、没有对应软件包或不支持的语音模组均拒绝。
应用仅修改选中模组；现有 database_urc/database_poll 短信模式保留，direct 转为
managed sender 所需的 database_poll。服务更新失败时恢复原配置。

## 多模组语音

`qmodem_voip` 配置包含与 SIP group 同名的 modem section，绑定 modem_id、enabled、interface。
导入及 SIP 页面保存会同步这一绑定。每个 worker 注册 `qmodem.voip.<group>`；媒体 socket、
安全恢复 journal、历史文件均按 group 分开。AT、PCM 和 ADB 必须映射到同一物理 USB 模组。
ADB 根据所选模组 USB 拓扑查找唯一设备；没有唯一结果时拒绝，绝不隐式选择其它设备。

聚合 `qmodem_voip` API 的控制操作接受 `modem_id`；多模组时省略或选择不存在的模组拒绝。
状态查询列出模组，LuCI 通话页面提供选择器。单模组保持省略 modem_id 的兼容行为。
浏览器媒体使用每组独立 socket，现有 uhttpd 地址通过已认证 token 请求选择新连接的模组；
已建立连接保留原 worker。切换期间旧 token 重新连接可能被拒绝，应重新获取 token。

语音仍仅支持已验证的 RM520N-GL USB AT/PCM profile；其它硬件失败关闭。
源代码和目标链接测试不能替代真实双模组同时通话、PCM、恢复和短信发送验收。

## 测试

- `sh application/qmodem_sipd/tests/service-contract.sh`：注册重试及独立服务启用矩阵。
- `OPENWRT_TEST_ROOT=<x86_64 OpenWrt root> python3 application/qmodem_sipd/tests/provision-import.py`：
  使用 Docker 和真实 ucode/UCI 验证预览、字段拒绝、选中模组隔离及服务失败回滚。
- `sh application/voipd/tests/discovery.sh`：多模组选择及不支持/歧义映射拒绝。
- 现有 call-contract、event-port-switch、serial-session、call-history、browser-media-lifetime、safety-verify 测试。

旧配置仅在模组映射唯一时迁移；歧义配置不启动方向，需在 SIP 页面手工指定。
