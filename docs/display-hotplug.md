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
仍保留同一通知缺口，且没有 applicationDidChangeScreenParameters:，
本轮未将 Wine 11.21 作为完整运行时做热插拔对照。
