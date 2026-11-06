# macOS 显示器热插拔

2026-11-06 在三屏环境完成真实拔下和接回对照。旧 Wine 11.16 的普通窗口没有收到
WM_DISPLAYCHANGE，虽然定时查询的显示器数量和虚拟桌面大小发生变化。
因此应用用于重新安排窗口、最大化和定位对话框的通知路径缺失。

0021-winemac-refresh-display-topology.patch 在桌面所属线程刷新缓存后，
异步向顶层窗口广播当前主显示器的尺寸和色深。激活某个进程引发的同步仍只刷新缓存。
Cocoa 的 applicationDidChangeScreenParameters: 也复用现有刷新入口，
在 AppKit 更新 NSScreen 后重新失效主屏高度和坐标缓存。

## 验证

| 项目 | 原版 | 候选版 |
| --- | --- | --- |
| 同一 C 探针收到的 WM_DISPLAYCHANGE | 0 次 | 20 次，包含拔下和接回触发的多个底层事件 |
| 拔下右侧外接显示器 | 3 屏变 2 屏 | 3 屏变 2 屏 |
| 稳定后的虚拟桌面 | 3008×3021 | 3008×3021 |
| 接回后虚拟桌面 | 6016×3021 | 6016×3021 |
| 实际窗口 | 原版作为通知对照 | 用户确认回到剩余屏幕，位置和最大化正常 |

切换期间两版都观察到过临时 1024×768 单屏回退，稳定后恢复正确拓扑。
本轮确认了普通 Win32 诊断窗口和热插拔通知。SOLIDWORKS 专用模态窗口、
主显示器切换和缩放切换仍需分别验收。

候选驱动、win32u、ntdll 和 loader 通过现有构建入口构建。隔离副本最初混用
Developer ID 启动器与 ad-hoc 模块，被 macOS 库验证拒绝加载。对隔离副本使用
一致的开发签名后，重新启动候选探针并完成上述验收。

## 重跑

使用两个 Wine 环境中相同的探针源码。每轮关闭探针前，至少进行一次真实的
显示器拔下和接回。没有拓扑变化或没有显示变更通知时，探针以非零值退出。

    x86_64-w64-mingw32-gcc native/wine_display_topology_probe.c \\
      -o /private/tmp/wine_display_topology_probe.exe -luser32
    WINEPREFIX=/path/to/disposable-prefix LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 \\
      /path/to/wine /private/tmp/wine_display_topology_probe.exe

原始日志临时位于 /private/tmp/macsw-displays.8Srwb9。诊断只创建自己的窗口。
Wine 11.21 标签中的 macdrv_displays_changed 和 display_mode_changed(FALSE)
仍保留同一通知缺口，且没有 applicationDidChangeScreenParameters:；因此迁移时继续保留 0021。

## Wine 11.21 正式容器复测（2026-11-06）

迁移 0021 后，在已升级的正式 App / 默认容器中完成两轮物理拔插：

- 普通诊断窗口：29 次 `WM_DISPLAYCHANGE`，探针检测到 5 次拓扑变化并正常退出。
- 第二轮先把窗口放在右侧副屏，程序调用 `ShowWindow(SW_MAXIMIZE)`，日志确认初始 `maximized=1`，随后用户完成两次拔插；已记录 21 次通知，接回后虚拟桌面恢复为 6016×3021、3 屏。
- 用户澄清原始问题为“插入新显示器后 Wine 窗口仍只能在小区域内拖动”，并确认本轮没有再出现这一限制。这项核心问题的实际验收通过。
- 用户同时观察到窗口没有自动回到原屏、尺寸变成小屏大小。日志也显示其后 `maximized=0`，窗口尺寸随工作区变化；这类恢复行为差异不归入“最大化保持完全通过”。没有为消除这些差异继续扩大修复范围。

记录位于 `/private/tmp/macsw-wine1121/integration/display-{hotplug,max-hotplug}.log`，第二轮摘要为 `display-max-summary.json`。原生面板和 SOLIDWORKS 专用模态窗口的跨屏交互仍需另外验收。

为避免只保留临时改版探针，仓库探针新增可选 `--maximize-secondary`：选择最右侧的非主屏，仅移动并最大化自己的窗口，记录 `auto-maximized`。无参数行为不变；没有副屏或参数错误会明确失败，不改系统显示设置：

```sh
x86_64-w64-mingw32-gcc -std=c99 -O2 -Wall -Wextra -Werror \
  native/wine_display_topology_probe.c -o /private/tmp/wine_display_topology_probe.exe -luser32
# 使用前述选定 Wine / prefix 的启动环境：
wine /private/tmp/wine_display_topology_probe.exe --maximize-secondary
```
