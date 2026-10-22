# 增加模组支持文档

## 扫描与拨号的生命周期

`modem_scand` 启动时检查全部已有的 `modem-device`，全量扫描也会检查已有配置。
配置仍按 slot 独立保存；不同 slot 不按序列号、VID/PID 合并，也不迁移 APN 等用户配置。

拨号需要 `/var/run/qmodem/<section>_dir/ready` 中的本次运行确认结果，不能仅凭持久化的
`state=enabled` 启动。确认过程检查设备路径、AT 字符设备的 sysfs 归属和数据网卡，
并记录 sysfs inode，以发现同一路径的重新枚举。PCIe 使用独立 USB 控制口时，仅接受
已有 `modem-slot.associated_usb` 的显式关联；嵌套 QMI 数据网卡沿用 `modem_netdev.sh`。
该文件只用于运行期就绪检查，不是模组身份或跨 slot 配置映射。

自动发现成功后，守护进程先提交扫描配置，再确认就绪并触发拨号服务 reload。
`qmodem_network` 创建 procd 实例前检查就绪状态，拨号脚本在读取配置、启动拨号以及
发送 AT 命令前再次检查。未知状态默认不启动。不要通过手工创建 ready 文件绕过检查。

收到 remove/disable 后立即撤销确认结果，使正在执行的旧扫描不能再次发布就绪状态。
随后设置 `state=disabled`，通过 `qmodem_network offline <section>` 停止 procd 实例和
所属连接管理进程，清理该段拥有的网络接口。offline 不查询 SIM、不向旧 AT 口发送
挂断命令。停拨失败保持未就绪，按扫描重试参数进行有限次数的重试。

`block_auto_probe=1` 只禁止自动发现和探测改写；已有配置的存在性检查和掉线处理仍然执行。
`fixed_device=1` 同样需要存在性确认。手动配置的路径或端口已失效时保持停用，需要用户
修正配置后重查；不会自动将它绑定到其他 slot。自动模式可以重新探测同一 slot 的端口。

可用 `modem_scanc check <section>` 请求重新检查，或用 `modem_scanc scan all` 检查全部
旧段并按当前策略发现设备。这些命令返回的是入队结果，不代表扫描或停拨已经完成。
设备验收还应检查 UCI 状态、procd 实例、拨号子进程和该段的网络接口。

宿主机回归入口：`sh application/qmodem/tests/test_modem_presence.sh`，需要 C 编译器、
json-c 开发库、Python 3 和 Bash。该测试使用隔离的 sysfs/UCI/procd fixture，覆盖启动门禁、
端口复用、同路径重新枚举、PCIe 关联、旧事件失效、提交失败和停拨重试；不替代实机拔插验证。
本改动需要同时更新 `qmodem` 和 `modem_scan` 包。

## 流程简介

在以下几个地方会触发模组扫描
负责扫描的都是 ```luci/luci-app-qmodem/root/usr/share/qmodem/modem_scan.sh``` 脚本
### 模组扫描流程：

1. qmodem_init 服务
2. 网卡和usb的hotplug事件
3. 网页端的手动扫描

*PCIe模组扫描* 遍历 ```/sys/class/net/``` 检查是否存在 ```/sys/bus/pci[e]``` 下的设备,如果存在且含有 加载了串口驱动的接口，则尝试添加该设备
*USB模组扫描* 遍历 ```/sys/class/net/``` 检查是否存在 ```/sys/bus/usb``` 下的设备,如果存在且含有 加载了串口驱动的接口，则尝试添加该设备
*监控预设的USB端口* 遍历 uci 配置 ```qmodem.@modem-slot``` , 扫描 ```slot_type``` 为 ```usb``` 的设备，如果存在且含有加载了串口驱动的接口，尝试添加该设备
*监控预设的PCIe端口* 遍历 uci 配置 ```qmodem.@modem-slot``` , 扫描 ```slot_type``` 为 ```pcie``` 的设备，如果存在且含有加载了串口驱动的接口，尝试添加该设备

### 尝试添加设备流程：
设备经过扫描流程后，会将 devpath 和 slot_type 传入添加流程
设备添加时会向设备发送 ```ATI``` 命令，如果包含返回 ```OK``` 字符串的则认为该端口可用，标记为可用端口后加入列表
检查完所有端口后
