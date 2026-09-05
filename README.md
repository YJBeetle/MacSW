# SolidWorks 2025 on macOS (Apple Silicon) 实战移植与调优方案

本项目提供了一套在 **macOS (Apple Silicon M系列芯片, macOS 15 Sequoia)** 上，通过 **Wine / CrossOver 26.3.0** 原生转译模式高效运行 **SolidWorks 2025 SP5.0 Premium** 的完整技术方案与复现案例。

无需安装耗费巨量内存与发热严重的 Parallels 虚拟机，即可获得接近原生的 3D 建模渲染体验。

---

## 成果亮点

- ⚡ **纯原生转译，无需虚拟机：** 基于 Rosetta 2 + CrossOver D3DMetal/Wine 转译，极低系统开销，发热与功耗远低于虚拟机方案。
- 🎮 **3D 硬件加速视口：** 基于 macOS Metal 图形驱动直通，零件建模、草图绘制、特征拉伸与视口旋转极其流畅。
- 🌲 **攻克停靠设计树黑屏难题：** 独创 `sw_ui_daemon` 毫秒级动态隔离守护，彻底解决左侧 FeatureManager 设计树黑块、透明穿透、缩放黑屏与标签挤压问题。
- 🔤 **现代微软雅黑中文渲染：** 彻底根除菜单栏与弹窗中文字符豆腐块（`□□`），全界面呈现高品质、抗锯齿的微软雅黑无衬线字体。
- 🚀 **开箱即用一键拉起：** 集成 FlexNet 本地许可自检、字体链接、图形环境变量以及 UI 守护进程，终端单行命令或 CrossOver 图标双击秒启。

---

## 技术架构原理

```
+--------------------------------------------------------------------+
|                    macOS (Apple Silicon M-Series)                  |
|  +--------------------------------------------------------------+  |
|  |             Rosetta 2 (x86_64 -> ARM64 指令动态翻译)          |  |
|  |  +--------------------------------------------------------+  |  |
|  |  |         CrossOver 26.3.0 / Wine 64-bit 运行时环境        |  |  |
|  |  |  +--------------------------------------------------+  |  |  |
|  |  |  | D3DMetal (Direct3D 11 -> Apple Metal API 硬件渲染) |  |  |  |
|  |  |  +--------------------------------------------------+  |  |  |
|  |  |  | FlexNet 本地许可守护进程 (25734@127.0.0.1)        |  |  |  |
|  |  |  +--------------------------------------------------+  |  |  |
|  |  |  | sw_ui_daemon (Win32 GDI 视口与 Metal 视口动态隔离)  |  |  |  |
|  |  |  +--------------------------------------------------+  |  |  |
|  |  |  | SolidWorks 2025 SP5.0 (SLDWORKS.exe 核心工作台)    |  |  |  |
|  |  |  +--------------------------------------------------+  |  |  |
|  |  +--------------------------------------------------------+  |  |
|  +--------------------------------------------------------------+  |
+--------------------------------------------------------------------+
```

---

## 核心难题攻克全过程

### 难题一：左侧 FeatureManager 设计树黑块 / 透明穿透 / 拖动变黑

#### 1. 现象与排查
- 初次运行 SolidWorks 新建零件后，左侧 FeatureManager 设计树处于透明或黑色状态，无法看见基准面、零件节点和沙滩球图标；
- 拖动窗口尺寸或遮挡重绘后，左侧面板完全变黑，且上方 5 个标签栏被严重挤压并出现 `< >` 翻页箭头。

#### 2. 根因深度剖析
1. **Metal 视口与 Win32 GDI 窗口层叠冲突：** SolidWorks 的 3D 主视口依托 macOS `CAMetalLayer` 进行 60 FPS 硬件刷新。原先 MDI 视口起点位于 `x=55`，直接覆盖了位于 `x=0~240` 的左侧 MFC 停靠面板。由于 Wine 无法跨 Cocoa Metal 图层对 GDI 子控件做精准矩形裁剪，Metal 刷新时会持续擦除底层 GDI 树形控件；
2. **MFC 双缓冲变黑：** MFC 停靠面板默认设置了 `WS_EX_COMPOSITED` 扩展样式，Wine 的驱动层在处理分层合成窗口时产生双缓冲渲染死黑；
3. **主题引擎异常：** Wine 内置的 `uxtheme` 在处理 `SysTreeView32` 和 `SysTabControl32` 时存在绘制退化。

