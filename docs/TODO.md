# 项目待办

## 当前优先级

官方安装已经完成，主界面和新建 Part 已通过。继续验证建模操作；以下构建系统迁移不阻塞功能验证。

## 官方安装后的待核查项

- [x] 移除旧安装向导中“选择路径但未明确执行”的组件/许可维护入口。App 不再提供替换 SOLIDWORKS 官方文件的能力；托管 FlexNet 改为设置页显式安装，并复制到固定的 `C:\\opt\\FlexNet` 后运行。
- [x] 处理官方安装末尾的 32 位托管注册路径。修复 Wine-Mono x86 native thunk，并在安装阶段使用解释器模式后，官方安装向导已正常完成。见 [验证记录](regasm-validation.md)。
- [x] 核查正式单容器的许可证服务。`lmgrd`、`SW_D` 日志及 25734 监听均已确认，SOLIDWORKS 主界面可启动。
- [ ] 完成剩余 GUI 验证。
  - [x] 新建 Part 后 FeatureManager 避让：已由 `winemac.drv` 原生图层裁剪修复。
  - [x] 清除 Login Manager 隐藏模态循环：安装 Login Manager 并完成托管 COM 注册后，缺失提示不再创建，一级/二级菜单和轮盘不再被 `TaskDialogIndirect` 消息循环整体阻塞。
  - [x] 修复 SOLIDWORKS 的同窗口鼠标捕获重入：`win32u` 在显式启用 `WINE_NOCAPTURERESEND` 时不再向重复取得自身捕获的窗口发送 `WM_CAPTURECHANGED`。同一二进制开关前后 A/B 验证表明，PropertyManager 左上角确认按钮由释放后仍捕获、状态 `0x0c`，恢复为释放捕获、状态 `0x00` 并执行命令。见 [调查记录](login-manager-ui.md)。
  - [x] 修复硬件加速视口的前缓冲刷新：`winemac.drv` 不再把前缓冲 `glFlush`/`glFinish` 当作双缓冲交换。补丁版已验证空白画布连续点击和窗口失焦不再使模型消失，边线橙色预选可持续显示。见 [调查记录](opengl-front-buffer.md)。
  - [ ] 继续覆盖 PropertyManager、草图、拉伸、旋转、保存和重开；创建/编辑拉伸的左上角确认按钮及模型保存已经通过本轮回归。
  - [ ] 修复鼠标手势轮盘的透明背景。`swGestureTarget` 是独立 Afx 顶层窗口；轮盘可响应，但本应透明的圆环外侧和中心当前显示为黑色。已采样到窗口扩展样式为 `0x88`（未含 `WS_EX_LAYERED`），后续单独核查 `SetWindowRgn`、`UpdateLayeredWindow` 与 Windows DWM 到 `winemac.drv` 的合成路径，不与右键菜单捕获问题混为一项。
  - [x] 统一 Part 文档窗口的五个标题按钮风格：安装时关闭 Wine ThemeManager 的活动主题，避免 Codejock 绘制的两个按钮与 Wine `DefWindowProc` 绘制的三个按钮混用不同皮肤。见 [调查记录](caption-button-theme.md)。
  - [ ] 字体和 Toolbox 数据库。
- [ ] 处理 macOS 显示器热插拔后的 Wine 显示拓扑刷新。
  - 检测主显示器、虚拟桌面范围或缩放变化，并让 Wine 重新枚举显示器，避免全屏窗口被限制在左上角的旧区域以及模态对话框出现在画面外。
- [x] 解耦 MacSW Builder 和正式运行路径与固定的 SOLIDWORKS 大版本。
  - App 版本和 Wine 运行时版本独立管理；SOLIDWORKS 版本不参与 Builder 配置，验证结果统一记录在 [兼容性报告](compatibility.md)。
  - 面向特定版本的诊断脚本和历史验证文档继续保留，但不进入正式运行路径。
- [x] 将 SOLIDWORKS Login Manager 安装与托管 COM 注册修复接入 App。
  - Builder 从固定版本、固定校验值的微软 NuGet 包提取 `stdole.dll`，并从固定 Wine-Mono prerelease 获取匹配的 `mscorlib.dll` 与 x86/x64 托管 RegAsm；App 在共享组件目录放置依赖并安装已校验的注册入口。
  - App 在 SOLIDWORKS 主 MSI 前静默安装 `swloginmgr/SOLIDWORKS Login Manager.msi`，保留独立详细日志；修复后的 Wine-Mono 完成 `sldLoginManager.dll` 托管 COM 注册。
  - 2026-09-13 使用重新打包的 App 清理旧 bottle 并执行干净安装端到端回归：新 bottle 生成了 Login Manager 的 CLSID、`mscoree.dll` 承载项与真实 CodeBase，SOLIDWORKS 启动时不再出现 Login Manager 缺失弹窗，可排除此前手工注册残留。
  - `EnableSldLoginManager=0` 和 `SW_Login_Disable=True` 均不能绕过组件检查。UI 守护程序的隐藏兜底已删除，避免让隐藏模态循环继续阻塞主线程。见 [调查记录](login-manager-ui.md)。

## 构建系统迁移

- [x] 使用 SwiftPM 管理 Swift 模块、启动程序和 XCTest。
- [x] 使用顶层 Makefile 统一编排依赖获取、构建、打包、校验和 CI 归档。
- [x] 将 App、Wine、Wine-Mono、7-Zip 版本及依赖校验值集中到单一配置文件。
- [x] 保留小型 Shell 脚本负责 Wine/7zz 下载、校验、缓存与嵌入，避免每次修改 UI 都重新编译 Wine。
- [x] 将官方 `stdole` NuGet 包作为构建时依赖下载、校验并嵌入 App，不在仓库提交 DLL。
- [x] UI 守护程序从原生 C 源码做可重复的 x64 构建，不再提交生成的 PE 文件。
- [x] 将 SwiftUI 重构为菜单栏启动器、独立 Bootstrap 窗口和设置窗口；Core 服务与视图分 target，增加标准本地 Run 动作。
- [ ] 使用全新容器回归新的可取消 Bootstrap、文本/.reg 序列号预载、安装完成后自动启动，以及托管 FlexNet 的安装/卸载与多服务器合并。
- [ ] 配置 Developer ID 签名与公证；所需账号及凭据另行确认。
- [ ] 在 GitHub Actions 新 Builder 首次运行后核对缓存命中、归档和 Release 上传。

最终仍只交付独立 `MacSW.app`，固定使用单容器，不引入用户运行时对源码目录或外部脚本的依赖。
