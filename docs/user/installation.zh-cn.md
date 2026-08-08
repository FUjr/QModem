# 安装 QModem

QModem 是一个 OpenWrt Feed，不是与任意固件通用的单个安装包。安装前先确认路由器架构、OpenWrt 分支、内核版本、可用存储空间和模组连接方式。

## 选择主界面

新部署推荐：

```text
qmodem
luci-app-qmodem-next
```

`qmodem` 提供后端和运行服务，`luci-app-qmodem-next` 提供纯 JavaScript LuCI 页面。旧版 `luci-app-qmodem` 及其短信、MWAN、TTL 插件仍在仓库中，但不应与 Next 主界面同时安装。选择前先确认所需功能是否出现在对应界面中。

## 从 OpenWrt 源码树构建

在 `feeds.conf.default` 添加：

```text
src-git qmodem https://github.com/FUjr/QModem.git;main
```

更新并安装 Feed 索引：

```sh
./scripts/feeds update qmodem
./scripts/feeds install -a -p qmodem
make menuconfig
```

在 `LuCI -> Applications` 选择主界面。根据目标硬件和模组接口选择 QMI、MBIM、MHI 或厂商驱动；不要仅因为菜单中存在某个驱动就全部启用。

构建完整固件：

```sh
make -j"$(nproc)"
```

排查构建错误时重新执行：

```sh
make -j1 V=s
```

## 使用 OpenWrt SDK 构建

SDK 必须与目标 OpenWrt 版本、target 和 subtarget 对应。把 QModem 添加为 Feed 后，更新索引、安装所需包，再构建具体软件包。SDK 能验证包依赖和目标工具链，但不能验证模组硬件行为。

## 安装预编译包

安装前检查：

```sh
ubus call system board
uname -r
opkg print-architecture
```

较新使用 APK 的 OpenWrt 分支应使用对应 `.apk`，使用 opkg 的版本应使用 `.ipk`。内核模块必须匹配运行固件的内核 ABI。遇到内核依赖不匹配时，应获取匹配固件的软件包或重新编译，不建议用 `--force-depends` 绕过检查。

先安装底层依赖和 `qmodem`，再安装 LuCI 包。安装后重启 rpcd 或设备，并确认相关服务存在：

```sh
ubus list | grep -E 'qmodem|at-daemon'
/etc/init.d/qmodem_init status
/etc/init.d/qmodem_network status
```

不同固件可能没有实现统一的 `status` 输出；此时结合 `logread` 和进程列表检查。

## 升级

升级前备份：

```sh
uci export qmodem > /tmp/qmodem-backup.txt
```

同时记录当前 QModem 版本、模组端口、拨号协议和工作状态。不要把包含 SIM PIN、APN 密码或设备身份信息的备份直接上传到公开 Issue。

跨大版本升级后应依次验证：

1. 模组仍绑定到正确物理卡槽。
2. AT 端口和数据接口没有变化。
3. APN、PDP 类型和拨号协议保持正确。
4. 默认路由、DNS、IPv6 和防火墙行为符合预期。
5. 锁频、锁小区等高级设置仍适用于当前模组固件。

## 下一步

安装完成后按照[首次配置](first-setup.zh-cn.md)验证从硬件枚举到公网连接的完整链路。
