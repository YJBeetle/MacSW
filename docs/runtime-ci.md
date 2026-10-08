# MacSW 真实安装与运行 CI

`Build & Package MacSW.app` 在本仓库 `master` push 时自动执行 macOS/Wine
真实验证，手动触发时可使用 `verify_solidworks=true`。
使用 GitHub 托管的 Apple Silicon
`macos-14` runner、仓库固定版本的 Wine/Mono/SWCLI，以及打包后的 App。
`runtime_stage=install` 只执行真实安装和私有夹具准备，不等待共享建模入口；
`runtime_stage=full` 再顺序执行共享运行验证。工作流不响应 PR，且 job 层再次限制事件类型。
带私有资源的验证只允许本仓库 `master` push 或 master 的手动选择执行，fork、PR
或其他 ref 不能执行。tag 发布仍只构建和打包，不调用私有安装/运行步骤。
push 使用默认介质、夹具、简体中文和 `full` 阶段；没有手动输入也不会跳过共享门禁。

## 构建与运行分离

- `build`：单元测试（`make test`）和编译／校验／归档（`make archive`）为独立步骤。
  上传发布 App 和 Wine 源码；需要运行验证时另行编译、归档 CI helper。
  不读取 rclone 或 SOLIDWORKS 序列号 Secret，不安装 SOLIDWORKS，不注入私有夹具。
- `runtime-test`：通过 `needs: build` 等待构建成功，在另一台 runner 下载本轮的
  `MacSW-macOS-App` 和 `MacSW-CI-Helpers`，核对构建 job 输出的 SHA-256 后解包。
  不重编译、不使用其他运行的 App；helper 只注入临时 App 副本，不进入发布 zip。
  App 使用原有 zip、helper 使用 tar 传递，以保留可执行权限、符号链接及包结构。
  随后恢复官方安装基底或执行首次安装，再运行共享门禁并清理。

两个 job 分别显示状态；安装／运行失败时，构建可保持成功，但工作流整体仍失败。
构建与运行采用独立并发组；运行组仍不取消进行中的安装，避免重复读取 Drive 介质。
官方安装缓存的身份、权限校验、私有夹具注入顺序和证据脱敏边界均不因拆分而改变。
tag 的 Release 上传在构建 job 完成，不等待也不触发私有运行 job。
官方 Actions 使用 Node.js 24 版本：checkout v7、cache（含 restore/save）v6、
upload-artifact v7、download-artifact v8。上传明确保留 `archive: true`，不启用
单文件直传模式；原有产物名称、相对路径、内层 App zip/helper tar 和缓存 key 均保持不变。

## 职责与顺序

MacSW 只负责宿主准备、复用实际安装链路、路径转换、daemon 生命周期和证据收集。
CAD 测试操作与断言只由 `Dependencies/SWCLI/scripts/ci` 的共享测试维护：

1. 检查 Secrets、runner 架构、共享入口和可用磁盘。
2. 通过 rclone 下载较小的私有验证夹具，使用 `rclone nfsmount` 只读挂载 ISO
   所在目录。不引入 macOS FUSE 依赖，也不完整下载 ISO；`MacSWCore` 仍使用原有
   `IsoService`/`hdiutil` 挂载路径，安装器访问哪些镜像区段就读取哪些区段。
   NFS 使用 `ro,locallocks,intr`：镜像文件的 advisory lock 由 runner 本地处理，
   不请求 rclone 未提供的网络锁管理器。首轮没有此设置时 `hdiutil` 报
   `No locks available`；这发生在读取 ISO/运行 MSI 之前，不是 SOLIDWORKS 安装失败。
   VC++ 的 `/log` 参数经当前容器的 `winepath -w` 转换为 Windows 路径，不直接传
   macOS 路径，也不假定 Z: 存在。退出码 86 可能是 1622（无法打开安装日志）的
   低 8 位，但不能只凭截断码确认原因或将其忽略。
