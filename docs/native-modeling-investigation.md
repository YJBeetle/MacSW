# 原生建模 CI 调查

## 当前结论

MacSW 的构建、真实安装与 COM 就绪已经有成功证据，但托管 macOS 上的连续建模
尚未稳定通过。当前没有足够证据把故障归因于某个 Wine 模块、隐藏窗口或矩形算法。
调查保持原有共享门禁和 120 秒操作超时，不重试失败操作，不中途重启后续跑。

MacSW 负责安装、Wine、App 打包、驱动映射、宿主准备和证据收集；建模操作与
断言仍只维护在 SWCLI。Windows、DockerSW 的成功不能替代本仓库 macOS 的证明。

## 已完成运行的证据

| 运行 | 首个业务失败 | 已证明的边界 |
| --- | --- | --- |
| [37706684327](https://github.com/YJBeetle/MacSW/actions/runs/37706684327) | front 建模和切除后，top 矩形超过 120 秒 | 缓存恢复、可见模式就绪及此前操作成功；未进入尺寸或隐藏模式 |
| [37727420806](https://github.com/YJBeetle/MacSW/actions/runs/37727420806) | 第一次实际后台 front 矩形超过 120 秒 | 全新安装、可见模式就绪、无租约及错误 stamp 的前置拒绝成功；此前没有实际切除 |
| [37730038675](https://github.com/YJBeetle/MacSW/actions/runs/37730038675) | 保存后的后台文档 `document.close` 返回 `0x800703e6` | 缓存恢复、front/top/right 草图、拉伸、圆、切除和保存成功；未进入尺寸或隐藏模式 |
| [37732440131](https://github.com/YJBeetle/MacSW/actions/runs/37732440131) | 首次拉伸在重建后的特征诊断遍历期间超过 120 秒 | 全新安装、可见模式就绪、首次矩形成功；未进入尺寸或隐藏模式 |
| [37736636613](https://github.com/YJBeetle/MacSW/actions/runs/37736636613) | 首次切除在重建后的特征诊断遍历期间超过 120 秒 | 缓存恢复、可见模式就绪、矩形、拉伸、测量、圆及草图检查成功；未进入尺寸或隐藏模式 |

`37727420806` 和 `37730038675` 都固定 SWCLI `86c52f27c0b2bdcfe0bf990debfc840481608d58`，
获得就绪的自有 SOLIDWORKS PID 488、版本 `33.5.0`、简体中文、可见模式。
失败点不同，因此“始终在第一次矩形”“只发生在切除后”“只因隐藏”均不成立。

`37730038675` 的 Wine 异常日志包含服务器端捕获的空地址访问异常，随后 COM
返回 `0x800703e6`。这证明该调用出现原生异常，不证明整个 SOLIDWORKS 进程已
崩溃，也不足以区分 SOLIDWORKS 缺陷、Wine 兼容性或其他宿主因素。日志中的
`slduiu.dll` 帧不能单独确定最初错误来源。

`ISupportErrorInfo` 封送警告在成功调用中也出现，不能单独作为失败原因。
超时后清理触发的 `WorkerStartupError` / `REGDB_E_CLASSNOTREG` 是后续错误，
不能取代首个超时，也不能倒推首次 COM 激活失败。

## 诊断基线

MacSW `498e3883b4a53a6c673e1e21d171a244282a9ea1` 同步 gitlink 与
`config/versions.env`，固定 SWCLI
`93d40e274be9d3714ccab00905fc36a6675fc195`（`0.1.0a6.dev0`）。
[37732440131](https://github.com/YJBeetle/MacSW/actions/runs/37732440131)
使用这一版本全新安装。构建、安装及可见模式就绪成功，但共享建模失败，
准确失败步骤为 `SOLIDWORKS installation & runtime` /
`Shared modeling then driving dimensions on one host`。

首个矩形操作成功，用时 113.723 秒；`CreateCenterRectangle` 已返回，用时
14.399 秒，几何校验 31.206 秒。随后首次拉伸已经返回原生特征，并进入
`EditRebuild3` 之后的特征错误诊断。截止超时前，同一请求有 90 个已完成的
原生边界记录，累计覆盖约 80.572 秒；其余时间包含未单独记录的方法。
最后未配对的是 `GetNextFeature`，它在总预算只剩约 1.4 秒时开始，之前同名
调用多次用时约 0.6–1.8 秒。不能仅凭这条未配对记录认定该方法死锁；
本轮证据更支持大量慢调用累计用尽预算，而非单一矩形创建方法长期不返回。
它还不能确定宿主变慢的原因，也不能解释上一轮独立的关闭异常。

CI 设置 `SWCLI_TRACE_NATIVE_CALLS=1`，在普通 daemon 日志里记录立即刷新的
调用开始、结束与耗时。它不修改原生参数、几何断言、租约或恢复策略。
按 `(worker_pid, request_id, sequence)` 配对事件；`end` 只表示调用返回，不表示
业务成功。只对已经覆盖的调用边界作判断，不能把日志空白解释为任意原生方法阻塞。
特别是请求前的 `RevisionNumber` 探测和直接 `CloseDoc` 当前没有独立方法边界。
详见 [运行适配器与诊断约定](runtime-ci.md#原生调用分段诊断)。

`37736636613` 使用 MacSW `0bf251e94ce2420446ec3f6376e584bbb32968f7`，
SWCLI 固定版本未变。构建和官方基底缓存恢复成功，可见模式自有 PID 488 就绪。
矩形、拉伸、圆及草图检查分别用时约 55.971、48.371、103.160、111.440 秒。
第一次切除返回原生特征并进入重建后的诊断遍历；超时前 87 个已完成调用边界
累计约 77.901 秒，最后 `GetNextFeature` 开始时只剩约 1.8 秒。这再次支持
累计慢调用消耗预算，不证明最后一个方法死锁，也不解释前述关闭异常。

该轮在共享门禁期间每 15 秒从 macOS `/bin/ps` 采集已知 Wine 进程的 CPU、
累计 CPU 时间、RSS 和状态，同时记录系统负载及空闲磁盘。输出只含数字、固定
进程名及受限状态字段，不包含原始命令行、参数、环境、模型数据或工具 stderr。
诊断失败只记录错误类别，不代替 CAD 结果；记录进入既有 `.log` 脱敏屏障。
RSS 是宿主 `ps` 的观测值，尤其在 Rosetta 下不等同于真实物理 footprint。
每个门禁有独立的经过时间；不得直接比较它与 Windows worker 的 monotonic 时钟。

37 次采样中，SOLIDWORKS CPU 使用率中位数约 177.1%，Python 两个进程的
采样中位数为 0%；1 分钟负载范围约 5.0–18.2，可用磁盘始终超过 21 GB。
这说明主要 CPU 活动在 SOLIDWORKS/Wine 宿主，而非 Python 的协议处理；
不能单凭百分比确定是哪条线程、渲染、Rosetta 或 Wine 模块导致慢调用。

## 当前改进版本：请求级原生 API 批次状态

MacSW 的 gitlink 与版本配置现固定 SWCLI
`f75a56f05ae8246749514dbaf36d49a79b2cf495`（`0.1.0a6.dev0`）。
本机另一独占可见实例 PID 1004 对同一后台文档完成只读对照：
`CommandInProgress=false → true → false` 时，相同 18 个特征的诊断遍历分别
用时 4.308、0.086、4.280 秒。原值已恢复，测试实例正常退出。
首次对照启动时本机许可服务未运行，尚未进入对照即失败；恢复后从新实例执行，
这个启动失败不计入建模或耗时结论。

按 SOLIDWORKS [官方说明](https://help.solidworks.com/2024/english/api/sldworksapi/SolidWorks.Interop.sldworks~SolidWorks.Interop.sldworks.ISldWorks~CommandInProgress.html?format=P&value=)，
该标志用于减少连续进程外 API 调用期间的中间更新。SWCLI 当前将它限定于
daemon-owned 宿主的单个请求，结束后恢复并验证原值；共享交互实例不改变。
恢复失败会中止 worker、清理精确的自有 SW PID 并要求显式重启，不续用未知状态。
断言、租约、120 秒预算、可见/隐藏顺序均不变。这是待完整门禁验证的性能改进，
尚不能宣称托管超时或独立的关闭异常已经修复。

## 本机交叉验证

2026-10-08 使用重新打包的 `build/app/MacSW.app` 和日常主 bottle，保留旧
Windows backend 后，仅同步 SWCLI Python 包。测试文件集中在一个独立的
`C:\Workspace\MacSW-trace-20261008.6A0yEq` 目录，没有修改安装样例或用户模型。
以自有可见模式启动，SW PID 376、版本 `33.5.0`，启用同一调用诊断。

共享 `verify-modeling.py` 已完成：`success=true`、85 个事件、清理错误为零，
包含 `native-model`、`reverse-cut`、`rejected-cut-then-sketch` 三个用例。
后台操作、保存关闭重开、预期原生失败后的继续建模均在同一宿主上通过。
第一次 `CreateCenterRectangle` 用时约 1.2 秒。MacSW 适配器没有传入可选的安装
Part/Assembly 样例，因此 85 个事件不等同于 Windows/DockerSW 含样例导出的
97 个事件。随后 `verify-driving-dimensions.py` 也在同一 PID 376 上完成，
`success=true`、242 个事件、清理错误为零，front/top/right 的驱动直径、
修改后的实体指标、保存重开及引用重新发现均通过。

可见序列完整完成并正常停止 daemon 后，独立启动隐藏模式自有 PID 1116。
同一 PID 内建模和尺寸门禁也分别完成 85、242 个事件，`success=true`、清理错误
均为零。两组序列内部都没有重启；正常停止前，文档列表均为空。
隐藏序列的矩形、拉伸、驱动尺寸修改最大操作耗时分别约 2.635、1.693、0.935 秒。
这是本机这一轮的时序观测，不是可见/隐藏的严格因果对照：启动配置同时涉及
`UserControl` 和 `UserControlBackground`，实例和预热顺序也不同。

本机 macOS 为 15.8，本轮构建 runner 为 14.8.9，均为 arm64。
本机与 `37730038675` 的 `msvcp140`、`msvcp140_2`、`vcruntime140_1`
文件 SHA-256 完全相同且含 Wine builtin 标记，不能仅凭这些标记解释两端差异。

此结果仅证明本机现有主容器在该次可见与隐藏序列中通过，不是托管 runner、
全新安装、缓存恢复或 GUI 交互的替代证明，也不是故障已经修复的结论。

## 后续收口

1. 取得诊断 CI 的首个失败及最后已覆盖调用；若失败发生在未覆盖边界，只增加
   相应方法的开始/结束记录，不先改变调用顺序或超时。
2. 本机共享建模 → 尺寸的可见与隐藏序列均已完成；继续对照托管宿主慢调用，
   每个正式门禁序列内仍不得更换 daemon/SOLIDWORKS。
3. 只有具体调用和宿主证据支持时才修改 Wine/MacSW 或 SWCLI；修复后重新执行
   未削弱的共享门禁，并分别记录本机、全新安装和缓存恢复的结果。
4. App 更新时既有 bottle 的 Windows backend 同步仍需单独核查；本次为可恢复
   的显式测试升级，不把这个部署问题与托管 CI 的原生异常混为一项。
