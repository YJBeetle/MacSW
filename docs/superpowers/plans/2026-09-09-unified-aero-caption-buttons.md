# 基于 DrawFrameControl 拦截的 SolidWorks Aero 标题栏按钮渲染实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development 或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 在 SolidWorks 2025 运行进程内拦截 `DrawFrameControl(DFC_CAPTION)` 调用，以 Windows 7 Aero 规格原生渲染最小化、还原与关闭三个子窗口控制按钮，与左侧自绘的 `[ <| ] [ |> ]` 达到 100% 视觉风格与交互统一（平滑渐变、无毛玻璃、珊瑚红关闭键）。

**架构：** 在常驻守护进程 [`scripts/sw_ui_daemon.cs`](file:///Volumes/Data/Workspace/WineSW/scripts/sw_ui_daemon.cs) 中集成 Aero Caption Hook 引擎。守护进程定位 `SLDWORKS.exe` 进程，在其中分配专用内存段并写入经过 Clang 精确编译的 Windows x64 ABI 高性能 GDI Aero 渲染例程，同时将 `DrawFrameControl` 入口原子重定向至该例程。当检测到 `DFC_CAPTION` 时，直接在 SolidWorks 传入的 `HDC` 与 `RECT` 中渲染双层高光天蓝/珊瑚红渐变及矢量投影图标，其它普通控件继续调用原函数。

**技术栈：** Win32 GDI / GDI+（`GradientFill`、`RoundRect`、`CreatePen`）、x86-64 机器码注入与原子跳板（Trampoline Hooking）、C# .NET 4.0（`sw_ui_daemon` 进程守护与内存调度）、macOS Swift/CoreGraphics（自动化无干扰屏幕验证）。

---

## 视觉设计与色彩参数规范（提取自用户提供的 Windows 7 实机截图）

| 按钮类型 | 尺寸规范 | 外边框 (1px) | 内侧顶/侧高光 (1px) | 上段 45% 光泽渐变 | 下段 55% 柔和底色渐变 | 图标造型与色彩 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **最小化 `[ - ]` (Normal)** | 高 21px, 宽 ~26px, 圆角 2px | `#677C96` (103, 124, 150) | `#C5CFDD` (197, 207, 221) | `#C5DFFA` → `#BFD3E6` 浅冰蓝 | `#B2CCE7` → `#D4E4F4` 天蓝光泽 | 水平横杠 (8×2px), 深石板灰 `#454D5B`, 下方 1px 纯白底光 `#FFFFFF` |
| **还原/最大化 `[ 口 ]` (Normal)** | 高 21px, 宽 ~26px, 圆角 2px | `#677C96` (103, 124, 150) | `#C5CFDD` (197, 207, 221) | `#C5DFFA` → `#BFD3E6` 浅冰蓝 | `#B2CCE7` → `#D4E4F4` 天蓝光泽 | 双层/单层方框 (8×8px, 1px 线宽), 深石板灰 `#454D5B`, 下方 1px 纯白底光 |
| **关闭 `[ X ]` (Normal)** | 高 21px, 宽 ~30px, 圆角 2px | `#513242` (81, 50, 66) | `#D0AAA7` (208, 170, 167) | `#F1B6AB` → `#E9A699` 珊瑚暖红 | `#D17C6C` → `#B26357` 茜红/酒红 | 细腻 45° 交叉叉号 (8×8px), 纯白 `#FFFFFF`, 下方 1px 深暗酒红微阴影 `#401010` |
| **悬停态 (Hover / Hot)** | 相同几何 | 更加鲜亮蓝 / 鲜红 `#D81A1A` | 增强反光白 | 提升明度 15% | 更加清透鲜艳 | 图标微幅提亮 |
| **按下态 (Pressed / Pushed)** | 相同几何 | 深海蓝 `#3D5A75` / 暗深红 `#800808` | 内凹微暗边 | 倒转渐变（上暗下亮，呈现内凹立体质感） | 呈现微幅阴影 | 图标向右下微移 1px |

---

## 涉及文件与职责划分

1. [`scripts/sw_aero_hook.c`](file:///Volumes/Data/Workspace/WineSW/scripts/sw_aero_hook.c) [新建]
   - 核心 C 语言 Hook 实现：负责解析 `DrawFrameControl(HDC hdc, LPRECT lprc, UINT uType, UINT uState)`；
   - 包含双段线性渐变算法（GDI `GradientFill` / `TRIVERTEX`）、圆角外框绘制与防锯齿矢量符号绘制；
   - 当 `uType == 1 (DFC_CAPTION)` 时，分流处理 `DFCS_CAPTIONCLOSE`、`DFCS_CAPTIONMIN`、`DFCS_CAPTIONRESTORE`；
   - 当 `uType != 1` 时，透传给原生 `DrawFrameControl` 跳板函数。
2. [`scripts/build_hook.py`](file:///Volumes/Data/Workspace/WineSW/scripts/build_hook.py) [新建]
   - 编译与提取脚本：在 macOS 宿主机使用 `clang -arch x86_64 -O2 -fno-asynchronous-unwind-tables` 编译为独立纯机器码二进制块（Blob）及重定位元数据。
3. [`scripts/sw_ui_daemon.cs`](file:///Volumes/Data/Workspace/WineSW/scripts/sw_ui_daemon.cs) [修改]
   - 扩展现有 UI 守护进程，新增 `AeroCaptionHookManager` 模块；
   - 负责检测 `SLDWORKS.exe` 进程并挂钩：通过 `VirtualAllocEx` 注入渲染代码块，填入 `user32.dll` / `gdi32.dll` / `msimg32.dll` API 指针表；
   - 负责设置 `user32.dll!DrawFrameControl` 64-bit Trampoline 跳转，并在进程生命周期内维持 Hook 稳定。
4. [`run_sw.sh`](file:///Volumes/Data/Workspace/WineSW/run_sw.sh) [保留验证]
   - 确认守护进程随 SolidWorks 自动启动，无需人工操作。

---

## 任务拆解与实施步骤

### 任务 1：编写与编译 Windows 64-bit Aero 标题栏自绘例程

**文件：**
- 创建：`scripts/sw_aero_hook.c`
- 创建：`scripts/build_hook.py`
- 测试：`scripts/test_hook_blob.py`

- [ ] **步骤 1：编写 C 源码 `scripts/sw_aero_hook.c`**
  包含独立的 `API_TABLE` 结构（包含 `GradientFill`, `CreateSolidBrush`, `CreatePen`, `SelectObject`, `DeleteObject`, `RoundRect`, `BitBlt`, `LineTo`, `MoveToEx`, `DrawFrameControl_Original` 等），编写完整的高光渐变、外框与矢量图标渲染。
- [ ] **步骤 2：编写编译脚本 `scripts/build_hook.py`**
  使用 macOS `clang -arch x86_64 -O2` 将 C 源码编译为独立的机器码字节数组（`.bin`），生成嵌入 C# 使用的 hex 字符串。
- [ ] **步骤 3：验证机器码与 ABI 正确性**
  运行 `python3 scripts/build_hook.py`，检查输出的反汇编代码确保无绝对重定位依赖（RIP-relative 或通过 context 指针访问 API 表）。

---

### 任务 2：在 `sw_ui_daemon.cs` 中实现进程注入与 Hook 管理

**文件：**
- 修改：`scripts/sw_ui_daemon.cs`
- 测试：`scripts/diagnostics/test_inject_hook.cs`

- [ ] **步骤 1：编写独立注入测试探针 `test_inject_hook.cs`**
  在独立测试程序中验证 `VirtualAllocEx`、`WriteProcessMemory` 以及 `DrawFrameControl` 14 字节跳板的挂载与卸载逻辑。
- [ ] **步骤 2：测试热挂载并触发重绘**
  对当前已在运行的 SolidWorks 实例执行挂载，向主窗口发送重绘通知，确认未发生崩溃且 hook 生效。
- [ ] **步骤 3：将 Hook 逻辑集成进 `scripts/sw_ui_daemon.cs`**
  在守护进程的轮询监控主循环中加入 Hook 状态检测：若未挂载则执行原子注入；若已挂载则保持保活。
- [ ] **步骤 4：编译并更新 `sw_ui_daemon.exe`**
  使用 Wine .NET csc 编译生成全新的 `sw_ui_daemon.exe`。

---

### 任务 3：像素级对齐与全交互验证

**文件：**
- 验证截图：`scratch/aero_buttons_verified.png`
- 验证对比：`scratch/aero_vs_realwin_comparison.png`

- [ ] **步骤 1：全分辨率窗口截图截取**
  使用 Swift / CoreGraphics 截取 SolidWorks 主窗口（Window 51535），裁剪出 CommandManager 右侧 5 个按钮区域。
- [ ] **步骤 2：像素级色差与圆角对齐检查**
  编写 Python 脚本测量并对比生成的按钮与用户参考图：
  - 按钮外边框颜色误差（Delta E < 5）；
  - 渐变色过渡平滑度；
  - 关闭按钮纯白叉号矢量居中与红底光泽；
  - 确认 Win95 灰块与黑点点阵彻底消失。
- [ ] **步骤 3：功能交互测试**
  通过鼠标模拟或人工点击测试：
  - 点击最小化：子文档正常最小化；
  - 点击还原：子文档正常还原窗口模式；
  - 点击关闭：子文档正常弹出保存提示或安全关闭。

---

## 验证与验收标准

1. **外观一致性**：
   - 右侧 `[ - ] [ 口 ] [ X ]` 彻底告别 Windows 95 凸起方块；
   - 与左侧 `[ <| ] [ |> ]` 浑然一体，拥有相同的冰蓝光泽渐变底板、灰蓝细边框、微圆角及柔和白高光；
   - 关闭键为高级典雅的珊瑚暖红/茜红高光，中间为高清晰纯白叉号。
2. **交互完整性**：
   - 鼠标悬停（Hover）有正常高亮反馈；
   - 点击（Pressed）有内凹质感反馈；
   - 点击最小化、还原、关闭功能 100% 正常响应。
3. **零侵入与自动化**：
   - 随 `./run_sw.sh` 守护进程自动常驻运行，用户今后重启无需任何手动干预。
