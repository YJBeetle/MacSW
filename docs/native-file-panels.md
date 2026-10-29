# macOS 原生打开与保存面板

Wine 补丁 `0017-comdlg32-native-file-panels.patch` 将文件选择交给临时 AppKit
助手 `MacSWFilePanel.app`。每次面板启动一个子进程，结束后退出，无常驻守护程序，
也不依赖 MacSW 主程序转发请求。Wine 继续负责 Windows 路径转换、对话框返回值、
SOLIDWORKS 事件回调和实际文件读写。

`MACSW_NATIVE_FILE_PANEL` 指向包内助手。两端通过带版本和序号的临时二进制文件
交换路径、格式与控件状态，不执行 shell 或 AppleScript。Wine DLL 变化需要重启
SOLIDWORKS；助手可在下一次面板启动时使用更新后的二进制。

## SOLIDWORKS 专用控件

桥接读取实际的 `IFileDialogCustomize` 控件和状态，原生面板显示格式、按钮、
单选框、复选框、文本及下拉选项。用户操作送回原始回调后，再刷新控件。
“选项…”等按钮临时隐藏面板，待 SOLIDWORKS 子窗口结束后恢复。

打开按钮的“以只读打开”等选项保留原始项目 ID，由 SOLIDWORKS 执行实际操作。
文件格式来自应用提供的过滤器，不另设 CAD 扩展名白名单。打开面板按大小写不敏感
的文件名模式筛选，支持分号列表、`*`、`?`、CATIA 的 `.CATProduct` 和 Creo 的
`*.prt.*`。保存面板保留格式回调，仅使用具体扩展名补全文件名，不把通配符写进文件名。

文件格式下拉框不等同于 Windows 窗口中额外的“快速过滤器”图标；后者尚未实现。

## 自动检查与真实验收

- `scripts/test_native_file_panel_filters.sh` 直接测试助手使用的过滤与扩展名解析。
- `scripts/diagnostics/verify_native_file_panels.py` 使用 x64 / x86 Wine 探针和捕获的
  面板响应验证 ABI、返回路径及回调；这类响应不证明 AppKit 的可见交互。
- 构建 CI 归档 `MacSW-native-file-panels` 证据，正式签名仍由独立签发工作流执行。

2026-10-30 在本机临时运行时、实际 SOLIDWORKS 2025 中完成以下验收：

1. 用户从原生打开面板选择“以只读打开”；COM 读回 `IsOpenedReadOnly = true`。
2. 原生面板另存为 `原生保存验收.SLDPRT`，关闭后重开成功，错误与警告均为 0。
3. 同名覆盖成功，文件大小及修改时间更新。
4. 原生面板导出 STEP AP214；文件头为 AP214，用户从界面重开后可显示模型。
   自动 `OpenDoc6` / `LoadFile4` 导入在这次实例中失败，未据此宣称 API 导入通过。
5. 在临时零件中建立 `MacSW_Export_Coord`，用户在面板选择此输出坐标系并导出。
   原点为 `(5.45, 0, -7.349668926783947) mm`；与默认坐标系导出对比，127 个
   STEP 点全部符合预期反向平移，最大最近点误差约 `9e-15 mm`。

这些结果针对临时构建与该验收零件；不替代正式签名包验收，也不表示所有导入格式、
装配体引用或保存版本组合均已验证。临时文件位于 `/private/tmp/MacSW 原生保存验证`。
