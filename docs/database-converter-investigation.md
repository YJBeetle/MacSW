# DatabaseConverter 安装停滞调查

## 当前正式安装现场

2026-09-11 的 install_msi.log 显示 SWRegistration 和
WriteToolboxStandardsXML 已通过。18:01:24 进入 UpdateBrowserData 后，安装器
等待 DatabaseConverter.exe 处理 C:\SOLIDWORKS Data\lang\english\SWBrowser.mdb。
调查时进程已运行约 18 分钟，CPU 约一个核心。正式容器仅有
SOLIDWORKS Data/ToolboxStandards.xml，没有 lang/english 目录。
调查没有终止或修改正式安装进程。

## 静态检查与最小对照

转换器 IL 的 CorFlags 为 0x3（ILONLY、32BITREQUIRED），引用 WinForms、
OleDb 和 System.Data.SQLite。入口先初始化 WinForms，再检查输入路径；
目录不存在时跳过该输入，最后退出。因而缺少目录本身不能解释持续高 CPU。

macOS 线程采样有大量 Rosetta exceptionserver 活动，但符号不完整，不能
据此确定具体异常或 CLR 函数。

在独立 scratch/app-runtime-smoke 容器，用 App 内 Wine 11.16 / Mono 11.3.0
编译并运行同源 FormsStartupProbe.cs：

- /platform:x64：打印 MAIN（指针宽度 8）、EnableVisualStyles passed、
  WinForms initialization passed，退出 0。
- /platform:x86：一分钟仍未打印第一行，CPU 约 104%；主动终止该独立测试进程。
- 此最小程序不访问数据库、不调用 SolidWorks，也不创建窗口。

输出位于 scratch/regasm-zero-logs/forms32.log、forms64.log。
静态分析输出 DatabaseConverter.il 与线程采样仅作为本地诊断产物，不提交二进制或反汇编。

## 结论与待查

已复现 32 位托管 WinForms 启动路径异常，不能把当前停滞简单解释成数据库
转换耗时；尚未定位到 Wine、WoW64、Mono 或 Rosetta 中的具体缺陷。
第一行未输出不一定代表 CLR 完全未启动，也可能在入口 JIT/依赖加载期间停滞。

数据库资源缺失是另一条需要独立处理的问题。不能仅把转换器改成返回零就
声称 Toolbox 已准备完成，也不能未经验证取消 32BITREQUIRED，因为存在
OleDb 与本地 SQLite 依赖。下一步应以最小程序定位 32 位启动问题，再单独
核查官方安装介质中数据库资源的部署流程。

补充介质检查：swwi/data/English.cab 已包含 swbrowser.sldedb（20,250,624 字节）
及 updatedb.sldedb（18,605,056 字节）。因此不能认为介质只有待转换的旧 MDB；
新容器可能应直接部署现成数据库。仍需核查 MSI 文件/组件映射和语言部署流程，
解释为何这些资源没有落入正式容器；本轮仅列出 CAB 内容，未提取或写入容器。

## 纯托管程序与解释器对照

同一独立容器、同一 App 内 Wine/Mono 的进一步对照：

| 程序 | 默认模式 | WINE_MONO_AOT=interp |
| --- | --- | --- |
| 32 位原生 cmd.exe | 正常退出 0 | 未测 |
| ConsoleProbe x64 | 输出 pointer=8，退出 0 | 未测 |
| ConsoleProbe x86 | 无 Main 输出，持续约一个核心 CPU | 输出 pointer=4，完成退出 |
| FormsStartupProbe x86 | 无 Main 输出，持续高 CPU | 输出 MAIN，随后在 EnableVisualStyles 崩溃 |

默认 x86 Console 的 +seh,+loaddll 日志已加载 libmono-2.0-x86.dll 和
mscorlib.dll，随后记录 c0000005。按同一进程模块基址定位，异常地址
7BF21135 对应 wow64cpu.dll +0x1135，访问地址 0x2ec5。这只是异常现场，
不能据此认定缺陷一定在 wow64cpu；Mono、WoW64 与 Rosetta 的交互仍待定位。

