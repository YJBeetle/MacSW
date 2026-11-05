# MCP daemon utilities 启动器修复

MacSW 的 SWCLI 固定到 3eba5c42776c6714d1a36a6458fab47aa7c3ff6d（0.1.0a16），包含 1204621 的 Windows 单元断言修复和新的宿主启动器管道 EOF 修复。纯原生客户端包装脚本与单独 Wine daemon utilities 的边界保持。

DockerSW [42116004763](https://github.com/YJBeetle/DockerSW/actions/runs/42116004763) 的宿主实际已开始工作，但常驻 Wine 后代继承了启动器的 stdout/stderr，PIPE 捕获等到启动预算结束才返回，随后入口退出中断容器测试（137）。现改用私有临时文件，只等待启动器进程；启动预算、原生时限、无失败重试及宿主所有权检查不变。完整源码 1600 项单元测试通过，21 skip。

SSH workspaceroot 隔离 Wine 11.16 / Windows Python 3.11.9 最小复现：PIPE 的父启动器 0.816 秒退出，捕获调用到 4.060 秒才返回；临时文件方式在 0.616 秒返回，后台子进程仍运行。未启动 SW，临时容器已正常退出并移除。原始 probe-results.json SHA-256：eccc915099d1f980764fde8ec8a97ad305d58ec100b9f0b53a9800f2bdb8e21d。

默认 MacSW App/bottle 的实际 MCP 启停验证另行保留原始回执，不能把最小复现或单元测试当作 App/Wine 真实接受结果。此次源码指针更新没有申请 Apple 公证或发布 App。

## 默认 App 实测发现的启动准备差异

本机默认 App 已更新到固定 SWCLI 3eba5c4，原始 App 和 Python 运行时有独立备份；本地同 Team Developer ID 验签通过，没有申请新 Apple 公证。原默认容器的 Wine 身份旧于原 App，先通过受锁标准 upgrade 流程迁移，保存旧 receipt 和 registry 摘要，未绕过运行时检查。

随后单次显式 MCP start 遇到许可服务器未连接（-15,10,10061），原生 worker 等待失败，后续 CAD 未执行。只读核查确认已有注册表指向 25734@localhost，而端口未监听。原 GUI 的 RuntimeStore.startSWCLIDaemon() 会调用 LicenseServerStore.ensureRunningIfNeeded()，独立 daemon utilities 缺少同一准备步骤。

新增显式 MacSW --prepare-swcli-daemon 在 SwiftUI 初始化前，仅复用现有 refreshInstallation → ensureRunningIfNeeded。它不安装许可、不改变远程地址、不创建 SW；只有已安装托管清单且注册表指向匹配的本地端口才沿用既有条件启动服务。utils 只在显式 start/serve/restart 时调用；doctor、status、MCP 握手和断开不触发准备。指定 MACSW_WINEPREFIX 时沿用同一绝对 bottle 路径。准备失败在 COM 前返回，不再次调用准备或 SW。

5 项新增 Swift 离线用例、shell 包装契约和 MacSW 主产品编译通过。完整 Core 测试 238 项通过；Python 离线测试 365 项、1 skip 通过。首次失败的本次空宿主已核对 PID/同 prefix 路径并用标准 wine_runtime.py stop 清理，未 Unix 强杀或重试原生失败。修复后的实际启停接受结果单独记录。

原始失败 start.json SHA-256：ba9e4ab625f67c853f8e45809450410fd1188b25efcba72b5dbb007a52a9832c。
只读 license-observation.json SHA-256：e1bf279c9eed02a9a8a79f1e5f8fb155e7a7e46fd9bc380849fc773a8cb96d74。
迁移证据 bottle-migration-evidence.json SHA-256：ca01e06fe378a4b2e8278f01739b5a14c8f2fc5cbd36a4a6e02799f0beecd3be。
