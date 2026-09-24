# SOLIDWORKS PropertyManager 标题消失与 Wine 子窗口 TOPMOST 语义

调查日期：2026-09-24。适用对象：MacSW 的 Wine 11.16 补丁
[`0005-win32u-ignore-child-topmost.patch`](../patches/wine-crossover/0005-win32u-ignore-child-topmost.patch)。

## 现象与根因

在 SOLIDWORKS 中创建草图后打开“拉伸凸台”，或编辑已有特征时，PropertyManager
左侧分组标题会先出现，再从左向右逐渐消失。文档子窗口最大化时，移动并释放主窗口
还会重现一次；子窗口未最大化时没有观察到同样的拖动触发条件。特征树边缘另有几个
像素被裁切，**不是本补丁修复的对象**。

先前的 Windows 原生 / 未修补 Wine / 修补后 Wine 对照排查表明，SOLIDWORKS 会对
真正的子窗口调用 `SetWindowPos(child, HWND_TOPMOST/NOTOPMOST, ...)`。原生 Windows
在这一条件下返回成功，但不改变子窗口矩形，也不发送对应的 `WINDOWPOS` 布局消息；
Wine 11.16 则继续执行位置与尺寸更新。SOLIDWORKS 的 PropertyManager 因此重复
布局，每轮让标题控件向右缩窄约 4 px，最终宽度为零。视觉上像“擦除文字”，实际是
承载文字的控件不断变窄；同时观察到的 `WM_ERASEBKGND` 更可能是布局过程的症状。

这些动态观察来自此前的本机及原生 Windows 对照测试；原始抓取日志和 probe 源码
目前没有收录在本仓库，不能把它们当作可直接复跑的附件。不过 Wine 当前 master 的
[`dlls/user32/tests/win.c`](https://gitlab.winehq.org/wine/wine/-/blob/master/dlls/user32/tests/win.c)
`test_SetWindowPos` 已经对 child + `HWND_TOPMOST/NOTOPMOST` 的矩形不变性写了
`todo_wine` 断言，独立佐证了 Windows 与 Wine 的兼容性差异。

## MacSW 本地修复与验证边界

本地 `0005` 在 `NtUserSetWindowPos` 中，对 `WS_CHILD` 且未设置 `SWP_NOZORDER`
的 `HWND_TOPMOST/NOTOPMOST` 请求直接返回成功。保留 `SWP_NOZORDER` 边界很重要：
此标志表示忽略 `hWndInsertAfter`，位置与尺寸更新仍应正常执行。此前最小 Win32
对照及真实 SOLIDWORKS 复测确认，修补后标题不再连续缩窄；MacSW 当时通过
`make app`、132 项 Swift 测试及 137 项 Python 测试。这些是 **MacSW 集成验证**，
不是 Wine 上游 CI 或 Wine Test Bot 的结果。

2026-09-24 对 Wine master `1977760e3745c58ee9c2b8aeb93e54e5fe7f14e2` 做了
`git apply --check`，本地补丁可应用；**尚未**在该 master 上完成构建或全套 Wine
测试。补丁本身也不宜直接提交上游：它只检查 `WS_CHILD` 样式，没有区分父窗口
已变为桌面的情形，而 Windows 在该情形下仍可正常改变 topmost 状态和几何。

## Wine 上游现状

Wine 官方[提交指南](https://gitlab.winehq.org/wine/wine/-/wikis/Submitting-Patches)
要求通过 [WineHQ GitLab](https://gitlab.winehq.org/wine/wine) 提交 Merge Request，
并使用已验证账号和真实姓名；邮件补丁通道已退役。上游已经有
[`!667`](https://gitlab.winehq.org/wine/wine/-/merge_requests/667)，标题为
“win32u: Ignore SetWindowPos() if it is trying to change topmost state for child window.”，
截至 2026-09-24 仍为 open。该 MR 同时：

- 移除 `user32/tests/win.c` 中 child + `TOPMOST/NOTOPMOST` 的 `todo_wine`；
- 在 `set_window_pos` 内仅对真正有非桌面父窗口的 child 略过这类请求；
- 测试 `SetParent(child, NULL)` 后仍应正常更新，以及重新挂回父窗口后的行为；
- 关联 [Wine-Bug 20190](https://bugs.winehq.org/show_bug.cgi?id=20190)。

因此再开一个内容相同、覆盖边界更少的 MR 没有价值。更合适的上游动作是向
`!667` 补充 SOLIDWORKS 2025 的实际受影响与 MacSW 回归验证，或在征得该 MR
作者/维护者意见后协助刷新现有提交。当前主机 `glab auth status --hostname
gitlab.winehq.org` 显示尚未认证；报告不代表已经向 Wine 提交 MR 或评论。

## 复核清单

1. 在原生 Windows 与未修补 Wine 上复跑 child + `TOPMOST/NOTOPMOST` 和
   `SWP_NOZORDER` 的独立 probe，保存矩形与 `WINDOWPOS` 消息日志。
2. 若更新上游代码，先复跑当前 Wine 测试，再运行改动后的 `user32/tests/win.c`
   和 Wine Test Bot；按官方建议把测试提交排在修复提交之前。
3. 保留非桌面父窗口、桌面父窗口、跨线程与 `SWP_NOZORDER` 的语义边界；不要直接
   把 MacSW 的简化 `0005` 复制到 Wine master。
4. 在 SOLIDWORKS 实机验证 PropertyManager 标题，同时单独追踪特征树左侧裁切。
