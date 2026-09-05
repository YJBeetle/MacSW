# 路径 1：SolidWorks 浮动窗口/属性面板提权与原生图层独立化实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 在不修改 Wine 源码的前提下，通过 UI 守护进程对 SolidWorks 的浮动工具栏、面板（`XTPDockingPaneMiniWnd`、`CMiniDockFrameWnd`）及弹出菜单进行 Win32 样式提权（`WS_EX_TOOLWINDOW | WS_EX_TOPMOST` 并设父窗口为桌面），促使 Wine 的 `winemac.drv` 为其创建独立的 Cocoa `NSWindow`（`NSFloatingWindowLevel`），彻底解决 macOS 下硬件 3D 视口（`CAMetalLayer`）遮挡浮动 UI 的图层优先级冲突；同时提供一键找回遗失/被遮挡浮动面板的重置恢复机制。

**架构：** 
- 利用 Wine `winemac.drv` 的窗口映射机制：当 Win32 窗口的父窗口是桌面且带有 `WS_EX_TOPMOST` 时，Wine 会自动在 Cocoa 端调用 `create_cocoa_window` 并赋予 `NSFloatingWindowLevel`。
- 扩展 `scripts/sw_ui_daemon.cs`：
  1. 进程级扫描（基于 `GetWindowThreadProcessId`），拦截 SolidWorks 进程所拥有的所有顶层与弹出窗口（`WS_POPUP`、`MiniWnd`、`MiniFrame`）；
  2. 动态提升浮动窗口为 Desktop 顶层无所有者/工具窗口，注入 `WS_EX_TOPMOST | WS_EX_TOOLWINDOW`；
  3. 增加“面板安全回归”逻辑：若浮动面板坐标落在 3D 视口死角或被移出屏幕，自动将其复位到可见区域；
  4. 保持 CommandLink 对话框字体修复与停靠区自适应避让协同工作。

**技术栈：** C# / Win32 P/Invoke, Wine winemac.drv, macOS CoreGraphics / Swift (验证探针).

---

### 任务 1：创建浮动窗口识别与提权验证探针（TDD 测试）

**文件：**
- 创建：`scripts/diagnostics/test_floating_elevation.cs`
- 测试：`scripts/diagnostics/test_floating_elevation.cs`

- [ ] **步骤 1：编写失败的测试探针代码**
  编写测试工具，枚举 SolidWorks 进程拥有的所有子窗口/弹出窗口，检查其当前的 ClassName、Style、ExStyle、Parent、Rect 以及在 macOS Quartz 中的对应 Layer。
- [ ] **步骤 2：运行测试探针，确认未提权状态**
  使用 Wine 编译并运行探针，观察当前所有浮动/弹出窗口的 ExStyle 是否缺少 `WS_EX_TOPMOST`。
- [ ] **步骤 3：在探针中验证提权 API 组合有效性**
  验证 `SetParent(hWnd, GetDesktopWindow())` 与 `SetWindowPos(HWND_TOPMOST)` 是否能成功使 Cocoa 端产生高 Layer（>0）的独立 `NSWindow`。
- [ ] **步骤 4：运行 Swift 探针验证 macOS WindowServer 图层**
  运行 `swift scratch/list_mac_windows.swift` 确认独立窗口的 `Layer` 大于 0。
- [ ] **步骤 5：Commit 测试探针**
  `git commit -m "test(floating): add diagnostic probe for floating window elevation"`

---

### 任务 2：升级 `sw_ui_daemon.cs` 实现进程级浮动窗口自动提权与失踪面板寻回

**文件：**
- 修改：`scripts/sw_ui_daemon.cs`
- 产物：`scripts/sw_ui_daemon.exe`

- [ ] **步骤 1：在 `sw_ui_daemon.cs` 中增加进程过滤与顶层/浮动窗口扫描**
  - 引入 `GetWindowThreadProcessId`，只处理属于 `SLDWORKS.exe` 的窗口；
  - 在 `EnumWindows` 全局枚举循环中，不仅处理标题包含 `SOLIDWORKS` 的主窗口，还要处理属于该进程的所有弹出/浮动窗口（类名包含 `XTPDockingPaneMiniWnd`、`MiniFrame`、`SysFloatToolBar` 或带有 `WS_POPUP` 的工具窗）；
- [ ] **步骤 2：实现安全提权机制**
  - 如果未设置 `WS_EX_TOOLWINDOW` 或 `WS_EX_TOPMOST`，则赋予这两个扩展样式；
  - 如果其父窗口不是桌面，调用 `SetParent(h, GetDesktopWindow())` 触发 Wine 创建独立的 Cocoa `NSWindow`；
  - 调用 `SetWindowPos(h, HWND_TOPMOST, ..., SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE)`；
- [ ] **步骤 3：增加被遮挡/遗失面板位置自动校准（找回功能）**
  - 针对被用户拖入视口内部或屏幕外的浮动面板，检测其坐标，如果完全脱离屏幕工作区，重置其坐标至主窗口客户区中心偏上（700, 200）；
- [ ] **步骤 4：编译 `sw_ui_daemon.exe` 并平滑热替换守护进程**
  - 停止当前运行的 PID 17809，重新编译，并在后台启动新版守护进程；
- [ ] **步骤 5：Commit 守护进程升级**
  `git commit -m "feat(daemon): implement process-wide floating window elevation and rescue (path 1)"`

---

### 任务 3：端到端与视觉验证

**文件：**
- 测试：`scripts/diagnostics/test_floating_elevation.cs`
- 验证脚本：`scratch/list_mac_windows.swift`
- 截图：`scratch/path1_floating_verified.png`

- [ ] **步骤 1：运行 Swift 探针验证 macOS 独立 NSWindow 存在与 Layer 提升**
- [ ] **步骤 2：对当前 SolidWorks 双文档窗口进行屏幕截图**
- [ ] **步骤 3：验证用户界面中浮动面板与 3D 视口重叠时的图层关系，确认绝无裁剪遮盖**
- [ ] **步骤 4：记录验证结果至 walkthrough.md**
- [ ] **步骤 5：Commit 验证代码与最终文档**
