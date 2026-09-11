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
