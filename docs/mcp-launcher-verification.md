# MCP daemon utilities 启动器修复

MacSW 的 SWCLI 源码固定到 769677ac6a2bdfb00e108c1606f419c0ef8e5f34（0.1.0a16）；它的产品源码与 3eba5c42776c6714d1a36a6458fab47aa7c3ff6d 逐字节相同，额外仅有 tag 发布 CI、脚本、测试和文档。本机已安装 App 的真实 SWCLI 接受来源仍明确为 3eba5c4，包含 1204621 的 Windows 单元断言修复和新的宿主启动器管道 EOF 修复。纯原生客户端包装脚本与单独 Wine daemon utilities 的边界保持。

DockerSW [42116004763](https://github.com/YJBeetle/DockerSW/actions/runs/42116004763) 的宿主实际已开始工作，但常驻 Wine 后代继承了启动器的 stdout/stderr，PIPE 捕获等到启动预算结束才返回，随后入口退出中断容器测试（137）。现改用私有临时文件，只等待启动器进程；启动预算、原生时限、无失败重试及宿主所有权检查不变。完整源码 1600 项单元测试通过，21 skip。

SSH workspaceroot 隔离 Wine 11.16 / Windows Python 3.11.9 最小复现：PIPE 的父启动器 0.816 秒退出，捕获调用到 4.060 秒才返回；临时文件方式在 0.616 秒返回，后台子进程仍运行。未启动 SW，临时容器已正常退出并移除。原始 probe-results.json SHA-256：eccc915099d1f980764fde8ec8a97ad305d58ec100b9f0b53a9800f2bdb8e21d。

默认 MacSW App/bottle 的实际 MCP 启停验证另行保留原始回执，不能把最小复现或单元测试当作 App/Wine 真实接受结果。此次源码指针更新没有申请 Apple 公证或发布 App。

## 默认 App 实测发现的启动准备差异

本机默认 App 已更新到固定 SWCLI 3eba5c4，原始 App 和 Python 运行时有独立备份；本地同 Team Developer ID 验签通过，没有申请新 Apple 公证。原默认容器的 Wine 身份旧于原 App，先通过受锁标准 upgrade 流程迁移，保存旧 receipt 和 registry 摘要，未绕过运行时检查。

随后单次显式 MCP start 遇到许可服务器未连接（-15,10,10061），原生 worker 等待失败，后续 CAD 未执行。只读核查确认已有注册表指向 25734@localhost，而端口未监听。原 GUI 的 RuntimeStore.startSWCLIDaemon() 会调用 LicenseServerStore.ensureRunningIfNeeded()，独立 daemon utilities 缺少同一准备步骤。

新增显式 MacSW --prepare-swcli-daemon 在 SwiftUI 初始化前，仅复用现有 refreshInstallation → ensureRunningIfNeeded。它不安装许可、不改变远程地址、不创建 SW；只有已安装托管清单且注册表指向匹配的本地端口才沿用既有条件启动服务。utils 只在显式 start/serve/restart 时调用；doctor、status、MCP 握手和断开不触发准备。指定 MACSW_WINEPREFIX 时沿用同一绝对 bottle 路径。准备失败在 COM 前返回，不再次调用准备或 SW。

5 项新增 Swift 离线用例、shell 包装契约和 MacSW 主产品编译通过。完整 Core 测试 238 项通过；Python 离线测试 365 项、1 skip 通过。首次失败的本次空宿主已核对 PID/同 prefix 路径并用标准 wine_runtime.py stop 清理，未 Unix 强杀或重试原生失败。修复后的实际启停接受结果单独记录。

原始失败 start-license-blocked.json SHA-256：ba9e4ab625f67c853f8e45809450410fd1188b25efcba72b5dbb007a52a9832c。
只读 license-observation.json SHA-256：e1bf279c9eed02a9a8a79f1e5f8fb155e7a7e46fd9bc380849fc773a8cb96d74。
迁移证据 bottle-migration-evidence.json SHA-256：ca01e06fe378a4b2e8278f01739b5a14c8f2fc5cbd36a4a6e02799f0beecd3be。

## 修复后的默认 MacSW App 真实 MCP 接受

MacSW 功能源码 fd9402633b23bba83fe75b23a023e07e8d37cb75；默认 /Applications/MacSW.app 的主二进制重新构建并同 Team Developer ID 验签。它是本机 arm64 debug 验证包，未重新申请公证、未发布。App 的双 Python 与默认 bottle 仍固定真实 SWCLI 3eba5c4，72 个源码/资源文件逐字节匹配；没有为了纯 CI 改动重部署另一个产品版本。原始 App 与之前本地包均有独立备份。

- 更新后握手、五工具发现与离线 status 不启动 SW。
- 只进行一次有针对性的显式 start，45.602 秒就绪；owned/hidden SW 的 Windows PID404（macOS PID62776），实时 top-level-windows 观察确认隐藏，无用户或其他 SW。文档列表 schema 与真实空列表读取通过。
- 第一条 stdio 连接退出后宿主保留。第二条连接确认同一 PID404、空文档，显式 stop 返回 success。
- stop 后同一 MCP 仍能返回结构化 status；TCP 关闭竞态先返回 ConnectionReset/unknown，原 harness 错误地要求立即 false，原失败断言及回执保留未修改。随后独立新连接只做一次只读 status，确认 stopped/端口拒绝连接，SW/pythonw 均已退出；没有重启、重做 CAD 或重试原生调用。
- 新准备入口自动复用本地托管许可服务；没有手工启动或重配许可。daemon stop 只管理其 SW/daemon，共享的 lmgrd、SW_D 和 wineserver 按现有规则保留，许可端口仍可用。

这验证了真实默认 App/bottle、宿主准备和 MCP 生命周期，不替代完整 CAD 矩阵。原始成功与失败接受记录、独立终态、源码/签名摘要以及 SHA256SUMS 保留在 /private/tmp/macsw-mcp-local-20261106/success-fd94026-3eba5c4。

| 原件 | SHA-256 |
| --- | --- |
| start.json | 4205839434f0d9b0acb2cdc30ab4986249212cbc22f9cf14e427191eb99899cf |
| reconnect-stop.json（保留瞬时 unknown 断言） | 77684b2570da870c5d4641b06e91ade02a612d17321dc43c39d69f30f777ec73 |
| after-stop-status.json（独立只读终态） | bc85d73c6207bf46dd44406da7bc6abfe098171d424344b6ce0f5d14e3e93b62 |
| installed-license-fix.json | 20750f948cd46d37e42f84753a856a39739d0d0f8c8ed2ce6e575a068297218c |
| final-source-proof.json | a68b6bc54b3dd8b469a0819fdc8d573ef29b2348a0569803c99701c49d34bd09 |
| summary.json | 0ebe200dbf618832119943bbcc5e326775775bb3e3ae5818b9e38263ce75ec10 |

## 日常 push CI 原包核验

[42126959890](https://github.com/YJBeetle/MacSW/actions/runs/42126959890)，push/master，a298998f7d6a0bb1d17f16db5d9df9e1cdba7519，attempt1，整体成功。MacSW Python365、Swift238、SWCLI1618（15skip）通过；真实 SW job 按日常策略跳过，没有把它当完整 SW 接受。

原 App artifact13461867919 ZIP522076349B，SHA77c4011ad12e05cb59d7069514101eb97e22a6d3d4b658986c040e1b341b4ca1，与 GitHub 匹配；内 App ZIP SHA2e98a06c629bb3b01ac2dc37dc99342d26bc4fdb6888f25818b8956dd562cfdc。只读核验0.1.10(12)、SWCLI0.1.0a16/769677a、native Python3.11.16/MCP1.30.0、双 Python72源码资源逐字节一致、856runtime manifest匹配，新显式准备入口和utils均在原包内。

写缓冲ZIP SHA f1a539a95dae23c7c0464d252f3c5ad9b69beae7955ab4d48807ca32c0008043，5cases原始marker通过；原生文件面板ZIP SHA c1788854974de3c661307841837a39da454e2162a1dcaa7986ab6b88bcd22355，x64/x86共24cases原log/request通过。Toolbox primitive11步只取得原build日志passed，未上传逐探针report，不能声称已独立复核该report原件。

该日常 App 是待distribution签名的原包（只有linker ad-hoc，尚无sealed资源），不是Developer ID/公证/正式发布；未用它覆盖或运行本机默认 App。原件/日志/只读审计位于/private/tmp/macsw-mcp-ci-42126959890，summary SHA026629d20ee23c1e77edf2a53bd33f54ead33917eef79b258274324243c88a2c，82原件摘要索引 SHAce73edb313a0eb754b0de0797baf93ee06eb2950bdfcd858ae2913fa17c20844。
