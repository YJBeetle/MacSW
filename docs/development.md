# MacSW 开发说明

安装与日常使用见 [中文 README](../README.cn.md) / [English README](../README.md)。
这里保留构建、安装实现和兼容性修复细节，不作为全部功能已验收的声明。

## 构建与测试

工具链需要支持 Swift 5.10，并提供 macOS SDK、Xcode Command Line Tools；Wine 构建
依赖 Homebrew 的 Bison 和 MinGW-w64。源码检出时应包含 `Dependencies/SWCLI` 子模块。

```bash
brew install bison mingw-w64
make app
```

产物为 `build/app/MacSW.app`。可直接打开构建产物：

```bash
open build/app/MacSW.app
```

常用目标：

```bash
make test                 # Swift XCTest、SWCLI Python 契约及宿主接线测试
make app                  # 构建、打包并校验 MacSW.app
make verify               # 校验已有 MacSW.app
make archive              # 生成 zip，会占用额外磁盘空间
make ci                   # 测试并生成归档
```

`make test` 的 Python 测试需要 SWCLI 的 `jsonschema` 等依赖。使用隔离环境，避免修改系统 Python：

```bash
python3 -m venv .venv
.venv/bin/python -m pip install ./Dependencies/SWCLI
PATH="${PWD}/.venv/bin:${PATH}" make test
```

首次构建联网获取固定依赖并验证 SHA-256；下载及 Wine 模块构建结果缓存于 `dist/`。
`build_winemac.sh` 的缓存身份包括 Wine 版本、源码校验值、全部补丁、配置及脚本内容。
每次打包只保留最终 `MacSW.app`，不累计保留含完整 Wine 的旧 App 副本。

## 构建职责与依赖固定

- SwiftPM 管理 `MacSWCore`、SwiftUI App、CI 专用入口和 XCTest。
- 顶层 Makefile 编排依赖获取、构建、打包、校验与归档。
- Shell 脚本处理固定依赖下载、Wine autotools 构建和 `.app` 装配。

应用、Wine、Wine-Mono、stdole、7-Zip、SWCLI 和 Python 的版本与校验值位于
[`config/versions.env`](../config/versions.env)。MacSW 应用版本独立于 SOLIDWORKS 版本；
SOLIDWORKS 的实测版本记录在[兼容性报告](compatibility.md)，不作为 Builder 版本选择依据。
SWCLI 子模块 HEAD 必须与 `SWCLI_SOURCE_COMMIT` 的完整提交一致，打包时强制校验。
当前配置的 `0.1.0a5.dev0` 是开发快照，不代表 a5 已正式发布。

SWCLI 的纯 Python 依赖及 macOS ARM64 / Windows AMD64 的 `rpds-py` wheel 固定在
[`config/swcli-wheels.tsv`](../config/swcli-wheels.tsv)，逐个校验并保留许可证、包元数据。
App 内置 SWCLI、Windows Python 3.11、macOS 原生 Python、pywin32 和完整 JSON Schema
依赖；构建时获取、校验和展开，全新安装时一次部署到容器，使用时不联网下载运行时。
普通协议客户端原生运行，只有 `doctor` 和 `daemon` 生命周期命令使用 Wine Windows Python。

完整打包流程包括：

1. 编译 SwiftUI 启动程序，并从 C 源码重建原生辅助程序。
2. 下载、校验固定版本 Gcenx Wine。
3. 从配置指定的官方 Wine 源码构建打过补丁的 `winemac.so`、`win32u.so`、
   x64 `combase.dll` 和 loader。
4. 覆盖已验证的 Wine-Mono x86 修复模块、RegistrationServices mscorlib 和 x86/x64 托管 RegAsm。
5. 从 Microsoft NuGet 包提取、校验托管 COM 注册使用的 `stdole.dll`。
6. 打包两种 Python 运行时、SWCLI 和固定依赖，对原生模块临时签名并校验。

`win32u.so` 构建使用 Homebrew Bison 和 FreeType 头文件；运行时通过相对 RPATH
定位包内固定的 x86_64 FreeType，不依赖最终用户机器上的 Homebrew。
`BuildManifest.plist` 保留构建版本、来源提交与校验值。

## 安装实现

Bootstrap 默认静默部署官方介质：主体 MSI 使用 `/qb` 和已验证属性树；用户可以在设置中
关闭静默，交由官方向导处理。选择介质时只做目录判断与附属扫描，不挂载 ISO 或启动
子进程；挂载推迟到“开始安装”。支持 ISO、`setup.exe`，以及在本级或一级子目录内
含 `setup.exe` / `swwi/data/solidworks.msi` 的目录。开装前校验核心 MSI、
VC++ / Login Manager / .NET 前置件和 Toolbox 载荷。

SOLIDWORKS / Simulation / Motion / MBD 序列号作为 MSI 公共属性传入，不预写注册表。
官方安装器写入 `HKLM\Software\SolidWorks\Licenses\Serial Numbers` 的
`SolidWorks` / `COSMOSWorks` / `COSMOSMotion` / `MBD`；组件范围只由 `ADDLOCAL` 决定。
MSI 详细日志会明文包含序列号属性，必须保持私人。关闭静默时，组件和序列号由官方
向导询问，App 不收集序列号。

附属资源扫描边界：

