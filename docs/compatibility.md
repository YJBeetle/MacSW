# Compatibility reports

MacSW 的应用版本与 SOLIDWORKS 版本相互独立。构建所使用的 Wine、Wine-Mono 和补丁产物由
[`config/versions.env`](../config/versions.env) 固定；SOLIDWORKS 版本只记录为验证结果，不参与
Builder 的版本选择。

## Maintainer-verified baseline

| SOLIDWORKS | MacSW | Wine / Mono | Host | Result | Remaining coverage |
| --- | --- | --- | --- | --- | --- |
| 2025 SP5.0 | `e7c705a`, `0.1.0` (1) | Wine 11.16 / Wine-Mono 11.3.0 | Apple Silicon, macOS 15.6 | Clean install through the App completed; automatic Login Manager/COM registration removed the startup error; main window and Part document verified; FeatureManager clipping, CommandManager expand/collapse, Task Pane redraw, composite context-menu commands, mouse gestures, and PropertyManager confirmation verified; the same-binary AppCompat A/B isolated and fixed Wine's same-window capture resend; the patched Wine driver preserved the model across blank-canvas clicks and focus loss and kept edge preselection visible | Save/reopen after a fresh launch, Toolbox, display hot-plug, and mouse-gesture transparency |

This table records observed behavior, not a promise that every component or workflow is supported.

## Community reports

Compatibility reports are welcome as pull requests. Add one row below and include enough evidence to distinguish
an application regression from a Wine, installer, licensing, graphics, or host-specific issue.

| SOLIDWORKS | MacSW commit/release | Wine / Mono | macOS and hardware | Install | Launch | Modeling depth | Known issues | Evidence / PR |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| _Example: 2025 SP5.0_ | _commit SHA or release_ | _from BuildManifest.plist_ | _macOS version, Mac model/chip, displays_ | _pass/fail_ | _pass/fail_ | _new part / sketch / feature / save-reopen_ | _short summary_ | _log, screenshot, or PR link_ |

Please redact serial numbers, license files, user names, and local paths before attaching logs. A useful report should
also state whether the bottle was clean or reused and whether the failure is reproducible after restarting MacSW.
