# Login Manager 隐藏弹窗导致 SOLIDWORKS 交互失效

## 结论

SOLIDWORKS 2025 的复合右键菜单和鼠标手势轮盘失效，不是 Wine 鼠标捕获本身的缺陷。
根因是 SOLIDWORKS Login Manager 未正确注册时弹出的致命模态对话框被 UI 守护程序隐藏，
但对话框及其模态消息循环仍然存在。主窗口虽然可见，SOLIDWORKS 自己的消息预处理链却
没有正常运行。

在全新干净安装的 bottle 中安装 `swloginmgr/SOLIDWORKS Login Manager.msi`，并完成
`sldLoginManager.dll` 的托管 COM 注册后，缺失提示不再出现；经真机验证，一级和二级
复合右键菜单均可点击并执行，鼠标手势轮盘也能正常保持、选择并切换视角。

## 诊断证据

隐藏状态下枚举到的窗口为启用但不可见的 `#32770` 对话框，正文是：

```text
SOLIDWORKS Login Manager is not installed. Reinstall SOLIDWORKS or install SOLIDWORKS Login Manager.
```

消息 hook 显示左键按下和释放均已通过 `WH_GETMESSAGE` 以 `PM_REMOVE` 进入队列，hook 本身
没有吞掉消息。调用栈停留在：

```text
USER32!IsDialogMessageW / CallMsgFilter
COMCTL32 v6!TaskDialogIndirect
sldvistauiu.dll
sldappu.dll
```

这说明主线程仍在隐藏的 Task Dialog 模态循环内。SOLIDWORKS 的分体式 `swPopup` 依赖自身
`uiCustomPopup::PreTranslateMessage` 处理命令；该链路被模态循环绕过后，会出现菜单项无法
点击、外部点击无法关闭菜单，以及轮盘释放后错误弹出右键菜单等现象。

## 排除项

- 停用 UI 守护程序只能消除它对轮盘窗口的额外干扰，不能结束已经创建的模态对话框。
- `HKCU`/`HKLM` 的 `EnableSldLoginManager=0` 不能阻止缺失提示。
- `SW_Login_Disable=True` 只能关闭 3DEXPERIENCE 登录入口；实测仍会出现 Login Manager
  未安装提示。
- `WINE_NOCAPTURERESEND` 的 `win32u` 实验补丁不是必要条件。安装 Login Manager 后成功
  验证时，bottle 中不存在对应 AppCompat `Layers` 键，补丁未启用。
- 官方 2025 安装编排在选择 SOLIDWORKS 时会同时安装 `SWLoginMgr`。当前 App 直接执行
  `swwi/data/solidworks.msi`，因此绕过了该前置组件。

## 后续工作

- 将 Login Manager MSI 安装和 Wine-Mono 托管 COM 注册修复接入 App 安装流程；当前只有
  手工验证结果，正式 App 尚未集成。
- UI 守护程序不再隐藏 Login Manager 致命对话框，避免把阻塞状态伪装成成功启动。
- 鼠标手势轮盘的黑色背景是独立的合成/透明度问题，继续按 TODO 跟踪。
