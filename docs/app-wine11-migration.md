# App-only Wine 11 migration

## 交付与验证

构建：`bash scripts/make_app.sh`。输出 `build/app/MacSW.app`，可移动到其他目录；不依赖源码工作区、Homebrew、Python 或外部启动脚本。Apple Silicon 仍需 Rosetta 2。当前是本地测试包，未做 Developer ID 签名与公证。

先正常关闭旧 MacSW App，再打开新 App，拖入或选择官方 ISO 或安装介质目录，完成安装并验证启动。注册表和两个维护目录同样支持拖入。最终固定使用一个容器，不提供选择/切换容器功能。

唯一容器为 `~/Library/Application Support/MacSW/bottle`，日志位于同级 logs，含 sw_launch.log、ui-daemon.log、install_msi.log、installer-wine.log、prerequisites.log 等。本轮按用户要求将旧正式容器备份后从空环境验证，不复制诊断容器作为安装结果。

请验证：主界面、新建零件、设计树可见和选择、草图/属性管理器切换、拉伸、旋转、保存并重开。UI 守护复用了提交 808d021 的实现，本轮没有重写其避让算法，也不承诺它已适配 Wine 11。按钮外观留待后续。

## 实现边界

- WineService 仅解析 App 包内的 wine/bin/wineloader 与 wineserver；所有启动入口调用 AppState.launchSolidWorks，统一 WPF/VC 前置检查与重复启动保护。
- 运行时固定 Gcenx wine-devel 11.16，SHA-256 校验归档。使用随包 Mono 11.3.0，不再复制旧 mscoree。
- 启动启用 atiadlxx=d 和微软 VC++ native-first overrides；沿用登录管理器禁用配置，启动 App 内 UI 守护，SW 退出后终止本次守护。
- 官方安装：用户选择介质 → wineboot → 官方 VC x64 安装包 → 可选注册表导入 → 官方 MSI（禁止回退并记录日志）→ 五个 WPF 主题库。组件和语言不再由 Swift 猜测、解包或注入。
- 保留用户显式操作的许可及组件维护入口，未把第三方许可或组件文件打入 App。
- 安装失败仍会报告非零退出码；尚未实现失败自定义动作的完整恢复。Toolbox 数据库、Segoe UI 字体缺失及 .NET regasm 注册问题未解决。
- 删除 CAB 直接部署服务、介质组件扫描服务、相关测试、旧 run_sw.sh 和未使用的重复 LicenseService；历史可从 Git 恢复。开发诊断脚本仅留在源码，不随 App 运行。

## 本地检查

`bash macos/Bootstrap/build_bootstrap.sh` 编译 Swift。

运行配置回归测试：

```sh
swiftc macos/Bootstrap/Services/WineService.swift macos/Bootstrap/Services/PrerequisiteService.swift macos/Bootstrap/Tests/test_runtime.swift -o /tmp/macsw-runtime-tests
/tmp/macsw-runtime-tests
```

测试覆盖 bundle-only 路径、环境隔离、原生 VC 加载策略、含空格/单引号路径的 shell 转义和进程启动错误。SW GUI 由用户验证，以上检查不能替代建模验收。

## 正式单容器首次安装反馈（2026-09-11）

用户通过 App 完成了一轮官方安装操作并启动 SW，但安装器仍显示中断，SW 停在许可证错误，并未完成主界面验收。

- install_msi.log 的 SWRegistration 阶段调用 Framework64/v4.0.30319/regasm.exe 时 CreateProcess 失败，返回 0x643；DISABLEROLLBACK 和 RollbackDisabled 均为 1。
- ui-daemon.log 确认已启动 watch 模式。
- 当前安装后的逻辑只补齐 WPF，不调用 applyComponentPatch/startLicenseServer。选择维护目录不代表已执行维护操作，用户对自动执行的预期尚未满足。
- 只读比较确认正式安装目录的 sldutu.dll、swsecwrap.dll 与用户所选组件目录中的文件不一致。
- 截图错误为 Invalid (inconsistent) license key (-8,544,0)；本机 25734 端口连通。尚未确认具体许可配置不一致的原因，不据此断言服务未启动。

此阶段提交保存 App-only 重构与官方安装链路，不代表完整安装、许可或建模验证通过。
