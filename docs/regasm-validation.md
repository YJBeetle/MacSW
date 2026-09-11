# 官方安装的托管组件注册阻塞

## 2026-09-11 复核

正式安装日志 `logs/install_msi.log` 显示 SWRegistration 调用
`C:\windows\Microsoft.NET\Framework64\v4.0.30319\regasm.exe`
注册 `gdtanalysis.net.dll` 时 CreateProcess 失败，随后返回 0x643。
这不是许可证注册，也不能通过许可证配置修复。

本轮未创建或修改正式 bottle；检查时该目录已不存在，历史安装日志仍保留。

## 独立验证

在已有 `scratch/app-runtime-smoke` 测试容器中，使用 App 内 Wine 11.16
和 Wine-Mono 11.3.0。从官方 .NET 4.8 安装包的 netfx_Full.mzz 提取
`regasm_exe_amd64` 与 `regasm_exe_config_amd64`，分别命名为
regasm.exe 与 regasm.exe.config。

- 官方工具的帮助命令正常运行，版本为 4.8.3761.0。
- 使用 bundled Mono 的 csc.exe 编译自建的 ComVisible 测试类，编译成功。
- 用官方 RegAsm /codebase 注册测试 DLL，返回 100，并报告
  `The method or operation is not implemented`。
- 测试容器的 system.reg / user.reg 未找到测试类名称及指定 CLSID。
- 因此不能把“RegAsm 能启动”当作“组件注册功能已支持”。

Wine 自带的 regasm.exe 也不是替代方案：上游
[programs/regasm/main.c](https://github.com/wine-mirror/wine/blob/master/programs/regasm/main.c)
是输出 stub 后直接返回 0 的占位实现。复制它只可能掩盖失败。

## 后续边界

尚未定位官方 RegAsm 在 Wine-Mono 中触发的具体未实现方法。
下一步应独立验证原生 .NET Framework 的安装、COM 注册和 WPF 启动兼容性，
而非直接替换已验证的 App 运行时。未通过这些验证前，不宣称注册失败已修复，
不建议仅为此再次完整安装 SOLIDWORKS。

## 原生 .NET 初步对照

本轮新建 `scratch/dotnet-native-probe`，日志在
`scratch/dotnet-native-logs`；正式容器及 App 配置保持不变。

1. 初始化时禁用 mscoree 自动加载；默认 Windows 10 下运行官方 4.8
   安装包返回 0，但 HTML 日志明确因认为系统已有 4.8 而跳过，未生成 RegAsm。
2. 将测试容器设为 Windows 7 后重试，官方安装器返回 0，实际生成了
   Framework64/v4.0.30319/RegAsm.exe 和 clr.dll。
3. 强制 native mscoree 后运行测试 RegAsm，返回 53；加载日志确认缺少
   原生 mscoree.dll，现有文件仍是 Wine 入口。
4. 下载微软 .NET 4.0 官方包，SHA256 为
   `65e064258f2e418816b304f646ff9e87af101e4c9552ab064bb74d281c38659f`。
   为隔离加载入口问题，从其 netfx_Core.mzz 提取 x86/x64 mscoree.dll，
   仅复制到测试容器对应系统目录。这不是完整安装 4.0。
5. 重试未完成注册；日志出现 CLR 初始化相关错误（包括优化服务的致命错误
   和 mscorees.dll 消息资源缺失），不能据此断定 RegAsm 的具体根因。
   停止该测试容器的进程并保留现场，未开展 WPF 或 SW 启动测试。

结论：原生 4.8 安装器可以落盘，但本轮尚未证明原生 CLR/COM 注册可用。
下一轮应在干净测试容器按完整的 4.0 安装再升级 4.8 顺序验证，不能以本轮
手工补入口替代完整安装，也不能把它合入 App 默认链路。
参考 [Winetricks dotnet40/dotnet48 安装流程](https://github.com/Winetricks/winetricks/blob/master/src/winetricks)。
