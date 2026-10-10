# Toolbox 标准件部署（2026-10-10）

## 原安装状态

主容器的 Toolbox 程序、COM 注册和 SQLite 数据库都存在。用户与机器配置均指向
`C:\SWData`，`lang/english/swbrowser.sldedb` 的只读 `PRAGMA quick_check` 返回 `ok`。
但该目录只有数据库、`ToolboxStandards.xml` 和 `ToolboxVersion.dat`，没有 Browser
标准件模型与 `ToolboxFiles.index`。这不是完全未安装，也不是数据库文件缺失。

官方说明指出 Toolbox 根目录应包含 Browser 与 lang 两个目录：
[设置 Toolbox 根目录](https://help.solidworks.com/2025/english/SolidWorks/toolbox/t_toolbox_setting_toolbox_root_folder.htm?id=33.1.0.2)。

## 原因及同二进制对照

MSI 已执行 `sldtoolboxupdater.exe <数据目录> <介质Toolbox目录> TRUE`，但日志中
工具退出码是 `0x1`；外层 `WIDll_SldToolboxUpdater` 仍报告成功，因此 App 的 MSI
退出码检查没有发现标准件缺失。对应 Wine 日志显示 WPF 在构造 Application/
Dispatcher 的消息窗口时抛出 Win32Exception「该类不存在」，尚未进入解包。

在数据库副本、同一官方工具和同一介质上，仅改变 `WINE_MONO_AOT`：

- `interp`：退出 1，0 个零件，复现同一 WPF 窗口创建异常。
- `none`：退出 0，生成官方索引和 19 套标准的 1,818 个原生零件。

这是解释器与该 x64 WPF 工具启动路径不兼容的对照证据，不是某个 Wine API 或
Mono 源码函数的根因定位。未改写 SOLIDWORKS 程序，也未自行解包/拼装数据库。

## App 安装流程

`ToolboxService` 在主体 MSI、语言包和五个 WPF 主题库完成后，独立运行官方更新
工具，仅为这个进程设置 `WINE_MONO_AOT=none`。其他安装/RegAsm 进程仍走解释器。
读取官方注册的 Toolbox 数据目录，不固定 SOLIDWORKS 年份；用户覆盖优先，多个
不同目录时拒绝猜测。Windows 路径通过该容器的 winepath 解析，介质使用实际映射。

运行前检查数据库、标准配置和所选 ZIP，运行后既要求退出 0，又要求非空官方索引
及每个启用标准的原生模型。失败不写安装完成标记，日志单独保存为
`logs/toolbox-install.log`，取消沿用原有安装取消/容器收尾流程。不在日常启动时
重新部署标准件，也不覆盖用户的数据库或更改其标准选择。

## 本机验证与未完成边界

共享 `Dependencies/SWCLI/scripts/ci/verify-toolbox.py` 门禁已接入 MacSW CI：每个
可见／隐藏模式在建模和驱动尺寸之后、同一 daemon/SOLIDWORKS 宿主中运行。
它从本轮隔离容器的真实注册表和映射发现数据目录，检查完整标准配置、官方
索引、模型与数据库，再用公共 CLI 只读打开、诊断、测量和关闭代表件；不重建、
不保存，也不修改主容器。数据缺失不能静默跳过，外层预算为每模式 600 秒。
接线的离线测试不代表真实运行已通过；安装与运行 CI 的顺序、证据和预算见
[运行验证说明](runtime-ci.md)。

主容器通过官方工具修复前保留完整 SWData 副本；实际退出 0，索引生成，19 个
启用标准均有模型（GB 330、ISO 140，总计 1,818）。重新打包校验并替换主 App，
保留旧 App；Wine、Mono、补丁身份不变。

主 SOLIDWORKS 33.5.0 的实际 COM 冒烟已加载 SwToolbox/SwBrowser（均返回 0），
只读打开 GB 六角头螺栓：OpenDoc6 错误 0、警告 2，模型非空、1 个实体，配置
为 Default/PreviewCfg。关闭该只读文档的调用曾返回，但随后主进程退出；本轮
尚未确定是否为自动化生命周期、插件或关闭路径的问题，不将它标为稳定性通过。
最后重新启动主实例，显式保持可见并保留只读 GB 模型，供返回后的 GUI 验收。
警告 2 仍保留在证据中，不把只读打开称为完全无警告的规格/装配体验验收。

Swift 164 项、Python 169 项（跳过 1 项）、CLI 路由检查和成品校验通过。
本轮没有重跑全新安装；新增安装步骤有离线回归和相同官方命令的真实运行证据。
规格选型、拖入装配体、生成配置和保存重开仍需 GUI 验收，不能由文件存在或原生
模型能打开代替。

诊断过程中保留两个与 Toolbox 修复无关的发现：主 App 的进程名启发式会将其他
隔离实例误认作主实例；独立启动探针必须设置 SOLIDWORKS 工作目录。后者已修正
诊断命令，正式启动代码本来已有工作目录。本轮未修改多容器进程归属逻辑。
