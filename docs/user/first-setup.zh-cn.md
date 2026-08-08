# 首次配置

首次配置应沿着“硬件枚举、控制端口、数据接口、拨号、系统网络”的顺序检查。不要在设备尚未正确枚举时反复修改 APN。

## 1. 确认硬件被系统识别

连接模组后查看内核日志和总线设备：

```sh
logread -e usb -e mhi -e tty -e qmi -e mbim
ls -l /dev/ttyUSB* /dev/ttyACM* /dev/mhi_* /dev/wwan* 2>/dev/null
ip link show
```

USB 模组还应记录 `VID:PID`、USB 拓扑位置以及每个 interface 对应的驱动。PCIe 模组应确认 MHI 控制和数据设备都已出现。

如果只有 USB 设备而没有串口或数据接口，通常应先解决驱动、USB composition、供电或硬件连接问题。

## 2. 扫描模组

在 LuCI 中执行扫描，等待设备出现在模组列表。扫描成功后检查：

- 厂商和型号没有被误识别。
- 物理卡槽与实际连接位置一致。
- AT 端口属于该模组，而不是调试口、GNSS 口或另一张模组。
- 数据接口与准备使用的拨号协议匹配。

多模组设备必须逐张核对，不能只凭 `/dev/ttyUSB2` 之类的编号长期绑定；设备重连后串口编号可能变化。

## 3. 验证 AT 通道

通过 LuCI 的 AT 调试发送只读命令，例如：

```text
AT
ATI
AT+CGMM
AT+CGMR
AT+CPIN?
```

应得到完整响应和终止标志。不要同时使用另一套 WebUI、串口终端或模组自带 ATD 访问同一端口。如果响应被截断、混入 URC 或频繁超时，先解决端口并发问题。

## 4. 配置拨号

最少需要确认：

- **启用拨号**：是否允许该模组自动建立数据连接。
- **协议**：QMI、MBIM、NCM、ECM、RNDIS 或设备支持的其他方式。
- **APN**：运营商要求的接入点；运营商支持自动获取时可以留空。
- **PDP 类型**：IPv4、IPv6 或 IPv4/IPv6。
- **认证**：无认证、PAP 或 CHAP，以及必要的用户名和密码。
- **PIN**：SIM 启用了 PIN 锁时填写。
- **路由 metric**：存在多个 WAN 时用于决定默认路由优先级。

选择协议时以真实数据接口为准：出现 `cdc-wdm` 不自动证明所有 QMI/MBIM 组合都可用；MHI 模组也可能因固件 composition 不同暴露不同控制接口。

## 5. 验证连接结果

拨号后依次检查：

```sh
ip address show
ip route show
ip -6 route show
cat /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null
logread -e qmodem
```

成功标准不只是页面显示“已连接”，还包括：

1. 数据接口获得预期的 IPv4 或 IPv6 地址。
2. 默认路由或策略路由指向正确接口。
3. DNS 服务器可用。
4. 防火墙把接口放入预期区域。
5. 实际流量能够通过该模组收发。

## 6. 最后配置高级功能

基础拨号稳定后再设置锁频、锁小区、SIM 切换、自定义初始化 AT、桥接、LED 和流量重置。每次只改变一类设置并验证结果，保留恢复到自动模式的路径。

遇到问题时进入[故障排查](troubleshooting.zh-cn.md)。
