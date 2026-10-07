# MacSW 真实安装与运行 CI

`Build & Package MacSW.app` 在本仓库 `master` push 时自动执行 macOS/Wine
真实验证，手动触发时可使用 `verify_solidworks=true`。测试、构建和打包仍先执行。
使用 GitHub 托管的 Apple Silicon
`macos-14` runner、仓库固定版本的 Wine/Mono/SWCLI，以及打包后的 App。
`runtime_stage=install` 只执行真实安装和私有夹具准备，不等待共享建模入口；
`runtime_stage=full` 再顺序执行共享运行验证。工作流不响应 PR，且 job 层再次限制事件类型。
带私有资源的验证只允许本仓库 `master` push 或 master 的手动选择执行，fork、PR
或其他 ref 不能执行。tag 发布仍只构建和打包，不调用私有安装/运行步骤。
push 使用默认介质、夹具、简体中文和 `full` 阶段；没有手动输入也不会跳过共享门禁。

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
   此操作只是为了 CI 无法访问开发者局域网许可服务器时验证可行性，
   不是 MacSW 产品功能，也不证明正版许可服务器联通性。
5. 执行 App 的 `RuntimeStore.startup(autoLaunch: false)` 字体准备路径，
   启动打包 `sw-cli daemon serve`，等待健康检查确认 COM 主机就绪。
6. 可见模式中顺序运行 `verify-modeling.py` 和 `verify-driving-dimensions.py`，
   每个入口前后核对同一个 daemon/SOLIDWORKS COM 主机的 PID、模式和元数据。
   中途不能重启 daemon 或 SOLIDWORKS；通用建模失败就保留失败，不继续尺寸测试。
7. 完成这两个入口后才停止第一套进程，再在隐藏模式重复上述顺序。
8. 无论成功或失败，都停止隔离 Wine server、弹出本次 ISO、卸载 rclone NFS，
   删除本地 VFS 稀疏缓存、验证资源、临时 App
   和整个测试容器。只上传通过最终脱敏检查的测试 JSON、daemon 日志及白名单安装日志。
   测试生成的 SLDPRT 会被共享测试检查，但不上传二进制模型，以收紧敏感数据边界。

共享入口参数约定：`--output-dir`（本机输出目录）、`--host-output-dir`
（同一物理目录的 Wine 可见路径）、`--cli-command`（打包后的 CLI）、`--endpoint`。
输出目录在容器 `drive_c` 内；本机与 Wine 必须看到同一批模型与 JSON，不能只给
两侧分别建立独立目录。每次共享入口结束或失败后，再将白名单文件复制到上传证据目录。
SWCLI 固定提交为 `64e97eb07dcb250d783114d176e108961ba76e27`，沿用 DockerSW 的共享
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

## 隔离与路径

CI 入口只允许在 GitHub Actions 中运行，路径固定在 runner 的临时目录。
拒绝复用已有测试容器，不调用 `AppPaths.live()`，不使用日常主容器。
缓存命中时，先校验清洁快照，再复制到新隔离目录，绝不在缓存本体上运行。
`MacSWCI` 只放进 CI 私有 App 副本，不进入发布 zip。

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
- `cache.json` 区分 `fresh-install` 与 `installed-base-cache`。缓存命中不是本次全新安装
  证明；`force_fresh_install=true` 忽略缓存并重新挂载介质完成整个安装链。
- 每次运行都重新下载、注入临时验证资源；不缓存补丁后的容器，不公开这些二进制。

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
不再出现退出码 86。该轮共享运行尚未获得最终结果，且使用的是先前的 SWCLI 固定版本；
最新版本与 v2 缓存恢复仍需要各自的实际验证。
该轮 daemon 激活以 `REGDB_E_CLASSNOTREG` 失败，未进入共享建模；安装结束时的注册
校验通过不代表之后能完成 COM 激活。后续 CI 在夹具及启动准备后收集 64 位 ProgID/CLSID
查询，并在 daemon 日志保留 Wine OLE、异常及模块加载诊断，避免仅凭 HRESULT 猜原因。
工作流接线与离线测试不能证明实际安装、COM 激活或连续建模已通过。