解释器模式下 WinForms 的托管栈为 Main → EnableVisualStyles →
ThemingScope.CreateActivationContext → CreateActCtx，随后发生执行访问异常。
因此解释器绕过了纯 Console 启动问题，但不能作为安装器的正式修复。
尚未对实际 DatabaseConverter 使用该开关，也未改变正式安装进程的环境。

Wine mscoree 源码通过 WINE_MONO_AOT=interp 选择 MONO_AOT_MODE_INTERP_ONLY：
https://github.com/wine-mirror/wine/blob/master/dlls/mscoree/metahost.c
此前试过 MONO_ENV_OPTIONS=--interp，仍停滞；不能把它当成已生效的解释器测试。

本地日志：console32-seh-modules.log、console64.log、console32-wine-interp.log、
forms32-wine-interp.log（均在 scratch/regasm-zero-logs）。复现源代码保存在
macos/Bootstrap/Tests/ConsoleProbe.cs 与 FormsStartupProbe.cs。

下一步应独立对照 32 位托管到原生调用，以及不同 Wine/Mono 组合，避免将
wineloader 的存在误当成所有 32 位运行时路径都兼容的证明。

## 最小 P/Invoke 对照

NativeCallProbe.cs 在解释器模式下依次调用 GetCurrentProcessId 和
CreateActCtxW(NULL)，不依赖 WinForms，也不创建实际激活上下文。

- x86 GetCurrentProcessId 正常返回，说明并非所有原生调用均失败。
- x86 CreateActCtxW 出现 execute access 异常（023C0080）。移除
  DllImport.SetLastError 后仍复现，不能归因于该选项。
- 同源 x64 正常输出 PID，并从 CreateActCtxW(NULL) 返回 -1。
- x86 直接导入 kernelbase.dll 的 CreateActCtxW 仍崩溃（023C0088），
  不是仅换掉 kernel32 入口转发就能解决。

以上定位到具体调用路径，但尚未区分 Mono 调用桩、Wine API 内部或
Rosetta 执行权限处理。没有修改正式运行时或把失败调用替换为成功。
本地日志为 nativecall32-interp.log、nativecall32-no-last-error.log、
nativecall64-interp.log、nativecall32-kernelbase.log。

## 运行时组合对照

继续以 NativeCall32NoLastError.exe 和解释器模式对照，同一探针二进制：

| Wine 来源 | Mono | 结果 |
| --- | --- | --- |
| App Gcenx 11.16 | 10.4.1 | PID 正常，CreateActCtx 崩溃 |
| Gcenx stable 11.0_1 | 11.3.0 | PID 正常，CreateActCtx 崩溃 |
| CrossOver 26.3.0.39832 | 自带 10.4.1 | PID 正常，CreateActCtx 崩溃 |

每组通过 loaddll 确认实际 libmono-2.0-x86.dll 路径。旧 Mono 对照克隆
app-runtime-smoke 到 scratch/mono104-compare/prefix，并仅在该副本设置
HKCU\Software\Wine\Mono 的 RuntimePath。稳定版使用全新
scratch/wine110-compare/prefix，CrossOver 使用 CX_BOTTLE_PATH 指向
scratch/crossover-compare，通过 cxbottle 创建 mono-probe（win10_64）。
没有替换 App 内运行时，也没有修改已有 CrossOver 容器。

日志分别为 mono104-compare/nativecall-interp.log、
wine110-compare/nativecall-interp.log、crossover-compare/nativecall-interp.log，
均位于 scratch。稳定版来源：
https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.0_1

这些结果不足以把问题归因于 Gcenx 11.16 或 Mono 11.3.0 的单独回归。
它们只是解释器原生调用对照，不代表所有组合的默认 JIT、WinForms 或实际
安装器均已测试。旧 Wine 主版本仍未完成：查询时 Gcenx 官方发布与标签清单
仅列出 11 系列，需另找可核实的历史构建来源。
