# MacSW

MacSW 是面向 Apple Silicon Mac 的独立 SwiftUI 应用，用固定、可校验的 Wine 运行和维护
SOLIDWORKS。最终用户只需要 `MacSW.app`，不需要源码目录、Homebrew 或外部启动脚本。

## 当前实现

- 固定使用唯一容器 `~/Library/Application Support/MacSW/bottle`，不提供容器切换。
- 使用 [`config/versions.env`](config/versions.env) 固定的 Gcenx Wine，并校验下载归档的 SHA-256。
- Bootstrap 全程静默部署官方介质：主体 MSI 以 `/qb` 加已验证的属性树安装，无需在安装窗口内点击，
  安装过程仍可终止。支持 ISO 或包含 `swwi/data/solidworks.msi` 的介质目录，开装前先校验官方 MSI、
  VC++/Login Manager/.NET 前置件与 Toolbox 载荷是否齐备。
- 安装序列号按 SOLIDWORKS/Simulation/Motion/MBD 四项填写，直接作为 MSI 公共属性传入，不再预写注册表。
  选择介质时会扫描其同级与介质内部（最深三层）的文本与注册表导出并匹配取值：唯一的自动回填，
  存在多个不同取值的字段留空交给用户确认。`.reg` 只作为读取来源，不再导入容器。
- 界面语言在安装界面选择，清单来自介质 `swwi/lang` 实际存在的官方语言 MSI，在主体安装完成后静默追加。
- 正常运行时只显示菜单栏启动器；启动 App 后默认自动启动 SOLIDWORKS，设置窗口负责 Wine 工具、
  服务器地址以及托管 FlexNet 的安装、卸载、启动和停止。
- 托管 FlexNet 经结构校验后原子复制到容器内固定位置 `C:\\opt\\FlexNet`，运行时不再依赖用户最初选择的外部目录。
- 安装阶段的 32 位托管辅助程序使用 Wine-Mono 解释器；64 位 SOLIDWORKS 正常使用 JIT。
- App 在主安装器前校验并放置固定版本 `stdole`，随后静默安装介质中的官方 Login Manager；
  两者的安装结果都按注册表内容断言托管 COM 注册，主 MSI 完成后额外校验 `SldWorks.Application`
  的 COM 链路，安装器退出码本身不作为成功依据。
- App 不提供替换或修改 SOLIDWORKS 官方程序文件的功能。

## 图形窗口修复

SOLIDWORKS 的硬件加速视口由 macOS 原生图层承载。原版 `winemac.drv` 没有把 Win32
子窗口的可见区域同步给该图层，因此视口会盖住 FeatureManager 等停靠控件。

本项目在 Builder 当前固定的 Wine 源码上应用
[`0002-winemac-metal-layer-clipping.patch`](patches/wine-crossover/0002-winemac-metal-layer-clipping.patch)：

1. 从视口 HDC 读取 `SYSRGN`；
2. 将屏幕坐标转换为视口本地坐标；
3. 把区域矩形转换为 Core Animation 图层遮罩；
4. Win32 窗口布局变化时才更新遮罩。

这保留了 SOLIDWORKS 自己的窗口几何和硬件加速，不再由守护程序移动或缩放 3D 视口。

同一驱动中的前缓冲刷新还有一处独立问题：Wine 会在应用已经执行 `glFlush`/`glFinish` 后，
再次调用会交换双缓冲的 `NSOpenGLContext.flushBuffer`。SOLIDWORKS 用前缓冲绘制选择、预选和
局部界面状态，因此空白点击或窗口失焦会把完整模型画面换走，边线橙色预选也只会闪现。
[`0004-winemac-preserve-front-buffer-flush.patch`](patches/wine-crossover/0004-winemac-preserve-front-buffer-flush.patch)
让真正的缓冲交换只发生在 SwapBuffers 路径；调查与回归证据见
[`docs/opengl-front-buffer.md`](docs/opengl-front-buffer.md)。

[`sw_ui_daemon.c`](scripts/sw_ui_daemon.c) 是独立的原生 x64 Win32 辅助程序，仅处理
普通对话框与浮动工具窗口层级，以及离屏窗口找回。它不依赖 .NET/Wine-Mono，也不改写
FeatureManager 或视口尺寸，并且不会隐藏致命的前置组件错误。Login Manager 相关根因见
[`docs/login-manager-ui.md`](docs/login-manager-ui.md)。