3. 在 `$RUNNER_TEMP/MacSW-runtime/app-support/bottle` 创建全新测试容器。
   CI 专用 `MacSWCI` 入口调用 `BootstrapStore`，复用介质、Wine/Mono/COM、VC++、
   Login Manager、核心 MSI、语言、主题和安装结果校验。这里先选“不配置许可”，
   在隔离 Wine 停止后制作官方已安装基底快照（保留获准公开的假 SN）；托管 FlexNet 在下一阶段仍调用
   `LicenseServerStore.configureDuringInstallation` 的实际安装路径。
4. 官方安装结束后，在此临时容器应用与 DockerSW 相同布局的私有验证资源。
   对所有程序覆盖文件逐字节校验，只记录校验数量和总大小；复制命令成功本身不算覆盖证明。
   此操作只是为了 CI 无法访问开发者局域网许可服务器时验证可行性，
   不是 MacSW 产品功能，也不证明正版许可服务器联通性。
5. 执行 App 的 `RuntimeStore.startup(autoLaunch: false)` 字体准备路径，
   在隔离活动容器中通过 MacSW 的 `SolidWorksResourceMonitorService` 禁用
   `sldProcMon.exe`（可逆重命名，与 DockerSW 相同），记录 VC++ 模块大小、哈希和
   Wine builtin/placeholder 标记，并将 Mono 的宿主路径按实际映射重新绑定，再
   启动打包 `sw-cli daemon serve`，等待健康检查确认 COM 主机就绪。
6. 可见模式中顺序运行 `verify-modeling.py` 和 `verify-driving-dimensions.py`，
   每个入口前后核对同一个 daemon/SOLIDWORKS COM 主机的 PID、模式和元数据。
   中途不能重启 daemon 或 SOLIDWORKS；通用建模失败就保留失败，不继续尺寸测试。
7. 完成这两个入口后才停止第一套进程，再在隐藏模式重复上述顺序。
8. 无论成功或失败，都停止隔离 Wine server、弹出本次 ISO、卸载 rclone NFS，
   删除本地 VFS 稀疏缓存、验证资源、临时 App
   和整个测试容器。只上传通过最终脱敏检查的测试 JSON、daemon 日志及白名单安装日志。
   测试生成的 SLDPRT 会被共享测试检查，但不上传二进制模型，以收紧敏感数据边界。

启动可见 SOLIDWORKS 之前，运行 MacSW 专属的 `check_bitmap_opengl.exe` 原生
位图探针。它不依赖 SW 或私有夹具，检查 24/32 位、宽度 7/8、上下行方向的
八组 DIB/WGL 实际像素、深度模板和上下文切换；缺失、非零退出或任一结果不符
都会使运行门禁失败。八组结果写入 `runtime.json` 的 `bitmap_driver`。
探针从仓库 C 源码构建，随原有 helper tar 传递，仅注入临时 CI App，不进入
发布 App zip。它验证 MacSW 图形驱动，不复制 SWCLI 的 CAD 操作或几何断言；
通过原生探针也不能代替后续共享建模/尺寸门禁。

宿主命令通过私有匿名临时文件接收 stdout/stderr，单独等待直接子进程退出，
不等待 Wine 后台进程关闭继承的日志管道。每条命令记录 `unix_pid`、真实
`exit_code`、耗时和退出时的有限日志快照；真正超时仍失败，并记录
`running_at_timeout`，终止、回收本条命令。日志只按原有 `runtime.json` 脱敏
流程上传，不上传原始临时文件。位图的 60 秒期限、退出码 0 和八组完整断言
均不变，也不为读取日志重启 Wine、daemon 或 SW。

位图探针前还执行 `check_cgl_arm64` / `check_cgl_x86_64`，将原生与 Rosetta
CGL renderer 清单和四种 legacy 上下文请求写入 `runtime.json.cgl_renderers`：
Wine 原有主显示器加速请求、任意加速 renderer、自动选择和指定软件 renderer。
它们仅作只读观察，不启动 Wine/SW，也不切换产品的绘图后端；某种模式不可用
会保留原始 CGL 错误，不能据此跳过或通过位图、建模和尺寸门禁。两个程序同样
只进入 CI helper，不进入发布 App。

