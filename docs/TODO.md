# 项目待办

## 当前优先级

官方安装已经完成，主界面和新建 Part 已通过。继续验证建模操作；以下构建系统迁移不阻塞功能验证。

## 官方安装后的待核查项

- [ ] 明确安装向导中已选择的维护资源与实际执行之间的状态：目前选择组件/许可目录只保存路径，不自动同步组件或启动服务；用户预期选择后会执行，当前行为存在偏差。避免仅凭 DLL 文件存在就显示“已应用”。
- [x] 处理官方安装末尾的 32 位托管注册路径。修复 Wine-Mono x86 native thunk，并在安装阶段使用解释器模式后，官方安装向导已正常完成。见 [验证记录](regasm-validation.md)。
- [x] 核查正式单容器的许可证服务。`lmgrd`、`SW_D` 日志及 25734 监听均已确认，SOLIDWORKS 主界面可启动。
- [ ] 完成剩余 GUI 验证。
  - [x] 新建 Part 后 FeatureManager 避让：已由 `winemac.drv` 原生图层裁剪修复。
  - [x] 复合右键菜单与鼠标手势输入：安装 Login Manager 并完成托管 COM 注册后，缺失提示不再创建，一级/二级菜单和轮盘操作均恢复正常。根因是 UI 守护程序只隐藏了致命模态对话框，主线程仍困在 `TaskDialogIndirect` 消息循环内；不是 Wine 鼠标捕获缺陷。见 [调查记录](login-manager-ui.md)。
  - [ ] PropertyManager、草图、拉伸、旋转、保存和重开。
  - [ ] 修复鼠标手势轮盘的透明背景。`swGestureTarget` 是独立 Afx 顶层窗口；轮盘可响应，但本应透明的圆环外侧和中心当前显示为黑色。已采样到窗口扩展样式为 `0x88`（未含 `WS_EX_LAYERED`），后续单独核查 `SetWindowRgn`、`UpdateLayeredWindow` 与 Windows DWM 到 `winemac.drv` 的合成路径，不与右键菜单捕获问题混为一项。
  - [ ] 按钮风格、字体和 Toolbox 数据库。
- [ ] 处理 macOS 显示器热插拔后的 Wine 显示拓扑刷新。
  - 检测主显示器、虚拟桌面范围或缩放变化，并让 Wine 重新枚举显示器，避免全屏窗口被限制在左上角的旧区域以及模态对话框出现在画面外。
- [x] 解耦 MacSW Builder 和正式运行路径与固定的 SOLIDWORKS 大版本。
  - App 版本和 Wine 运行时版本独立管理；SOLIDWORKS 版本不参与 Builder 配置，验证结果统一记录在 [兼容性报告](compatibility.md)。
  - 面向特定版本的诊断脚本和历史验证文档继续保留，但不进入正式运行路径。
- [ ] 将 SOLIDWORKS Login Manager 安装与托管 COM 注册修复接入 App。
  - 当前流程直接运行 `swwi/data/solidworks.msi`，绕过根目录 `setup.exe` 对 `swloginmgr/SOLIDWORKS Login Manager.msi` 的前置组件编排；App 内 RegAsm 仍是只返回成功的兼容程序。
  - 已在全新干净安装的正式 bottle 中手工安装 Login Manager，并用修复后的 Wine-Mono 完成 `sldLoginManager.dll` 注册；缺失弹窗消失，右键菜单与鼠标手势恢复正常。该结果尚未接入 App 自动安装流程。
  - `EnableSldLoginManager=0` 和 `SW_Login_Disable=True` 均不能绕过组件检查。UI 守护程序的隐藏兜底已删除，避免让隐藏模态循环继续阻塞主线程。见 [调查记录](login-manager-ui.md)。

## 构建系统迁移

- [x] 使用 SwiftPM 管理 Swift 模块、启动程序和 XCTest。
- [x] 使用顶层 Makefile 统一编排依赖获取、构建、打包、校验和 CI 归档。
- [x] 将 App、Wine、Wine-Mono、7-Zip 版本及依赖校验值集中到单一配置文件。
- [x] 保留小型 Shell 脚本负责 Wine/7zz 下载、校验、缓存与嵌入，避免每次修改 UI 都重新编译 Wine。
- [x] UI 守护程序从原生 C 源码做可重复的 x64 构建，不再提交生成的 PE 文件。
- [ ] 配置 Developer ID 签名与公证；所需账号及凭据另行确认。
- [ ] 在 GitHub Actions 新 Builder 首次运行后核对缓存命中、归档和 Release 上传。

最终仍只交付独立 `MacSW.app`，固定使用单容器，不引入用户运行时对源码目录或外部脚本的依赖。
