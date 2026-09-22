# SOLIDWORKS 文档窗口标题按钮风格不一致

## 现象与结论

创建 Part 并把文档子窗口从最大化切换为普通窗口后，标题栏会出现五个按钮。左侧两个按钮
带蓝色 Aero 皮肤，右侧最小化、最大化和关闭按钮则是白色经典风格。它们属于同一个文档
窗口，混合风格明显，但不影响按钮命令本身。

最终处理不修改 Wine 绘制代码。App 在新 bottle 的安装环境准备阶段写入：

```text
HKCU\Software\Microsoft\Windows\CurrentVersion\ThemeManager
ThemeActive = "0"
```

关闭 Wine ThemeManager 的活动主题后，五个按钮都使用同一套平面经典风格。该设置与
`WINE_NOCAPTURERESEND` 合并为一次注册表导入，只在安装时执行；项目目前没有 bottle schema
迁移框架，因此不为旧容器增加每次启动补写逻辑。

## 根因定位

历史补丁 `0001-defwnd-aero-caption-buttons.patch` 修改了 `user32!DrawFrameControl`，但实测切换
补丁版与原版 `user32.dll` 不会改变 SOLIDWORKS 中这五个按钮。进一步检查发现 SOLIDWORKS
加载的 `ToolkitProVC141x64U.dll`（Codejock/XTP）hook 了 `DrawFrameControl`：它会先尝试内部
皮肤绘制，只有失败时才回落到 user32。因此仅修改 Wine 的 DefWindowProc 绘制层无法统一
两组按钮。

在同一 bottle、同一 Part 和同一窗口状态下进行 A/B：`ThemeActive=1` 时复现混合风格；
`ThemeActive=0` 时五个按钮统一。随后分别加载补丁版和原版 user32 做像素比较，结果 AE 与
RMSE 都为 0，证明 0001 对实际界面没有作用。该补丁已从仓库删除，也从未进入当前 Builder
的 0002–0004 正式补丁链。

## 兼容边界

这是 bottle 级 Wine 主题选择，会让 Wine 内由主题管理器接管的控件回落到经典外观；目标是
一致性，而不是复刻 Windows Aero。新安装由 App 自动配置，已有测试 bottle 只需手工写入一次。
