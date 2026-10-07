# MacSW 真实安装与运行 CI

`Build & Package MacSW.app` 的手动触发选项 `verify_solidworks=true` 增加 macOS/Wine
真实验证。普通 push 的测试、构建和打包流程不变。使用 GitHub 托管的 Apple Silicon
`macos-14` runner、仓库固定版本的 Wine/Mono/SWCLI，以及打包后的 App。
`runtime_stage=install` 只执行真实安装和私有夹具准备，不等待共享建模入口；
`runtime_stage=full` 再顺序执行共享运行验证。工作流不响应 PR，且 job 层再次限制事件类型。
带私有资源的验证只允许在本仓库 `master` 上手动触发，fork 或其他 ref 不能执行。

## 职责与顺序

MacSW 只负责宿主准备、复用实际安装链路、路径转换、daemon 生命周期和证据收集。
CAD 测试操作与断言只由 `Dependencies/SWCLI/scripts/ci` 的共享测试维护：

1. 检查 Secrets、runner 架构、共享入口和可用磁盘。
2. 通过 rclone 下载官方 ISO 与私有验证夹具，不引入 macOS FUSE 依赖。
3. 在 `$RUNNER_TEMP/MacSW-runtime/app-support/bottle` 创建全新测试容器。
   CI 专用 `MacSWCI` 入口调用 `BootstrapStore`，复用介质、Wine/Mono/COM、VC++、
   Login Manager、核心 MSI、语言、主题、托管 FlexNet 和安装结果校验。
4. 官方安装结束后，在此临时容器应用与 DockerSW 相同布局的私有验证资源。
   此操作只是为了 CI 无法访问开发者局域网许可服务器时验证可行性，
   不是 MacSW 产品功能，也不证明正版许可服务器联通性。
5. 执行 App 的 `RuntimeStore.startup(autoLaunch: false)` 字体准备路径，
   启动打包 `sw-cli daemon serve`，等待健康检查确认 COM 主机就绪。
6. 可见模式中顺序运行 `verify-modeling.py` 和 `verify-driving-dimensions.py`，
   每个入口前后核对同一个 daemon/SOLIDWORKS COM 主机的 PID、模式和元数据。
   中途不能重启 daemon 或 SOLIDWORKS；通用建模失败就保留失败，不继续尺寸测试。
7. 完成这两个入口后才停止第一套进程，再在隐藏模式重复上述顺序。
8. 无论成功或失败，都停止隔离 Wine server，删除私有 ISO、验证资源、临时 App
   和整个测试容器。只上传通过最终脱敏检查的测试 JSON 与 daemon 日志。
   测试生成的 SLDPRT 会被共享测试检查，但不上传二进制模型，以收紧敏感数据边界。

共享入口参数约定：`--output-dir`（本机输出目录）、`--host-output-dir`
（同一物理目录的 Wine 可见路径）、`--cli-command`（打包后的 CLI）、`--endpoint`。
输出目录在容器 `drive_c` 内；本机与 Wine 必须看到同一批模型与 JSON，不能只给
两侧分别建立独立目录。每次共享入口结束或失败后，再将白名单文件复制到上传证据目录。
已检查 SWCLI agent 的未提交通用建模入口，当前四个参数与尺寸入口一致。
SWCLI 共享入口尚未进入固定子模块提交时，runtime 预检明确失败，**不静默跳过**。

当前 MacSW 接线不自行复制 Windows/DockerSW 的启动矩阵、外部实例附着或几何断言。
这些测试若需要纳入跨平台运行，也应由 SWCLI 提供共享入口，再在此调用。
本次 CI 的 `Visible` 校验来自 COM 元数据，不等于人工验证窗口焦点、字体像素、IME、
Metal/OpenGL 图层或鼠标交互。

## 隔离与路径

CI 入口只允许在 GitHub Actions 中运行，路径固定在 runner 的临时目录。
拒绝复用已有测试容器，不调用 `AppPaths.live()`，不使用日常主容器。
`MacSWCI` 只放进 CI 私有 App 副本，不进入发布 zip。

模型和临时 CLI 输出置于测试容器的 `drive_c` 内；给临时 App 配置独立 `M:` 映射。
所有 Mac 路径经 App 的 `swcli-path` 按实际 `dosdevices` 转换；不拼接或假定 `Z:`。
CLI 生命周期中的辅助 EXE、当前目录及临时输出也使用同一真实映射解析器。

## 私密数据与产物

需要 `RCLONE_CONFIG_B64` 与 `SW_SERIAL_SOLIDWORKS` 两个仓库 Secret。
rclone 配置以 0600 临时文件保存并由退出 trap 删除。序列号只传给安装入口；
后续 daemon 和测试进程不继承这两个 Secret。

原始 MSI 日志会包含序列号，因此**不上传安装日志、完整容器、注册表 hive、许可文件、
私有夹具或补丁后的任何二进制**。只收集运行测试自己的白名单证据。
上传前再次清除原始/规范化序列号、rclone 凭据与 token；此隐私检查失败时禁止上传。
发布 App 在应用私有夹具前独立归档、上传，绝不能用测试容器内容重新打包。
失败时保留阶段、命令退出状态及部分 JSON 证据，不以日志上传成功代替运行验证成功。
工作流的清理步骤覆盖通常的失败/取消；runner 被强制终止时由托管 VM 的销毁收尾。

ISO、构建输入、App 和安装容器会同时占用磁盘。首轮下载前要求至少 45 GiB 空闲空间，
这只是预检阈值，不是已测得的峰值。若标准 runner 容量不足，先依据实际 `df` 证据
调整介质获取/释放时机或 runner 容量，不把磁盘失败当作 SOLIDWORKS 不兼容。

## 触发与验证边界

在 Actions 中选择该工作流，勾选 `verify_solidworks`，确认 Drive 介质与夹具路径。
CLI 等效调用：

```bash
gh workflow run build-app.yml --repo YJBeetle/MacSW --ref master \
  -f verify_solidworks=true -f runtime_stage=install -f language=chinese-simplified
```

共享脚本进入固定版本后，将 `runtime_stage` 改为 `full` 执行完整验证。

首次云端运行还需要确认 GUI 会话、Rosetta、磁盘、私有许可夹具与 Wine 冷启动行为。
工作流接线与离线测试不能证明实际安装、COM 激活或连续建模已通过。
