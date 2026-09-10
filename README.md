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

### 故障排查：编辑草图时 3D 视口黑屏（Sketch Mode Black Screen）深度剖析与修复

#### 1. 现象描述
在零部件空闲/正常查看状态下 3D 视口渲染正常，但一旦进入“草图绘制 / 编辑草图”模式，整个 3D 舞台区域瞬间全黑，退出草图后恢复正常。

#### 2. 根因深度剖析
1. **SolidWorks 动态属性停靠栏机制：**
   当用户点击“草图绘制”时，SolidWorks 会在文档 MDIFrame（`mdiDoc`）下动态实例化一个属性管理器停靠容器 **`DVEDockedContainer`**（包含 `uiVisualSketchEditorView_c` 与 `Dve sheet`）。
2. **UI 守护进程（`sw_ui_daemon`）误判：**
   原守护进程在隔离 3D 视口与特征树时，仅依据尺寸条件（`sibW > 300 && sibH > 300 && overlapping`）遍历兄弟窗口，将刚创建的 `DVEDockedContainer` 误判为 3D 视口；
3. **视口遮挡全黑：**
   守护进程将 `DVEDockedContainer` 强制移动并放大到视口区域（`X = 310, W = clientWidth - 310`），而 `DVEDockedContainer` 内部挂载了尺寸高达 `10000x10000` 且背景全黑的不透明 `Dve sheet` 底板，导致其完全覆压在真正的 3D 视口（`AfxMDIFrame140u`）之上，造成草图模式下视口全黑。

#### 3. 彻底修复方案
在 [`scripts/sw_ui_daemon.cs`](file:///Volumes/Data/Workspace/WineSW/scripts/sw_ui_daemon.cs) 中实现严格的窗口类名与语义类型过滤：
* **3D 视口主容器（`AfxMDIFrame140u`）：** 保持在右侧舞台区域（`X = DESIRED_PANEL_WIDTH, W = rDocClient.Right - DESIRED_PANEL_WIDTH`），与 CAMetalLayer 硬件加速视口物理隔离；
* **所有停靠栏与属性页（`DVEDockedContainer` / `AfxFrameOrView140u`）：** 严格限制在左侧停靠区（`X = 0, W = DESIRED_PANEL_WIDTH`），绝不拉伸至 3D 视口区。

修复后，草图几何线条（圆/椭圆/直线等）、坐标轴系、尺寸标注与左侧属性管理器完全同步显示，视口保持流畅的硬件渲染。

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
├── macos/                          # 🍎 原生 macOS Bootstrap App (SwiftUI)
│   ├── Bootstrap/                  # App 核心源码 (状态机、许可服务、Wine桥接)
│   └── Resources/                  # 图标、元数据与静态资源
├── scripts/
│   ├── make_app.sh                 # 📦 自动化独立 App 打包流水线
│   └── build_wine.sh               # 🍷 x86_64 Wine-crossover 定制构建脚本
├── patches/                        # 🛠️ MacSW 专属 Wine 核心补丁集
├── run_sw.sh                       # 终端开发者底层调试启动脚本
└── .github/workflows/              # 🚀 自动化 CI/CD 构建流水线
```

---

## 快速启动与部署指南

### 一键开箱即用（推荐）

1. **打包生成原生 App：**
   ```bash
   ./scripts/make_app.sh
   open build/app/MacSW.app
   ```
2. **在向导中完成部署：**
   - 拖入 SolidWorks 安装介质（ISO 镜像或解压目录）；
   - 向导自动识别并装配许可服务、网络注册表与组件补丁；
   - 点击「开始部署」，向导将全程自动化完成环境准备、官方向导运行、补丁注入与 WPF 运行库补齐；
   - 部署就绪后，直接在控制台点击「启动 SolidWorks」即可原生运行！

### 终端开发者调试启动

若需在终端进行底层调试，可直接执行：

```bash
./run_sw.sh
```

脚本将自适应使用 MacSW 内置 Wine，并自动校验本地 FlexNet 许可服务与 UI 守护进程状态。

---

## 常见问题与维护提示

1. **为什么绝对不能开启“使用软件 OpenGL”？**
   - SolidWorks 2025 的现代视口重度依赖 OpenGL 4.5 与现代着色器流管线；
   - macOS 官方自 2018 年已全面弃用 OpenGL，在 Apple Silicon（ARM64 + Rosetta 2）转译环境下，Wine 内置的 CPU 软件渲染器会触发多线程自旋锁（Spinlock）死锁，导致主线程无响应卡死、COM 服务挂起；
   - 必须保持默认硬件加速（通过 D3DMetal / MoltenVK 转译），切勿在选项中开启软件 OpenGL。

2. **属性管理器（PropertyManager）展开被 3D 视口遮挡与 CommandLink 方块字解决：**
   - **属性栏避让：** SolidWorks 支持在左侧特征树旁并排展开属性面板（`DVEDockedContainer`）。`sw_ui_daemon` 已升级智能感知，自适应计算所有左侧停靠面板的实际右边界 `maxDockRight`，确保 3D 视口自动避让，永不遮盖属性栏；
   - **CommandLink 方块字根治：** Windows 任务对话框及 OLE 挂起对话框的 CommandLink 按钮默认调用了旧版主题的 `Tahoma` 字体（缺少 CJK 字形）。`sw_ui_daemon` 自动检测并剥离旧主题、注入 `Segoe UI Semibold` 中文字体，彻底根治方块字现象。

3. **浮动面板/工具条与弹出对话框原生图层提权（路径 1 核心机制）：**
   - **架构机理：** 传统 Wine 下子窗口（GDI）无法穿透覆盖 macOS 原生硬件视口（`CAMetalLayer`）。路径 1 方案免改 Wine 源码，通过守护进程将所有浮动工具栏（如“2D 到 3D”）、Docking 面板与弹出对话框（`#32770`）赋予 `WS_EX_TOOLWINDOW | WS_EX_TOPMOST` 样式，并将父窗口指向系统桌面；
   - **原生图层提升：** Wine `winemac.drv` 驱动在接收到该 Win32 状态后，自动在 macOS 端创建独立的 Cocoa `NSWindow` 并配置为 `NSFloatingWindowLevel`（Layer 21）。在 WindowServer 层面超越 3D 视口（Layer 0），实现任意拖拽浮动均保持在最前；
   - **失踪面板寻回：** 若用户将面板拖动到屏幕盲区或异常视口死角，`sw_ui_daemon` 会自动检测并安全复位其屏幕坐标至可见安全区（X=700, Y=200）。

4. **许可服务状态排查：**
   在 MacSW 控制台仪表盘中可直接查看「FlexNet 许可服务」实时指示灯，或在终端通过 `nc -z 127.0.0.1 25734` 快速检测端口连通性。

