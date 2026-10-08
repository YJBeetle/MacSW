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
| [37741088903](https://github.com/YJBeetle/MacSW/actions/runs/37741088903) | 保存后的后台文档关闭返回 `0x800703e6`，非超时 | 全新安装、可见模式及 front/top/right 建模、检查、测量和保存成功；未进入尺寸或隐藏模式 |

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
在既有 `93d40e2` / `f75a56f` 证据中，请求前的 `RevisionNumber` 探测和直接
`CloseDoc` 没有独立方法边界；后述版本只补齐 `CloseDoc` 的边界。
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

性能改进首次集成时的 gitlink 与版本配置固定 SWCLI
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
断言、租约、120 秒预算、可见/隐藏顺序均不变。该改进已经通过下面列出的门禁，
但正式托管 macOS 运行尚未完成，不能宣称托管超时或独立的关闭异常已经修复。

### 改进版本的门禁结果

以下均使用 SWCLI `f75a56f05ae8246749514dbaf36d49a79b2cf495`。
每个模式内部连续执行建模 → 驱动尺寸，没有更换 daemon/SW；所有结果均为
`success=true`、`state=completed`、清理错误为零。

| 宿主 | 模式 | 原生 PID | 建模事件 | 尺寸事件 |
| --- | --- | --- | --- | --- |
| [Windows 正式 CI 37740915090](https://github.com/YJBeetle/SWCLI/actions/runs/37740915090) | 可见 | 2424 | 97 | 242 |
| 同一 Windows CI | 隐藏 | 1744 | 97 | 242 |
| 本机主 bottle | 可见 | 1332 | 85 | 242 |
| 本机主 bottle 的另一完整序列 | 隐藏 | 1972 | 85 | 242 |
| workspaceroot 独立 Linux/Wine 容器，叠加当前源码 | 隐藏 | 620 | 97 | 242 |

Windows CI 的四份共享结果及可见/隐藏 box BMP 已下载核对，两张图均显示实体。
本机重新打包 App 并显式同步 Windows backend，旧包有可恢复副本；文件仍集中在
原有独立测试目录。两个模式均以空文档列表正常停止 daemon。Linux 使用既有
`localhost/swcli-a5-probe:20261008` 基底，挂载当前源码和共享脚本；仅用于集成
回归，没有改动镜像标签或晋升镜像。正常停止 daemon 后已移除专用测试容器，
主机与本机保留生成的结果和日志。

[MacSW 正式 CI 37741088903](https://github.com/YJBeetle/MacSW/actions/runs/37741088903)
使用本仓库 `71f23a7909e71e870b06bb083b2af634d293b681` 和相同 SWCLI 指针。
构建、全新安装及官方基底快照成功，运行门禁失败，准确步骤为
`SOLIDWORKS installation & runtime` / `Shared modeling then driving dimensions on one host`。
首个失败为请求 `0d553828-551f-47ff-b946-b85ef048e0e0` 的后台模型关闭，返回
`0x800703e6`，不是 `WorkerTimeout`。建模记录共 56 个事件；另两次关闭失败属于
清理，尺寸和隐藏模式未进入。此前矩形、拉伸、切除的操作最大耗时分别约
23.107、18.648、13.419 秒；这轮已越过原来的累计慢调用失败点，但不是整个
托管流程通过的证明。该原生关闭异常在启用批次状态之前也已出现。
27 次宿主采样的 SW CPU 中位数仍为约 176.1%，Python 为 0%。
具体跨宿主证明边界见 SWCLI 的
[验证记录](https://github.com/YJBeetle/SWCLI/blob/main/docs/verification/macsw-background-rectangle-2026-10-08.md#request-scoped-implementation-validation)。

当前 gitlink 与版本配置已同步为
`fb147c19e65a4d4b2a84e8e8c140c1589171c54e`。它只为既有 `CloseDoc` 调用增加
可选、立即刷新的 begin/end/error 日志，沿用同一诊断开关，不记录文档标题或
原生参数，也不改变关闭顺序、异常结果或门禁。621 项便携测试通过，8 项仅
Windows 可执行的测试在本机跳过；新的托管运行结果尚待验证。

### 独立跟进：本机 BMP 白图

隐藏序列完成后，重开它生成的模型并执行严格 STEP 导出成功；800×600 的
等轴测 BMP 虽通过文件与尺寸检查，实际却是纯白图，不能计为渲染成功。
另一可见自有实例 PID 396 对同一只读模型按 `CommandInProgress=false → true →
false` 渲染，三张图均只有一种 RGB 颜色。随后显式调用官方
`IModelView.GraphicsRedraw` 的同类对照也均为白图。
另一个自有可见实例 PID 1880 中，用户将 SW 切到前台并确认模型区能看到实体。
同一模型、相同参数的前台渲染仍为白图，前后 BMP 的 SHA-256 完全相同；
只读测量返回 5 个实体，均有非零体积。因此单纯切前台未改善本次捕获结果，
可见场景与 BMP 捕获存在差异；下面的原生日志进一步缩小捕获失败路径，但不能从
这次对照宣称旧版本渲染正常。它与累计调用延迟、原生关闭异常
分别跟进，不通过改动几何门禁、重试建模或中途重启来掩盖。

#### 位图像素格式与离屏 drawable 对照

同一本机主 bottle 的自有可见实例 PID 2020 直接调用 `SaveBMP`，绕过 CLI 的
尺寸校验，分别请求 800×600、0×0 和 1600×1200。0×0 产生窗口大小的
2398×1181 位图，但三张图都只有一种 RGB 颜色，不能归因于固定导出尺寸。

另一个自有可见实例 PID 528 启用 Wine 内建 `wgl`、`opengl`、`bitblt` 日志。
在实际 `SaveBMP` 调用内，GDI 先填充白色位图；`ChoosePixelFormat` 随后请求
`PFD_DRAW_TO_BITMAP | PFD_SUPPORT_GDI | PFD_SUPPORT_OPENGL`（`0x38`）。
winemac 提供的 720 个格式均缺少 `PFD_DRAW_TO_BITMAP`，最终返回 0。
本次捕获没有取得位图 OpenGL 格式，尽管 `SaveBMP` 仍返回成功、文件也存在。
这是捕获失效的直接证据，不是实体缺失或窗口未切前台的证据。

一次未提交的最小试验只为支持 pbuffer 的单缓冲格式声明 bitmap/GDI 能力。
构建和静态契约检查通过，真实实例 PID 1612 的 `ChoosePixelFormat` 改为返回
109，但随后 `CGLCreatePBuffer` 返回 `10005 / invalid drawable`，BMP 仍为白图。
不依赖 SOLIDWORKS 的 8×8 DIB/WGL 最小程序也停在 `wglMakeCurrent`，64 个
预期红色像素均未产生。因此只增加能力标志不足以实现位图绘制；此试验未纳入
生产补丁，相关构建和清单改动已撤回。

进一步绕过 Wine，直接运行本机 CGL 最小程序：硬件渲染器 `Apple M2 Max` 和
`Apple Software Renderer` 都能创建上下文，但 rectangle/2D、RGB/RGBA 四组
`CGLCreatePBuffer(8, 8, ...)` 均返回同一错误。x86_64 和 arm64 程序结果一致。
该结果只证明本机 macOS 15.8 的这条旧式离屏路径不可用，不单独判定 Apple
缺陷，也不宣称所有 macOS 版本或硬件都有相同问题。

证据集中保存在既有 `C:\Workspace\MacSW-trace-20261008.6A0yEq`：
`render-native-sizes.log`、`render-native-capture-trace.log`、
`render-native-bitmap-patched.log`、`bitmap-opengl-minimal-patched.log`，以及
`bitmap-opengl-probe.c`、`cgl-pbuffer-probe.c` 和两种架构的 CGL JSONL 结果。
失败的标志试验保留为 `bitmap-format-experiment.patch`，不作为可用修复。

Windows 正式 CI 的可见和隐藏 BMP 均已核对有实体；Linux 的补充对照见下节。
后续修复必须同时验证像素内容与原有建模/尺寸序列，不能仅以
`ChoosePixelFormat` 非零或 `SaveBMP=true` 作为成功。

#### workspaceroot Linux 补充对照

同日使用现有 `localhost/swcli-a5-probe:20261008` 基底及 SWCLI
`fb147c19e65a4d4b2a84e8e8c140c1589171c54e` 源码覆盖层，启动专用 Podman 容器。
运行环境为 Wine 11.16、SW `33.5.0`、Xvfb 和 Mesa llvmpipe。
自有隐藏 PID 616 和另一自有可见 PID 1464 分别通过真实 CLI，只读打开
Mac 的同一模型副本与此前 Linux 门禁模型，并导出 800×600 等轴测 BMP。

| 模型来源 | 隐藏模式 RGB 颜色数 | 可见模式 RGB 颜色数 |
| --- | --- | --- |
| 在 Mac 上产生白图的同一个模型 | 3683 | 3700 |
| 此前 Linux 共享建模门禁 | 3650 | 3737 |

四张图均已逐张目视核对包含实体，不仅是背景渐变；四次测量均为 5 个实体，
总体积约 `308558.406140636 mm³`。Mac 模型副本 SHA-256 与本机源文件一致：
`e77c6e4c461226ffd507700824e8d4a609ea318944eab2bdfc633ebeb2d5c438`。
同一个不依赖 SW 的 8×8 DIB/WGL 程序在 Linux 也通过：位图格式选择成功，
上下文绑定成功，64 个预期红色像素全部正确。

每个模式内部未重启宿主；结束时文档列表均为空，daemon 正常停止，专用容器
随后移除。原镜像、公开标签和其他容器未改动。产物与日志保存在 workspaceroot
`/tmp/swcli-bmp.ETxLrC/output`，本机副本为 `/private/tmp/swcli-bmp-linux.En0KlH`。
因此这次白图在已测 Linux 环境没有复现，证据指向 Mac 的 winemac/CGL 图形
路径；这仍不是所有 Wine 版本、Linux 图形后端或 Mac 硬件的普遍保证。

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
