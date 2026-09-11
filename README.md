# MacSW

MacSW 是面向 Apple Silicon Mac 的独立 SwiftUI 应用，用固定版本 Wine 运行和维护
SOLIDWORKS 2025。最终用户只需要 `MacSW.app`，不需要源码目录、Homebrew 或外部启动脚本。

## 当前实现

- 固定使用唯一容器 `~/Library/Application Support/MacSW/bottle`，不提供容器切换。
- 使用经过安装验证的 Gcenx Wine 11.16，并校验下载归档的 SHA-256。
- 使用官方安装程序；支持拖入 ISO、已挂载介质或包含 `setup.exe` 的目录。
- 拖入安装介质、序列号注册表、许可服务目录或组件补丁目录中的任意一项时，自动在同级查找
  `sw*_network_serials_licensing.reg`、`SolidWorks_Flexnet_Server` 和 `SOLIDWORKS Corp`。
- 安装阶段的 32 位托管辅助程序使用 Wine-Mono 解释器；64 位 SOLIDWORKS 正常使用 JIT。
- App 负责环境初始化、VC++ 前置组件、安装、维护操作、FlexNet 状态和 SOLIDWORKS 启动。

## 图形窗口修复

SOLIDWORKS 的硬件加速视口由 macOS 原生图层承载。原版 `winemac.drv` 没有把 Win32
子窗口的可见区域同步给该图层，因此视口会盖住 FeatureManager 等停靠控件。

本项目在 Wine 11.16 源码上应用
[`0002-winemac-metal-layer-clipping.patch`](patches/wine-crossover/0002-winemac-metal-layer-clipping.patch)：

1. 从视口 HDC 读取 `SYSRGN`；
2. 将屏幕坐标转换为视口本地坐标；
3. 把区域矩形转换为 Core Animation 图层遮罩；
4. Win32 窗口布局变化时才更新遮罩。

这保留了 SOLIDWORKS 自己的窗口几何和硬件加速，不再由守护程序移动或缩放 3D 视口。

[`sw_ui_daemon.c`](scripts/sw_ui_daemon.c) 是独立的原生 x64 Win32 辅助程序，仅处理登录管理器、
CommandLink 字体、浮动工具窗口以及少量 Wine 主题兼容问题。它不依赖 .NET/Wine-Mono，也不改写
FeatureManager 或视口尺寸。

## 构建

开发机需要 Xcode Command Line Tools、Rosetta 2，以及两个 Homebrew 构建依赖：

```bash
brew install bison mingw-w64
./scripts/make_app.sh
```

产物位于 `build/app/MacSW.app`。打包流程会：

- 编译 SwiftUI 启动程序；
- 从 C 源码重建原生 UI 辅助程序；
- 下载并校验固定版本 Gcenx Wine 运行时；
- 从 Wine 11.16 官方源码重建打过补丁的 `winemac.so`；
- 覆盖经过验证的 Wine-Mono x86 修复模块；
- 对最终原生模块进行临时签名和校验。

每次构建只保留最终 `MacSW.app`，不会累计保存包含完整 Wine 运行时的旧 App 副本。

`build_winemac.sh` 会按 Wine 版本、源码校验值、补丁和构建脚本内容缓存产物。GitHub Actions
使用同一条构建链路。

## 使用与验证

```bash
open build/app/MacSW.app
```

在 App 中选择或拖入安装介质，按向导完成部署。干净安装会直接清空唯一容器，请确认其中没有需要保留的文件。

图形回归至少应覆盖：

- 新建 Part 后 FeatureManager 完整可见；
- 切换 FeatureManager/PropertyManager 时视口不遮挡左侧面板；
- 进入和退出草图、拉伸、旋转；
- 浮动工具条和对话框显示在视口上方；
- 保存、退出并重新打开零件。

更详细的安装链路和已验证边界见
[`docs/app-wine11-migration.md`](docs/app-wine11-migration.md)。

## 日志

日志位于 `~/Library/Application Support/MacSW/logs`，主要包括：

- `install_msi.log`
- `installer-wine.log`
- `prerequisites.log`
- `sw_launch.log`
- `ui-daemon.log`

若手动终止整个 Wine server，FlexNet 也会一同退出；再次启动 SOLIDWORKS 前应在 App 控制台重新启动许可服务。