`0009-winemac-software-renderer-fallback.patch` 的独立候选保留硬件优先，只在
legacy 加速格式不存在时尝试 Apple 软件 renderer，不将 core 请求降为 legacy，
也不更改 SW 的“软件 OpenGL”选项。位图探针额外核对真实 renderer、GL 版本及
WGL 加速属性；软件格式必须报告 `PFD_GENERIC_FORMAT` / `WGL_NO_ACCELERATION_ARB`。
这不会跳过八组像素门禁，后续共享建模→尺寸仍须在同一宿主顺序通过。
候选状态、已知风险及验收边界见[软件 renderer 待办](software-renderer-compatibility.md)。

共享入口参数约定：`--output-dir`（本机输出目录）、`--host-output-dir`
（同一物理目录的 Wine 可见路径）、`--cli-command`（打包后的 CLI）、`--endpoint`。
输出目录在容器 `drive_c` 内；本机与 Wine 必须看到同一批模型与 JSON，不能只给
两侧分别建立独立目录。每次共享入口结束或失败后，再将白名单文件复制到上传证据目录。
SWCLI 固定提交为 `fb147c19e65a4d4b2a84e8e8c140c1589171c54e`（`0.1.0a6.dev0`），沿用 DockerSW 的共享
门禁调用顺序。两个共享门禁使用明确的十分钟租约，并在写操作、预期拒绝断言及关闭前
续租；尺寸门禁的协议和 CLI 写操作均覆盖。此修改针对慢调用导致租约过期的测试问题，
不改变 daemon 默认期限、原生断言或命令超时，也不重试过期/失败操作。
尺寸入口额外传入 `--after-modeling` 指向同一模式的成功 `modeling.json`，
由 SWCLI 核对前序成功、拒绝切除后的续用证明及原生宿主 PID。外层宿主检查仍保留。
共享入口缺失时，runtime 预检明确失败，**不静默跳过**。

当前 MacSW 接线不自行复制 Windows/DockerSW 的启动矩阵、外部实例附着或几何断言。
这些测试若需要纳入跨平台运行，也应由 SWCLI 提供共享入口，再在此调用。
本次 CI 的 `Visible` 校验来自 COM 元数据，不等于人工验证窗口焦点、字体像素、IME、
Metal/OpenGL 图层或鼠标交互。

## 原生调用分段诊断