- 序列号文本只在介质所在目录及一级子目录中查找；只有唯一取值才自动回填，多值留空。
- `.reg` 仅作为读取来源，不导入容器。
- FlexNet 按 `lmgrd.exe` 的存在识别，最多向下两级，不依赖目录名称。
- 这些附属扫描不进入 ISO 内部。

许可配置为单选：不配置、指定服务器地址或托管 FlexNet。选中项输入有效才允许开装；
介质旁唯一 FlexNet 目录会自动填入并选中托管。目录选择时校验 `lmgrd.exe`、唯一
`.lic` 的 `SERVER` 端口及 `VENDOR` 守护进程；压缩包在安装解包后校验。
托管包经校验原子复制到 `C:\opt\FlexNet`，运行时不依赖原始外部目录。

界面语言按 macOS 偏好在固定官方清单中预选，可由用户更改，不扫描介质内部生成清单。
不追加语言资源时使用介质自带英文；语言 MSI 在主体安装完成后静默安装。

安装阶段的 32 位托管辅助程序使用 Wine-Mono 解释器，64 位 SOLIDWORKS 使用 JIT。
App 先校验并放置固定 `stdole`，再安装官方 Login Manager；按注册表内容校验托管 COM
注册，主体 MSI 后再校验 `SldWorks.Application` 的注册链。注册校验或安装器退出码
不能单独证明 COM 激活、宿主就绪或建模成功。字体策略见[字体说明](font-fallback.md)。

## Wine 兼容性修复

补丁保留 SOLIDWORKS 自身窗口几何和硬件加速，不由守护程序移动或缩放视口。

### 视口图层裁剪

原版 `winemac.drv` 没有把 Win32 子窗口可见区域同步给硬件加速视口的 macOS 原生图层，
导致视口覆盖 FeatureManager 等停靠控件。
[`0002-winemac-metal-layer-clipping.patch`](../patches/wine-crossover/0002-winemac-metal-layer-clipping.patch)
从 HDC 读取 `SYSRGN`，转换为视口本地坐标及 Core Animation 遮罩，仅在窗口布局改变时更新。
详见[视口裁剪调查](winemac-opengl-child-clipping.md)。

### 前缓冲刷新

Wine 在应用已调用 `glFlush` / `glFinish` 后，额外调用交换双缓冲的
`NSOpenGLContext.flushBuffer`。SOLIDWORKS 的前缓冲选择、预选与局部 UI 因此在
空白点击或失焦后丢失模型画面，橙色边线预选只闪现。
[`0004-winemac-preserve-front-buffer-flush.patch`](../patches/wine-crossover/0004-winemac-preserve-front-buffer-flush.patch)
将真正的交换限定于 SwapBuffers 路径；证据见[前缓冲说明](opengl-front-buffer.md)。

### 应用身份、捕获与 COM

- [`0001-winemac-macsw-branding.patch`](../patches/wine-crossover/0001-winemac-macsw-branding.patch)
  为 loader 内嵌 MacSW bundle 元数据，由 `wine -> MacSW` 链接满足 Wine 重新执行的固定路径。
  Dock 与应用菜单显示 MacSW，EXE 图标仍走 Wine 原生路径，不替换各程序图标。
- `win32u.so` 提供由 App 为 SOLIDWORKS 单独启用的鼠标捕获兼容路径。
- x64 `combase.dll` 延长 SOLIDWORKS 冷启动时首次 COM 类工厂注册等待，其他 CLSID
  保持原有上限；等待不等于重启或重试建模。补丁范围与云端证据见[运行 CI](runtime-ci.md)。

Wine 及其派生补丁使用 LGPL-2.1-or-later。App 包含许可证与精确源码说明；正式 Release
附带构建所用 Wine 源码归档，仓库保留所有补丁和构建脚本。

## 验证

GitHub Actions 分成两个 job：`build` 分步执行 `make test` 和 `make archive`；
`runtime-test` 依赖构建成功，下载并校验本轮 App 归档及 CI helper，在另一台 runner
执行安装与运行门禁，不重新编译 App。安装／运行失败不改变已成功的构建 job 状态，
但整个工作流仍会失败。`make ci` 保留为开发时合并执行测试与归档的便捷入口。
本仓库 master 的相关 push 自动执行隔离安装与运行门禁，
可手动选择 `verify_solidworks` 和验证阶段；PR / fork 不使用私有资源。
真实安装、缓存恢复、启动、连续建模和尺寸验证分别取证；不使用日常主容器。
共享 CAD 操作与断言由 SWCLI 维护，MacSW 负责宿主准备、真实路径转换和证据收集。
通用建模和尺寸门禁必须在同一 daemon / SOLIDWORKS 实例中顺序执行，不以中途重启绕过失败。
详见[运行 CI](runtime-ci.md)及[兼容性报告](compatibility.md)。

GUI 回归至少覆盖：

- 新建 Part 后 FeatureManager 完整可见。
- FeatureManager / PropertyManager 切换时视口不覆盖左侧面板。
- 进入和退出草图、拉伸、旋转。
- 连续点击空白画布、切换 macOS 窗口后模型仍可见。
- 边线橙色预选持续到鼠标移开。
- 浮动工具条和对话框位于视口之上。
- 保存、退出并重新打开零件。

这些是回归清单，不是本次构建全部通过的声明。
