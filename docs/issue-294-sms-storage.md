# Issue #294：模块短信删除与收信展示延迟修复

## 背景与范围

- 问题：[SIM 卡短信管理无法删除短信](https://github.com/FUjr/QModem/issues/294)。
- [最新反馈](https://github.com/FUjr/QModem/issues/294#issuecomment-6630836129)：收信后可能十多分钟才在页面显示。
- 实现基于 `origin/main` 的 `99553e5a4cdf577a678e8fa3d4aac5f4de1d2f36`，工作分支为 `fix/issue-294-sms-storage`。
- 本次仅处理模块原始短信删除和数据库模式展示延迟，保留现有 Direct 模式的分片显示方式。

数据库模式下，原“SIM 卡短信管理”页面通过通用 `list` 接口取得 SQLite 历史记录，却使用模块 `index` 删除。数据库 `id` 与模块 `index` 含义不同，不能互相替代。两个页面读到同一份历史记录，也解释了原反馈中的联动删除现象。

延迟方面，原 URC 模式完全依赖通知；漏通知后缺少定时补扫。缺片超时发布也依附于下一次同步，没有新事件时可能一直不展示。以上是源码定位结果，尚未在反馈者的模块上确认具体触发原因。

## 最小改动设计

### 原始存储与历史记录分开

在 `qmodem.sms` 增加两个薄接口，复用现有 `run_tom()` 和 AT 传输方式，不迁移数据库，不更改 CPMS 设置。

| 接口 | 参数 | 行为 |
| --- | --- | --- |
| `sim_list` | `modem_id` | 查询 `AT+CPMS?` 的实际读取存储区，再读取模块原始短信；返回 `storage`、`mode`、`auto_delete`、`messages`。三种模式均使用此路径。 |
| `sim_delete` | `modem_id, storage, index, pdu` | 删除前重新读取存储区和原始短信，确认 index 对应的 PDU 未变化，再执行删除；支持 index 0。 |

存储区变化、索引复用或读取失败均拒绝删除。原短信已经不存在时按幂等成功处理，不对该索引再次发删除命令。删除完成后仅更新已归档且身份完全匹配的 `source_messages.deleted_at`，保留历史、分片和转发记录；该更新失败时明确返回错误，并保留已经实际删除的计数。

原 `list/delete/modem_list/modem_delete` 等接口继续保留。新页面不回退到历史记录接口，缺少新接口时提示同时更新 qmodem-smsd 与 LuCI。

### 页面行为

页面和菜单改称“模块短信存储”，显示实际读取区（SM/ME 等），避免把模块存储统一称作 SIM 卡。当数据库模式启用归档后自动删除时，说明空列表与历史仍在的关系。

单条和全部删除共用确认流程。确认时复制当前列表的 `index/pdu` 快照，锁定模块选择与页面操作，并暂停轮询；逐条删除后分别统计已删除、已不存在和失败，部分失败仍继续处理剩余快照。删除期间新到的短信不加入删除集合。完成后重新读取，轮询错误直接显示，过期的读取结果不能覆盖切换模块后的页面。

### 展示延迟

- 打开或手动刷新短信列表、会话时，两种数据库模式先同步再重新读库。URC 页面的后台刷新只读库。
- 在已有 30 秒调度器中，让 URC 模式按现有 `sms_poll_interval` 补扫，默认仍为 300 秒。正常通知继续立即同步，Direct 模式不参与数据库调度。
- 同一调度器独立检查缺片超时，无需等待另一次 URC 或 AT 扫描。沿用现有缺片等待、迟到分片合并、去重及转发逻辑。

在进程和 AT 读取正常的条件下，漏通知后的发现时间受配置补扫周期与调度间隔限制；这不是对真实网络收信时间的保证。

## 验证记录（2026-11-05）

| 验证层次 | 结果与覆盖 |
| --- | --- |
| C 编解码及数据库回归 | 通过；包括分片合并、重复超时不重复转发、按完整身份更新来源记录。 |
| 守护进程原生集成 | 通过；使用真实 UCI/SQLite/ubus 数据结构和实际回调，AT 子进程为模拟。覆盖三种模式、SM/ME、index 0、索引复用、存储变化、幂等删除、AT 失败、元数据失败、URC 补扫、独立缺片发布、自动归档删除及历史保留。 |
| JavaScript 回归 | 通过；覆盖新旧来源隔离、主动同步、旧接口版本提示、模块切换、轮询竞态、确认取消、串行快照删除、部分失败及新短信保留。已接入现有 SMS CI 工作流。 |
| Chromium 页面检查 | 通过；真实浏览器加载实际 service/view 代码，RPC 使用模拟响应；三种模式均通过，无页面异常。不是完整路由器 LuCI 联调。 |
| ARM64 OpenWrt 交叉构建 | 通过；使用现有 aarch64 musl 工具链及依赖，隔离执行原包的 Prepare/Compile/Install 配方，验证 daemon、共享库、配置、init 和 ACL 安装内容。未生成完整固件或 ipk。 |
| LuCI 安装内容 | 通过；四个修改的 JS 经 SDK jsmin 压缩和语法检查，中文翻译经 msgfmt 检查并用 po2lmo 编译，菜单及两侧 ACL 检查通过。 |

常规回归命令（主机需 SQLite/json-c 开发依赖）：

```sh
node luci/luci-app-qmodem-next/tests/test_sms_addressing.js
node luci/luci-app-qmodem-next/tests/test_sms_service.js
node luci/luci-app-qmodem-next/tests/test_sms_sim.js
make -C application/libqmodem-sms/tests
make -C application/qmodem_smsd/tests
```

安装原生 libubus、libuci、libubox、libblobmsg-json 开发依赖后，还可执行：

```sh
make -C application/qmodem_smsd/tests daemon
```

本地验证产物保存在工作树的 `.evidence/` 中，未纳入 Git；这些路径仅供本地检查：

- 回归验证记录：`logs/regression.json`。
- 交叉构建日志：`logs/libqmodem-sms-cross-build.log`、`logs/qmodem_smsd-cross-build.log`。
- 浏览器结果：`browser/result.json`；截图：`browser/database_urc-before.png`、`browser/database_urc-after.png`。

## 实机验收与交付边界

需同时安装本次 qmodem-smsd 和 luci-app-qmodem-next。尚未连接真实模块或 SIM 卡，实机验收待完成；本次提供修复分支源码，尚未发布安装包或部署。Issue 保持开放以收集实机反馈。

实机应分别在 Direct、Database Polling、Database URC 模式，以及模块支持的 SM/ME 存储区验证：原始列表对应模块实存内容；单条/全部删除后历史与转发记录保留；自动归档删除后原始区为空但历史仍可见；真实 URC 收信立即同步、主动刷新能补入漏信、停用通知后能按补扫周期恢复；缺片超时及迟到分片补齐不会重复转发。记录到达模块、同步入库、页面显示三个时间点后，再判断最新反馈的实机延迟是否消除。
