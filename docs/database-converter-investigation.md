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