[run 37727420806](https://github.com/YJBeetle/MacSW/actions/runs/37727420806)
在 MacSW `ac3dd87`、SWCLI `86c52f2` 上完成安装和可见模式启动（SW PID 488、
版本 33.5.0），但共享建模的第一次实际后台 front 矩形操作超过 120 秒。
之前的无租约及错误 stamp 请求均为预期拒绝，尚未执行实际切除；不能将本次
失败归因于拒绝切除后的残留状态。后续清理的注册错误也不代表首次启动失败。
原日志没有方法开始／结束记录，暂不能确定阻塞在切换前台、平面选择、进入草图、
创建矩形、退出或几何观察的哪一步。

隔离运行适配器现在向 daemon 继承 `SWCLI_TRACE_NATIVE_CALLS=1`，将 SWCLI
原生调用边界与 Wine 诊断一起写入 `visible-daemon.log`／`hidden-daemon.log`。
每个开始事件先落盘并刷新再调用 COM，即使 worker 被超时终止也保留已写记录。
按 `(worker_pid, request_id, sequence)` 配对 `swcli.native-call` 的
`begin`、`end`、`error`；最后未配对的内层 begin 指出进入过哪个已覆盖调用，
不是死锁或供应商根因的结论。`end` 只表示返回，不代替业务成功和几何断言。
日志记录调用名、阶段、关联标识和耗时，不记录原生参数、结果或异常原文。

此开关仅在隔离 CI 中启用，日常产品默认关闭。共享建模 → 尺寸顺序、单宿主
身份校验、120 秒操作超时、租约和几何断言均保持原样，不通过重试、增加超时
或中途重启消除失败。此次版本与诊断接线仍需新的真实运行验证，不宣称超时已修复。
SWCLI 的对应记录见 `Dependencies/SWCLI/docs/verification/macsw-background-rectangle-2026-10-08.md`。

当前 backend 对 daemon-owned 宿主的每个业务请求使用官方 `CommandInProgress`
作用域，结束时恢复并验证原值，以减少连续进程外调用的中间更新开销。它不是
CI 开关，也不改变断言、超时、租约、可见/隐藏矩阵或失败后的行为；共享交互
实例不启用。恢复失败会终止自有宿主并要求显式重启，不在未知状态中续跑。
本机同实例只读对照支持这一方向；`37741088903` 已完成三平面建模并保存模型，
随后关闭后台文档返回原生 `0x800703e6`，未进入尺寸或隐藏模式。当前版本补上
`SldWorks.CloseDoc` 的立即刷新调用边界，仍需新的完整共享 CI 验证，不能预记成功。
其他已完成运行的不同失败点、本机交叉验证及当前调查边界汇总在
[原生建模 CI 调查](native-modeling-investigation.md)。

共享门禁期间另有每 15 秒一次的只读宿主指标，写入
`visible-host-metrics.log` / `hidden-host-metrics.log`：已知 Wine 进程的 macOS
PID、CPU、累计 CPU 时间、RSS、状态，以及系统负载、空闲磁盘和时间。
不保存命令行、参数、环境或 `ps` stderr，不访问 COM，不控制进程；诊断采集失败
不影响共享门禁的原始结果。RSS 不是 Rosetta 进程的物理 footprint 证明。
日志走相同的最终脱敏屏障，不进入 App 或官方安装缓存身份。

针对托管 `CloseDoc / 0x800703e6`，运行适配器另启用 Wine 内建 `wgl` 日志，
记录驱动的 renderer、像素格式、上下文创建/绑定/释放，与请求级关闭边界配对。
不启用逐 GL 调用的 `opengl` trace，不安装/注入调试器，不改变 API 参数或关闭
顺序。驱动的物理上下文不等同于应用的逻辑 HGLRC，不能单凭非零驱动指针认定
`wglGetCurrentContext` 返回了非零值。日志仍走最终脱敏屏障；增加日志可能影响
时序，因此仅作诊断，不以带日志的通过或失败单独确定根因。

## 隔离与路径

CI 入口只允许在 GitHub Actions 中运行，路径固定在 runner 的临时目录。
拒绝复用已有测试容器，不调用 `AppPaths.live()`，不使用日常主容器。
缓存命中时，先校验清洁快照，再复制到新隔离目录，绝不在缓存本体上运行。
`MacSWCI` 和 `MacSWCIRuntime` 只放进 CI 私有 App 副本，不进入发布 zip。
后者只做运行前宿主准备和诊断，不执行安装、不改动官方基底，也不进入安装缓存身份；
仅修改这些运行步骤时仍可恢复与当前安装源码及 Wine 模块一致的官方快照。
缓存清除非 C: 盘映射后，安装期 Mono `RuntimePath` 不能沿用旧的 Z: 宿主路径；
运行准备经 `winepath -w` 使用当前实际映射重新写入，路径也进入宿主准备证据。

模型和临时 CLI 输出置于测试容器的 `drive_c` 内；给临时 App 配置独立 `M:` 映射。
所有 Mac 路径经 App 的 `swcli-path` 按实际 `dosdevices` 转换；不拼接或假定 `Z:`。
CLI 生命周期中的辅助 EXE、当前目录及临时输出也使用同一真实映射解析器。

## 私密数据与产物

需要 `RCLONE_CONFIG_B64` 与 `SW_SERIAL_SOLIDWORKS` 两个仓库 Secret。
rclone 配置以 0600 临时文件保存，下载脚本退出或安装挂载结束时删除。
NFS 仅绑定 runner 的 loopback，不对外提供服务，远端介质只读。
序列号只传给安装入口，rclone 进程不继承它；
后续 daemon 和测试进程不继承这两个 Secret。

CI 序列号为私有验证夹具使用的测试值；经授权可以上传官方 VC++/MSI 安装诊断日志，
但仍通过脱敏屏障。只收集 Wine 初始化、VC++、Login Manager、核心 MSI 和语言安装
日志，UTF-16 转为 UTF-8，每个文件最多 16 MiB；不收集 rclone 或许可服务器日志。
**不上传完整容器、注册表 hive、rclone 配置、许可文件、私有夹具或补丁后的任何二进制**。
上传前清除 rclone 凭据与 token；本仓库已确认的假 SOLIDWORKS SN 经授权保留在安装
诊断日志中，不再做 SN 脱敏。其他产品的序列号属性仍隐藏。此隐私检查失败时禁止上传。
发布 App 在应用私有夹具前独立归档、上传，绝不能用测试容器内容重新打包。
失败时保留阶段、命令退出状态及部分 JSON 证据，不以日志上传成功代替运行验证成功。
`prerequisite-diagnostics.json` 仅记录 VC++ 日志是否生成、大小及固定格式的错误/结果码，
不保存日志原文、文件名、命令行、注册表值或安装属性。
`installer-logs/*.log` 保留安装步骤、错误、路径、堆栈及获准公开的假 SOLIDWORKS SN；
上传前屏蔽 rclone 配置的 base64 原文、解码配置中的长凭据/token 值及其他产品的序列号属性。
工作流的清理步骤覆盖通常的失败/取消；runner 被强制终止时由托管 VM 的销毁收尾。

本机现有容器实测约 8.3 GiB，其中 SOLIDWORKS 目录约 7.2 GiB（仅用于容量估算，
不是 CI 峰值）。首轮 runner 提供约 39 GiB 空闲空间，旧的 45 GiB 预检门槛误挡安装，
现改为挂载方案下的 24 GiB。VFS `full` 使用稀疏文件，只缓存已读取区段，目标缓存
大小 8 GiB、最低剩余空间 4 GiB；这些是软目标，打开的 ISO 不能被逐出，不能当作硬上限。
`media.json` 记录安装期间最低空闲空间及 VFS 实际磁盘分配量，供后续调优。
安装完就解除挂载，不删除或修改 Google Drive 上的 ISO。

## 完整官方安装基底缓存

缓存整个官方已安装 Wine bottle，但必须在私有补丁/许可夹具注入前生成：

- 只复制 bottle，不包含宿主安装日志、ISO、rclone 配置、私有资源或托管 FlexNet。
- 删除容器内日志、dump、临时目录及非 C: 的本次运行映射；保留官方安装程序、
  Mono/COM/VC++、语言资源与注册表。假 SOLIDWORKS SN 经授权保留，不改写文本、
  十六进制 hive 或二进制安装状态，也不因出现此假 SN 拒绝缓存。
- 存在许可文件、rclone 配置或私有 FlexNet 时仍拒绝发布；必须在补丁夹具注入之前制作。
- 缓存格式为 v2，key 包含 macOS/架构、介质路径、语言、版本配置、安装源码与假 SN 的指纹；恢复时逐文件核对
  SHA-256、文件权限、符号链接和 manifest，校验失败不启动容器，也不把坏缓存当作成功安装。
  Wine 构建脚本和公开 Wine 补丁也进入缓存 key，避免恢复由旧模块初始化的基底。
- `cache.json` 区分 `fresh-install` 与 `installed-base-cache`。缓存命中不是本次全新安装
  证明；`force_fresh_install=true` 忽略缓存并重新挂载介质完成整个安装链。
- 每次运行都重新下载、注入临时验证资源；不缓存补丁后的容器，不公开这些二进制。

恢复通过独立 `restore-base.py` 调用原有严格校验与复制逻辑，诊断修改不使安装缓存失效。
失败时仍停止运行，仅增加 `cache-restore-failure.json`：阶段、错误类别、磁盘余量、
OS errno，以及缺失/新增/变更数量和变更字段。样例路径仅保存 SHA-256，模式只保存数字；
不输出原始复制异常、注册表、链接目标或文件内容，也不将校验失败降为缓存未命中。
官方基底的 Actions 恢复步骤单独设置 `TAR_OPTIONS=--same-permissions`，让 GNU tar
保留归档权限，避免 runner 的 umask 改写它们；不修改 manifest，也不忽略权限差异。
参见 [GNU tar 权限恢复说明](https://www.gnu.org/software/tar/manual/html_node/Setting-Access-Permissions.html)。

禁用 PR 触发不能保证缓存只有维护者可读，不能缓存含有敏感内容的测试容器。
缓存的隔离副本和活动测试容器结束后都删除；只有通过隐私检查的官方基底留在 Actions cache。
参考 SWCLI Windows CI 的官方安装/私有夹具分层及缓存导出、恢复脚本。最新 Windows
工作流暂禁用安装快照，等待新 runner 的原生 COM/方程等价性验证；MacSW 按要求保留
整瓶缓存，但全新安装与缓存恢复必须分别验证，不能由快照完整性检查替代原生运行证明。

## 触发与验证边界

本仓库 master 的相关源码/配置/工作流 push 自动执行完整验证；不相关文档改动不触发。
在 Actions 中选择该工作流，勾选 `verify_solidworks`，确认 Drive 介质与夹具路径。
CLI 等效调用：

```bash
gh workflow run build-app.yml --repo YJBeetle/MacSW --ref master \
  -f verify_solidworks=true -f runtime_stage=install -f language=chinese-simplified
```

将 `runtime_stage` 改为 `full` 执行共享建模与尺寸完整验证。
首次安装或排查安装回归时可追加 `-f force_fresh_install=true`。

首轮 [run 37694344157](https://github.com/YJBeetle/MacSW/actions/runs/37694344157)
的真实安装、官方基底保存和夹具准备已经通过，VC++ 使用实际 Windows 日志路径后
不再出现退出码 86。该轮共享运行失败，且使用的是先前的 SWCLI 固定版本；
最新版本与 v2 缓存恢复仍需要各自的实际验证。
该轮 daemon 激活以 `REGDB_E_CLASSNOTREG` 失败，未进入共享建模；安装结束时的注册
校验通过不代表之后能完成 COM 激活。后续 CI 在夹具及启动准备后收集 64 位 ProgID/CLSID
查询，并在 daemon 日志保留 Wine OLE 错误/警告、异常、模块加载及时间戳，避免仅凭 HRESULT 猜原因。

[run 37697068522](https://github.com/YJBeetle/MacSW/actions/runs/37697068522)
再次完成真实安装、v2 官方基底保存和夹具准备，但首次 COM 激活失败，未进入建模。
64 位 ProgID/CLSID 校验成功；模块加载证据显示 `SLDWORKS.exe` 已启动，激活调用
约 30 秒后失败时它仍在初始化，没有证据支持“注册表丢失”或“程序已崩溃”的归因。
本轮移植 DockerSW 的公开 Wine `0007-combase-wait-solidworks-registration.patch`，
从同版 Wine 11.16 源码构建 x64 `combase.dll`，包内清单校验补丁和模块 SHA-256。
补丁仅针对 SOLIDWORKS CLSID：默认等待 300 秒，可经 `WINE_SOLIDWORKS_STARTUP_TIMEOUT`
设置 1–3600 秒（小数向上取整），无效值退回原有 30 秒；其他 CLSID 不变。
CI 明确设置 150 秒，低于 daemon 的 180 秒启动预算及宿主的 210 秒外层期限。
这是同一次激活内等待类工厂，不是重新启动、附着既有实例或重试 CAD 原生操作。
同时移除海量 OLE trace，保留错误/警告和其他诊断，降低诊断自身对启动耗时的影响。
延长等待能否解决实际启动、夹具校验及新基底恢复是否通过，仍需后续云端证据；
不能将这个 HRESULT 的所有原因一概视为超时。

[run 37700624906](https://github.com/YJBeetle/MacSW/actions/runs/37700624906)
通过新增 Wine 模块的编译/打包校验、全新安装、新基底保存和全部 5 个程序夹具文件的
逐字节校验（25,598,208 字节）。daemon 在约 64 秒后获得自有 COM 主机 PID 472，
证明首次激活已超过原有 30 秒上限并成功；但未到就绪阶段，最终报 `WorkerStartupTimeout`，
没有进入共享建模。日志中空地址崩溃属于 `sldProcMon.exe`，不能当作 SOLIDWORKS 主进程
崩溃或断言它就是就绪阻塞的原因。下一轮在隔离容器复用已有禁用监视器设置，并补充
VC++ 文件诊断；不禁用 CAD 功能、不重试实例、也不更改 `StartupProcessCompleted` 就绪要求。
`runtime.json` 的 `host_acquisitions` 仅证明获得 COM 实例，`hosts` 才记录通过就绪检查的宿主。

[run 37704206894](https://github.com/YJBeetle/MacSW/actions/runs/37704206894)
通过新增运行准备入口的测试、编译和签名，并命中同一官方基底缓存；但随后校验/复制
失败，夹具和 daemon 都未执行。这轮原有错误屏障没有提供具体原因，因此尚不能归因于
缓存损坏、文件权限或磁盘空间。下一轮保留相同快照和校验，增加失败诊断后再判断。
[run 37705488521](https://github.com/YJBeetle/MacSW/actions/runs/37705488521)
收集到缓存恢复失败的具体证据：25,032 个条目没有缺失、新增、内容哈希或链接变更，
仅 648 个文件的权限不同，样例由 `0666` 变为 `0644`；未创建活动容器，仍有
27,296,321,536 字节空闲。GNU tar 的非 root 默认解包会应用 umask，与该变化吻合。
修正仅限解包时保留归档权限，复用相同缓存；实际恢复与启动是否通过仍待云端验证。

[run 37706684327](https://github.com/YJBeetle/MacSW/actions/runs/37706684327)
通过云端测试/构建、同一 v2 基底的完整校验及隔离复制、全部程序夹具校验和运行准备。
可见模式获得并通过就绪检查的自有宿主 PID 为 488，版本 `33.5.0`，简体中文，
`shared_interactive=false`；没有附着外部实例。Mono 绑定到实际 M: 路径，监视器状态为
`disabled`。宿主准备前后 VC++ 文件没有变化，但 `msvcp140`、`msvcp140_2`、
`vcruntime140_1` 仍带 Wine builtin 标记；不能仅凭这一现象将后续超时归因于 VC++。

共享建模在同一实例中通过文档创建、租约/版本冲突拒绝、front 矩形、拉伸及原生测量、
圆草图观察、切除和重复使用已吸收草图的 `SketchUnavailable` 预期拒绝。
紧接着的 top 矩形创建超过 120,000 ms，返回 `WorkerTimeout`，SWCLI 终止 worker 和
自有宿主。该原生调用具体阻塞在哪个 COM 方法，目前证据不足，不能宣称是状态污染
或宿主库导致。失败后的共享清理又收到 `WorkerStartupError`，这是后续清理错误，
不能取代首个超时；没有通过重启继续测试。尺寸入口和隐藏模式没有执行，完整运行仍失败。
隔离资源清理和脱敏证据上传均成功。

后续需要 SWCLI 原生操作阶段/调用级超时证据以定位阻塞；不修改共享断言、不调大
操作超时或重跑同一原生失败制造通过。当时因授权边界暂停了上游调查，现已按维护者
授权继续统一排查，见上面的诊断版本与调查记录。缓存恢复和可见启动已获得实际证据，但最新宿主准备
下的全新安装运行、连续建模/尺寸以及隐藏模式仍未完成证明。

现按维护者要求从 `64e97eb` 同步到上游 main 的 `86c52f2`，包括 `e8f78a5` 的协议
续租上下文修复，以及 `e164b50` 在原生 `FeatureCut4` 失败时用 `SetPickMode` 结束
未完成命令的清理修复。后者不重试切除，也保留原始失败。MacSW 上述失败序列中的
重复切除被 `SketchUnavailable` 前置拒绝，尚未调用 `FeatureCut4`，因此不能仅凭
更新就宣称该超时已解决。上游 Windows/隐藏 Wine 的成功也不等于 MacSW 通过。
该次同步由 master push 的现有 CI 验证。由于版本配置进入安装缓存身份，
此更新会使用新 key 并走全新安装链，不额外发起重复运行。
工作流接线与离线测试不能证明实际安装、COM 激活或连续建模已通过。
