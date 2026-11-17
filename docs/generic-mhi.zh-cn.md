# Generic MHI 适配

QModem 支持上游 `mhi-pci-generic` 的两条数据路径：

| 数据驱动 | 控制口 | 数据口 | 拨号方式 |
| --- | --- | --- | --- |
| `mhi_net` / `IP_HW0` | 同一 MHI 控制器下、类型为 QMI 的 WWAN 口 | `mhi_hwip*` | raw-IP，无 QoS/QMAP 聚合头 |
| `mhi_wwan_mbim` / `IP_HW0_MBIM` | 同一 MHI 控制器下、类型为 MBIM 的 WWAN 口 | 原生 WWAN 默认链路 | MBIM session 0 |

仅出现 `/dev/wwan*mbim*` 控制口不代表具备 MBIM 数据通道。内核必须实际提供并绑定 `IP_HW0_MBIM`；本适配不更改内核通道表，也不把 raw-IP 的 `mhi_hwip*` 当作 MBIM 数据口。原生 MBIM 当前使用默认链路，不创建额外的 multiplex session。

## 编译与配置

启用 QModem 的 `Add PCIe Modem SUPPORT`，MHI 驱动选择 `Use Generic MHI PCIe Driver`，拨号器选择 `Tom customized Quectel CM`。依赖为 `kmod-mhi-net`、`kmod-mhi-pci-generic`、`kmod-mhi-wwan-ctrl`、`kmod-mhi-wwan-mbim`。

扫描和拨号按 sysfs 归属查找端点，不固定 MHI 或 WWAN 编号。`IP_SW0` 不作为拨号候选；多个独立数据端点或同类型控制口无法唯一匹配时拒绝选择。旧厂商 `mhi_netdev` / `mhi_uci_q` 路径继续保留。

如果模块没有 PCIe AT 口，需要在对应的 `modem-slot` 中明确设置 `associated_usb`，借用该模块的 USB AT 口，例如：

```uci
config modem-slot 'pcie0'
        option type 'pcie'
        option slot '0002:01:00.0'
        option associated_usb '2-1'
```

不要同时对同一模块启动 USB 与 PCIe 拨号。USB 和 PCIe 配置仍是独立实例，不按模块身份合并或迁移 APN。

## 回归检查

主机需要 C 编译器与 json-c 开发库。可执行：

```sh
python3 tests/test_generic_mhi.py
sh application/qmodem/tests/test_modem_netdev.sh
cc -ffunction-sections -fdata-sections \
  application/quectel_CM_5G_M/tests/test_mhi_format.c \
  -Wl,--gc-sections -lpthread -o /tmp/test-mhi-format
/tmp/test-mhi-format
```

拓扑测试覆盖不同 MHI/WWAN 编号、HW/SW 双通道、控制口归属、缺失与重复控制口、原生 MBIM 默认链路和旧厂商驱动。协议测试检查 raw-IP、禁用 QoS/聚合以及不带 mux-id 的 PCIe WDS 绑定。

## 本次验收标准

本次以控制面适配完成为验收标准：设备扫描与型号识别、按控制器归属匹配控制口、显式关联 USB AT 口，以及 generic QMI 的控制协议交互。main、stable 已完成上述适配，并通过主机回归与 ARM64 APK SDK 编译；当前设备已验证 QMI 控制交互。

原生 MBIM 适配通过拓扑回归与编译，当前设备不具备相应数据通道，未完成 MBIM 硬件协议交互验证。数据面吞吐、长期连通性、自动重拨稳定性及 PCIe AER 恢复不作为本次完成条件；下列实测结果保留用于后续定位。

## 2026-10-26 验证记录

使用 Misectel M02K88、RM520N-GL、ImmortalWrt 25.12.1 / Linux 6.12.94 验证 generic QMI。设备通过 `mhi-pci-generic`、`mhi_net` 和 `mhi_wwan_ctrl` 工作，PCIe 无 AT 口，通过显式关联的 USB AT 口识别模块。main 和 stable 均验证了 IPv4/IPv6 地址、路由、DNS 配置与绑定 `mhi_hwip0` 的公网连通性。main 的一次拨号进程终止测试成功自动重拨；stable 的后续同类测试发生下述 AER 故障，自动重拨稳定性尚未确认，不影响本次控制面适配完成结论。

构建采用校验 SHA256 的 OpenWrt snapshot mediatek/filogic ARM64 APK SDK（GCC 14.4.0），分别编译 qmodem、modem_scan、quectel-CM-5G-M。设备保留原有内核，部署用户态适配文件进行验证。

该设备未提供原生 MBIM 数据通道，MBIM 验证限于拓扑回归和 SDK 编译，不代表完成 MBIM 硬件拨号验收。OpenWrt 23.05.5 IPK 不在本次验证范围。

复测中还观察到 PCIe AER `CmpltTO` 和下游链路失活，MHI 通道随之消失。该故障在重新打开拨号通道的测试中重复出现，但触发原因尚未确定，需要继续定位。不能将上述短时连通性结果作为长期稳定性结论。
