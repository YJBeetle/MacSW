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