## 构建

开发机需要 Xcode Command Line Tools，以及两个 Homebrew 构建依赖：

```bash
brew install bison mingw-w64
make app
```

产物位于 `build/app/MacSW.app`。`scripts/make_app.sh` 仍作为 `make app` 的兼容入口。
首次构建需要联网下载固定依赖；校验通过的下载和 Wine 原生模块构建结果缓存在 `dist/`，
相同配置再次构建时会复用。

Builder 分为三层：

- SwiftPM 管理 Swift 模块、原生启动程序和 XCTest；
- 顶层 Makefile 编排依赖获取、原生构建、打包、校验与归档；
- Shell 脚本处理固定依赖下载、Wine autotools 构建和 `.app` 目录装配。

应用、Wine、Wine-Mono、stdole 和 7-Zip 版本及 SHA-256 只在
[`config/versions.env`](config/versions.env) 定义。应用版本独立于 SOLIDWORKS 版本；被验证的
SOLIDWORKS 版本记录在 [`docs/compatibility.md`](docs/compatibility.md)。

常用目标：

```bash
make test                 # SwiftPM XCTest
make app                  # 构建、打包并校验 MacSW.app
make verify               # 校验已有 MacSW.app
make archive              # 生成可上传的 zip（会占用额外磁盘空间）
make ci                   # 测试并生成归档
```

完整打包流程会：

- 编译 SwiftUI 启动程序；
- 从 C 源码重建原生 UI 辅助程序；
- 下载并校验固定版本 Gcenx Wine 运行时；
- 从配置指定的 Wine 官方源码重建打过补丁的 `winemac.so` 与 `win32u.so`；前者修复原生
  图层裁剪和前缓冲刷新，后者提供由 App 为 SOLIDWORKS 单独启用的鼠标捕获兼容路径；
- 覆盖经过验证的 Wine-Mono x86 修复模块、RegistrationServices mscorlib 与 x86/x64 托管 RegAsm；
- 从微软 NuGet 包提取并校验托管 COM 注册所需的 `stdole.dll`；
- 对最终原生模块进行临时签名和校验。

每次构建只保留最终 `MacSW.app`，不会累计保存包含完整 Wine 运行时的旧 App 副本。

`build_winemac.sh` 会按 Wine 版本、源码校验值、三份补丁、配置和构建脚本内容缓存产物。
重建 `win32u.so` 需要 Homebrew 的 Bison 与 FreeType 头文件；打包后的运行时仍使用包内固定的
x86_64 FreeType 动态库，并通过模块内的相对 RPATH 定位，不依赖用户机器上的 Homebrew。
GitHub Actions 使用同一条 `make ci` 构建链路；包内 `BuildManifest.plist` 保存可复核的构建版本、
来源提交和校验值。

## 使用与验证

```bash
open build/app/MacSW.app
```

Apple Silicon 运行包内 x86_64 Wine 需要 Rosetta 2。首次运行在 Bootstrap 窗口中选择安装介质并完成部署；安装完成后的启动默认进入菜单栏并自动启动 SOLIDWORKS。
干净安装会直接清空唯一容器，请确认其中没有需要保留的文件。

图形回归至少应覆盖：

- 新建 Part 后 FeatureManager 完整可见；
- 切换 FeatureManager/PropertyManager 时视口不遮挡左侧面板；
- 进入和退出草图、拉伸、旋转；
- 完整重绘后连续点击空白画布、切换到其他 macOS 窗口，模型仍保持可见；
- 鼠标停在模型边线上时，橙色预选轮廓持续显示到鼠标移开；
- 浮动工具条和对话框显示在视口上方；
- 保存、退出并重新打开零件。

更详细的安装链路和已验证边界见
[`docs/app-wine11-migration.md`](docs/app-wine11-migration.md)，兼容性报告见
[`docs/compatibility.md`](docs/compatibility.md)。

## 日志

日志位于 `~/Library/Application Support/MacSW/logs`，主要包括：

- `install_msi.log`
- `install_msi_errors.log`
- `installer-wine.log`
- `login-manager-install.log`
- `login-manager-wine.log`
- `language-install.log`
- `prerequisites.log`
- `sw_launch.log`
- `ui-daemon.log`

若安装了托管 FlexNet 且服务器列表包含对应的 `端口@localhost`，MacSW 会在启动 SOLIDWORKS 前自动确保该服务运行。
