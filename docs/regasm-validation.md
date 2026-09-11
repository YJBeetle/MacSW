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

## 返回零的安装对照：已确认继续后续步骤

复制既有官方安装测试容器到 `scratch/sw-regasm-zero`，不修改正式容器。
在 Framework/Framework64 的 v4.0.30319 下分别放入当前 Wine 自带的
x86/x64 regasm.exe 占位实现；先用安装器相同的参数验证 x64 工具退出码为 0。
然后对原版 MSI 运行静默修复：`REINSTALL=ALL REINSTALLMODE=vomus DISABLEROLLBACK=1`。
这是已有容器副本的修复对照，不是全新安装验证。

证据保留在 `scratch/regasm-zero-logs/`：

- `probe.log` 确认指定路径的占位工具被调用。
- `wine.log` 记录安装期间 21 次 regasm stub 调用。
- `install.log` 的 ExecuteRegAsm 逐项记录 Returned:0x0、IgnoreExitCode:0，
  随后明确输出 SUCCESS。
- `SWRegistration` 结束时 Return value 1（MSI 动作成功），不再在原来的
  gdtanalysis.net.dll 注册位置退出。
- 后续 WriteToolboxStandardsXML 成功，再进入 UpdateBrowserData，运行
  Toolbox 的 DatabaseConverter.exe。
- 数据库转换约两分钟仍未结束、CPU 约 100%；未确定是正常耗时还是循环。
  为限制独立实验资源占用，主动停止该容器。没有拿到整场 MSI 的自然结束结果，
  不将主动终止结果当作 MSI 自身安装失败。

结论：对于本轮 MSI 的 ExecuteRegAsm 路径，正常启动并返回 0 足以让安装器
接受结果、继续后续步骤。21 次托管注册实际均未执行，不能把安装器接受结果
视为 COM 组件注册成功。

## App 干净安装验证版本

经用户确认，安装流程现在在 wineboot 后补齐两种架构的 Wine RegAsm 占位工具。
来源固定为 App 自带 runtime，不引入原生 .NET，不修改安装包，也不自动处理
许可服务或授权。遇到已有的不同版本 RegAsm 会中止，避免覆盖原生工具。
安装前及最终结果明确显示托管 COM 注册跳过，详细记录在
Application Support/MacSW/logs/regasm-compatibility.log。
此版本等待用户干净安装验证；数据库转换和相关插件能力仍未确认。
