# App-only Wine 11 migration

## 交付与验证

构建：`make app`。输出 `build/app/MacSW.app`，可移动到其他目录；不依赖源码工作区、Homebrew、Python 或外部启动脚本。Apple Silicon 仍需 Rosetta 2。当前是本地测试包，未做 Developer ID 签名与公证。

先正常关闭旧 MacSW App，再打开新 App，拖入或选择官方 ISO 或安装介质目录，完成安装并验证启动。注册表和两个维护目录同样支持拖入。最终固定使用一个容器，不提供选择/切换容器功能。

唯一容器为 `~/Library/Application Support/MacSW/bottle`，日志位于同级 logs，含 sw_launch.log、ui-daemon.log、install_msi.log、installer-wine.log、prerequisites.log 等。本轮按用户要求将旧正式容器备份后从空环境验证，不复制诊断容器作为安装结果。

当前已经验证官方安装程序能够完成、主界面能够启动、新建 Part 正常，以及 FeatureManager 在硬件加速视口前保持可见。草图/属性管理器切换、拉伸、旋转、保存并重开仍需继续回归。

## 实现边界

- WineService 仅解析 App 包内的 wine/bin/wineloader 与 wineserver；所有启动入口调用 AppState.launchSolidWorks，统一 WPF/VC 前置检查与重复启动保护。
- 运行时固定 Gcenx wine-devel 11.16，SHA-256 校验归档；在其上覆盖由 Wine 11.16 官方源码和仓库补丁重建的 `winemac.so`。
- 安装阶段使用 Mono 11.3.0 x86 修复模块和解释器模式，避免 32 位托管辅助程序在 Rosetta 下进入不稳定的 JIT 路径；64 位 SOLIDWORKS 使用 JIT。
- 启动启用 atiadlxx=d 和微软 VC++ native-first overrides；启动 App 内原生 x64 UI 辅助程序，SW 退出后终止本次辅助程序。登录管理器弹窗当前由辅助程序隐藏，注册表禁用值已确认无效并移除。
- 官方安装：用户选择介质 → wineboot → 官方 VC x64 安装包 → 可选注册表导入 → 官方 MSI（禁止回退并记录日志）→ 五个 WPF 主题库。组件和语言不再由 Swift 猜测、解包或注入。
- 保留用户显式操作的许可及组件维护入口，未把第三方许可或组件文件打入 App。
- 安装失败仍会报告非零退出码；尚未实现失败自定义动作的完整恢复。Toolbox 数据库和剩余字体问题仍需单独验证。
- 删除 CAB 直接部署服务、介质组件扫描服务、相关测试、旧 run_sw.sh 和未使用的重复 LicenseService；历史可从 Git 恢复。开发诊断脚本仅留在源码，不随 App 运行。

## 本地检查

SwiftPM 编译与测试：

```bash
make bootstrap
make test
```

XCTest 覆盖同级维护文件发现、RegAsm 兼容逻辑、bundle-only 路径、环境隔离、原生 VC 加载策略、含空格/单引号路径的 shell 转义和进程启动错误。SW GUI 由用户验证，以上检查不能替代建模验收。

## 正式单容器首次安装反馈（2026-09-11）

用户通过 App 完成了一轮官方安装操作并启动 SW，但安装器仍显示中断，SW 停在许可证错误，并未完成主界面验收。

- install_msi.log 的 SWRegistration 阶段调用 Framework64/v4.0.30319/regasm.exe 时 CreateProcess 失败，返回 0x643；DISABLEROLLBACK 和 RollbackDisabled 均为 1。
- ui-daemon.log 确认已启动 watch 模式。
- 当前安装后的逻辑只补齐 WPF，不调用 applyComponentPatch/startLicenseServer。选择维护目录不代表已执行维护操作，用户对自动执行的预期尚未满足。
- 只读比较确认正式安装目录的 sldutu.dll、swsecwrap.dll 与用户所选组件目录中的文件不一致。
- 截图错误为 Invalid (inconsistent) license key (-8,544,0)；本机 25734 端口连通。尚未确认具体许可配置不一致的原因，不据此断言服务未启动。

此阶段提交保存 App-only 重构与官方安装链路，不代表完整安装、许可或建模验证通过。

## 安装与图形里程碑（2026-09-12）

- 修复后的 Wine-Mono x86 模块配合安装阶段解释器模式，使官方 SOLIDWORKS 2025 SP5 安装向导正常到达成功页面。
- SOLIDWORKS 主界面及新建 Part 已在唯一正式容器中启动。
- Wine `winemac.drv` 现在把 Win32 `SYSRGN` 转为视口 Core Animation 图层遮罩。实测 3D 窗口保持 SOLIDWORKS 原始几何，遮罩可见区从 FeatureManager 右缘开始，左侧树不再被视口覆盖。
- 原 C# 守护程序已替换为原生 x64 Win32 辅助程序，不再经过 Wine-Mono；它只保留普通对话框与浮动窗口层级，以及离屏窗口找回职责。Login Manager 等致命前置组件错误不再隐藏，避免其模态消息循环在不可见状态下持续阻塞主线程。