#### 3. 创新解决方案：`sw_ui_daemon` 动态隔离引擎
编写专用守护进程 [`scripts/sw_ui_daemon.cs`](file:///Volumes/Data/Workspace/WineSW/scripts/sw_ui_daemon.cs)（已预编译为 [`sw_ui_daemon.exe`](file:///Volumes/Data/Workspace/WineSW/scripts/sw_ui_daemon.exe)），在 SolidWorks 启动后作为常驻后台服务：
- **强制扩展面板尺寸：** 将左侧 `Tree Container Wnd` 宽度精准锁定为 **310px**（与真实 Windows 一致），完整展开 5 个选项卡（设计树、属性、配置、外观 DisplayManager 沙滩球），杜绝翻页箭头；
- **动态视口左边界隔离：** 毫秒级监测并修正右侧 3D 绘图区起点为 `x=310`，窗口缩放或拖拽时无缝同步，让 Metal 渲染层与左侧 GDI 面板物理分离；
- **剥离合成样式：** 动态侦测并剥除相关窗口的 `WS_EX_COMPOSITED` 样式，消除 Wine 双缓冲黑块；
- **还原原生经典绘制：** 调用 `SetWindowTheme(hwnd, " ", " ")` 将树形控件与选项卡重置为原生经典绘制，所有图标与节点即刻正常清晰显示。

---

### 难题二：菜单栏、新建弹窗说明与按钮中文豆腐块（`□□`）

#### 1. 现象与排查
- 下拉菜单中的“新建(N)...”以及新建弹窗中的“零件”、“装配体”、“工程图”能正常显示中文；
- 但顶部菜单栏（`□□(F)  □□(V)  □□(T)`）、弹窗下方的详细描述（`...3D...`）以及确定/取消按钮全部显示为方块 `□□`。

#### 2. 根因深度剖析
1. **纯西文字体缺乏字形与 Fallback：** 顶部菜单栏和按钮使用的是 Windows 系统字体 **`Segoe UI`** 和 **`Tahoma`**。容器的 Fonts 目录下物理存在纯西文的 `segoeui.ttf`，且 macOS 自带纯西文的 `Tahoma.ttf`。Wine 发现磁盘上物理存在该字体时直接加载，但因缺少中文字形且 Wine 没有 Windows 原生 DirectWrite 的动态 Fallback，所有汉字全变豆腐块；
2. **注册表字族名称误差：** 在 `msyh.ttc` 中，标准字体族名为 **`Microsoft YaHei UI`**（带 `UI`）或中文名称 **`微软雅黑`**。若注册表错写为 `Microsoft YaHei`，Wine 查无此字便会回退至纯西文 Arial。

#### 3. 解决方案：字体软链接重定向 + 注册表精确映射
- **建立物理层软链接：** 在 [`scripts/setup_fonts.sh`](file:///Volumes/Data/Workspace/WineSW/scripts/setup_fonts.sh) 中，将字体目录下的 `segoeui*.ttf` 和 `tahoma*.ttf` 直接软链接至 `msyh.ttc`（微软雅黑）。这样无论 Win32 控件以何种字符集调用 `Segoe UI` 或 `Tahoma`，物理加载的都是自带全套中西文的高清微软雅黑字形；
- **完善注册表重定向：** 将 `FontSubstitutes`、`FontLink/SystemLink` 和 Wine `Replacements` 全部规范配置至 `Microsoft YaHei UI`；
- **环境多字节模式：** 在启动脚本导出 `LANG=zh_CN.UTF-8` 与 `LC_ALL=zh_CN.UTF-8`，确保转译层全面运行于 UTF-8 多字节环境。

---

### 难题三：保存提示弹窗 CommandLink 按钮方块字（`保存文档(S)` / `不保存(N)`）

#### 1. 现象与排查
在常规界面汉化完成后，关闭未保存零件时触发的「保存修改过的文档」对话框中：
- 窗口标题、说明正文、底部「显示详情」与「取消」按钮均能完美显示中文；
- 唯独中间两个核心命令按钮出现豆腐块：`-> □□□□(S)` 与 `-> □□□(N)`。

#### 2. 根因深度剖析
1. **TaskDialog CommandLink 专用字重机制：** Windows Vista/7/10/11 的 TaskDialog（任务对话框）中，CommandLink 大按钮的主标题硬编码调用了 **`Segoe UI Semibold`**（半粗体，对应物理字体文件为 `seguisb.ttf` / `seguisbi.ttf`）；
2. **应用程序私有字体劫持：** SolidWorks 程序安装目录下（`Program Files/SOLIDWORKS Corp/SOLIDWORKS/`）物理打包了纯西文的 `segoeui.ttf`。根据 Win32 动态链接库与资源加载优先级，当前工作目录优先级高于系统 Windows 目录，导致 SolidWorks 进程优先强行加载了其自带的西文字体。

#### 3. 解决方案
- **扩展 Segoe UI 全套字族软链接：** 在 [`scripts/setup_fonts.sh`](file:///Volumes/Data/Workspace/WineSW/scripts/setup_fonts.sh) 中将 `seguisb.ttf`（半粗体）、`seguisbi.ttf`（粗斜体）、`seguibl.ttf`（特粗体）全套映射至 `msyhbd.ttc`（微软雅黑粗体）；
- **覆盖 SolidWorks 本地纯西文字体：** 脚本自动检测并用 `msyh.ttc` 替换 SolidWorks 程序目录下的 `segoeui.ttf`，彻底根除私有字体劫持。

---

### 深度剖析：macOS 下 3D 视口（Metal / CAMetalLayer）与 Win32 GDI 跨图层重叠原理

在排查界面渲染遮挡时，我们发现一个底层核心架构问题：**“舞台（3D 视口）遮盖了上层/同层控件”**。

#### 1. 为什么 Win32 原生的窗口裁剪机制失效？
* 在真实 Windows 上，DirectX 视口与 Win32 GDI 控件（如 Ribbon 标签栏、停靠面板）都在桌面窗口管理器（DWM）的管理下，可以通过 `WS_CLIPSIBLINGS`（兄弟窗口裁剪）在像素着色阶段进行遮挡剔除；
* 但在 macOS + Wine (CrossOver D3DMetal/DXVK) 环境下，3D 视口被映射为 macOS 原生 GPU 硬件加速的 **`CAMetalLayer`**，而 GDI 控件是由 CPU/2D 渲染的 AppKit 图层；
* macOS CoreAnimation 合成器中，`CAMetalLayer` 是一个独立的高优先级直接渲染表面，**无法感知 Win32 的 GDI 裁剪矩形（HRGN）**。任何几何重叠，Metal 都会以 60 FPS 强行覆盖底层 GDI 画面。

#### 2. 可选的解决方案对比：
1. **几何坐标边界硬隔离（本方案采纳，零开销最佳实践）：**
   通过 `sw_ui_daemon` 限制 3D 视口的几何位置，使其在 X 轴与 Y 轴上永远不与 Ribbon 或左侧面板重叠（`X >= 310, Y >= Ribbon.Bottom`）。既保留 Metal 硬件满血性能，又杜绝遮盖冲突；
2. **macOS 驱动层 CALayer 层级排序（系统级方案）：**
   修改 Wine `macdriver`，使所有 GDI 子窗口也生成独立的 `CALayer` 并设置更高的 `zPosition`，但会增加合成器负担并可能引发重绘撕裂；
3. **软件 OpenGL 模式（回退方案）：**
   在 SolidWorks 选项中勾选“使用软件 OpenGL”，视口退化为纯 CPU 2D 贴图，虽彻底解决跨图层问题，但会完全损失 Apple Silicon M2 Max GPU 硬件加速。

---

### 常见问答：能否直接使用 macOS 苹果原生字体（如苹方 PingFang）？

* **苹方（PingFang SC）无法直接使用：**
  macOS 的 `PingFang.ttc` 是 Apple 专有字体，重度依赖 Apple AAT 与特有字符表，**缺少 Windows GDI 必须的 TrueType Windows Unicode cmap 表（Platform ID 3）**。在 Wine/FreeType 下直接加载会导致字符全空或方块甚至 GDI 崩溃；
* **华文黑体（STHeiti）可用：**
  `/System/Library/Fonts/STHeiti Light.ttc` 具备标准 Windows cmap，Wine 可以识别，但字形较旧，高清屏美观度不如现代字体；
* **思源黑体（Source Han Sans）与微软雅黑（当前方案）：**
  跨平台 OpenType 标准字体，与 Wine FreeType 完全兼容。当前默认选用的 **`Microsoft YaHei UI`** 在字宽与行高上与 SolidWorks 原生 Windows 界面对齐度最高，布局最为协调。

---

## 目录结构说明

```
WineSW/
├── run_sw.sh                       # 🚀 一键拉起 SolidWorks 2025 主入口
├── scripts/
│   ├── init_bottle.sh              # 容器创建与软链接初始化
│   ├── setup_filesystem.sh         # 虚拟驱动器与 Windows 目录映射
│   ├── import_registry.sh          # 核心注册表与许可配置导入
│   ├── register_components.sh      # COM 组件与关键 DLL 注册
│   ├── manage_license.sh           # FlexNet 许可服务管理守护 (start/stop/status)
│   ├── setup_fonts.sh              # 字体软链接与 CJK 映射初始化
│   ├── apply_msyh_fixed.reg        # 微软雅黑 UI 注册表配置方案
│   ├── restore_stsong.reg          # 经典宋体 (STSong) 安全回退方案
│   ├── sw_ui_daemon.cs             # ⭐️ UI 视口隔离守护进程源码
│   ├── sw_ui_daemon.exe            # UI 守护进程预编译可执行文件
│   ├── create_shortcut.vbs         # 生成 Windows 桌面快捷方式脚本
│   └── diagnostics/                # 🔬 研发排查探针工具集
│       ├── test_gdi_text.cs        # GDI 真实字形离屏渲染测试
│       ├── inspect_dialog.cs       # 弹窗与控件树递归探针
│       ├── inspect_menubar_font.cs # 菜单栏字体度量探针
│       ├── check_overlap.cs        # 视口与控件坐标重叠监测
│       └── ...
└── .gitignore                      # 规则排除临时数据与中间产物
```

---

## 完整复现与部署指南

### 第一步：准备运行环境

1. **操作系统：** macOS 15+ (Sequoia), Apple Silicon (M1/M2/M3/M4 系列)；
2. **转译工具：** 安装 [CrossOver](https://www.codeweavers.com/crossover) 24+ 或 26+；
3. **SolidWorks 安装介质：** 准备已预装或抽取的 SolidWorks 2025 SP5.0 程序目录（包含 `Program Files/SOLIDWORKS Corp` 与 `SolidSQUAD` 许可文件）。

### 第二步：初始化容器与环境配置

在终端进入本项目工作目录，执行以下步骤：

```bash
# 1. 初始化 64 位 Windows 10 Bottle
./scripts/init_bottle.sh

# 2. 映射程序文件与运行库虚拟目录
./scripts/setup_filesystem.sh

# 3. 导入注册表与许可环境配置
./scripts/import_registry.sh

# 4. 注册核心 COM 组件
./scripts/register_components.sh

# 5. 配置微软雅黑中文字体软链接
./scripts/setup_fonts.sh
```

### 第三步：一键运行 SolidWorks 2025

执行项目根目录的一键启动脚本：

```bash
./run_sw.sh
```

脚本将依次自动完成：
1. 检测并后台拉起 FlexNet 许可守护进程（监听 `127.0.0.1:25734`）；
2. 校验并确保微软雅黑中文字体软链接就绪；
3. 注入 CrossOver D3DMetal、DXVK 及原生 VC++ 运行库重载；
4. 后台启动 `sw_ui_daemon` 视口隔离守护程序；
5. 拉起 `SLDWORKS.exe` 进入主界面。

> [!TIP]
> 也可以在 CrossOver 主界面中直接双击生成的 **`SOLIDWORKS 2025`** 官方快捷图标启动！

---

## 常见问题与维护提示

1. **如何验证中文字体渲染状态？**
   可使用我们编写的 GDI 探针快速测试并输出位图：
   ```bash
   wine "C:\\windows\\Microsoft.NET\\Framework64\\v4.0.30319\\csc.exe" /nologo /r:System.Drawing.dll /r:System.Windows.Forms.dll /out:scripts/diagnostics/test_gdi_text.exe scripts/diagnostics/test_gdi_text.cs
   wine scripts/diagnostics/test_gdi_text.exe
   ```
2. **如果想切回系统默认的宋体风格？**
   在终端执行：
   ```bash
   export CX_ROOT="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
   "${CX_ROOT}/bin/wine" regedit "Z:\\Volumes\\Data\\Workspace\\WineSW\\scripts\\restore_stsong.reg"
   ```
3. **许可服务状态排查：**
   随时使用管理脚本查询许可健康状态：
   ```bash
   ./scripts/manage_license.sh status
   ```
