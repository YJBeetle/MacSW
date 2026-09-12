# 项目待办

## 当前优先级

官方安装已经完成，主界面和新建 Part 已通过。继续验证建模操作；以下构建系统迁移不阻塞功能验证。

## 官方安装后的待核查项

- [ ] 明确安装向导中已选择的维护资源与实际执行之间的状态：目前选择组件/许可目录只保存路径，不自动同步组件或启动服务；用户预期选择后会执行，当前行为存在偏差。避免仅凭 DLL 文件存在就显示“已应用”。
- [x] 处理官方安装末尾的 32 位托管注册路径。修复 Wine-Mono x86 native thunk，并在安装阶段使用解释器模式后，官方安装向导已正常完成。见 [验证记录](regasm-validation.md)。
- [x] 核查正式单容器的许可证服务。`lmgrd`、`SW_D` 日志及 25734 监听均已确认，SOLIDWORKS 主界面可启动。
- [ ] 完成剩余 GUI 验证。
  - [x] 新建 Part 后 FeatureManager 避让：已由 `winemac.drv` 原生图层裁剪修复。
  - [ ] PropertyManager、草图、拉伸、旋转、保存和重开。
  - [ ] 按钮风格、字体和 Toolbox 数据库。
- [ ] 处理 macOS 显示器热插拔后的 Wine 显示拓扑刷新。
  - 检测主显示器、虚拟桌面范围或缩放变化，并让 Wine 重新枚举显示器，避免全屏窗口被限制在左上角的旧区域以及模态对话框出现在画面外。
- [ ] 解耦 MacSW 与固定的 SOLIDWORKS 大版本。
  - 盘点 Swift、VBS 和 REG 文件中的版本化注册表路径、快捷方式及显示文本；实施时再结合安装介质和已安装信息，确定自动识别或产品配置方式。
- [ ] 正式处理 SOLIDWORKS Login Manager 缺失弹窗。
  - 当前 Wine 环境会提示 `SOLIDWORKS Login Manager is not installed`，确认按钮会导致 SOLIDWORKS 退出；UI 守护程序暂时按窗口内容隐藏该弹窗。
  - 已实测 HKCU 与 HKLM 下的 `EnableSldLoginManager=0` 均不能阻止弹窗，不能作为解决方案。后续应确认安装介质是否漏装 Login Manager 组件，或寻找受支持的禁用入口，并移除隐藏兜底。

## 构建系统迁移

- [ ] 将手工 swiftc 编译与 App 拼装迁移到 Xcode 工程 + xcodebuild。
  - 统一管理 Swift 源文件、App 资源、版本及 Debug/Release 配置。
  - 接入测试 target，并在 CI 中执行构建、测试和归档。
  - 保留小型 Shell 脚本负责 Wine/7zz 下载、校验、缓存与嵌入，避免每次修改 UI 都重新解压运行时。
  - [x] UI 守护程序从原生 C 源码做可重复的 x64 构建，并验证包内产物一致性。
  - 配置签名与发布流程；Developer ID 签名、公证所需账号及凭据另行确认。
  - 保持最终只交付独立 MacSW.app、固定单容器的目标，不引入用户运行时对源码目录或外部脚本的依赖。
