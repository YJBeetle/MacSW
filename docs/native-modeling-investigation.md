# 原生建模 CI 调查

## 当前结论

MacSW 的构建、真实安装与 COM 就绪已经有成功证据，但托管 macOS 上的连续建模
尚未稳定通过。当前没有足够证据把故障归因于某个 Wine 模块、隐藏窗口或矩形算法。
调查保持原有共享门禁和 120 秒操作超时，不重试失败操作，不中途重启后续跑。

MacSW 负责安装、Wine、App 打包、驱动映射、宿主准备和证据收集；建模操作与
断言仍只维护在 SWCLI。Windows、DockerSW 的成功不能替代本仓库 macOS 的证明。

## 已完成运行的证据

| 运行 | 首个业务失败 | 已证明的边界 |
| --- | --- | --- |
| [37706684327](https://github.com/YJBeetle/MacSW/actions/runs/37706684327) | front 建模和切除后，top 矩形超过 120 秒 | 缓存恢复、可见模式就绪及此前操作成功；未进入尺寸或隐藏模式 |
| [37727420806](https://github.com/YJBeetle/MacSW/actions/runs/37727420806) | 第一次实际后台 front 矩形超过 120 秒 | 全新安装、可见模式就绪、无租约及错误 stamp 的前置拒绝成功；此前没有实际切除 |
| [37730038675](https://github.com/YJBeetle/MacSW/actions/runs/37730038675) | 保存后的后台文档 `document.close` 返回 `0x800703e6` | 缓存恢复、front/top/right 草图、拉伸、圆、切除和保存成功；未进入尺寸或隐藏模式 |

后两轮都固定 SWCLI `86c52f27c0b2bdcfe0bf990debfc840481608d58`，
获得就绪的自有 SOLIDWORKS PID 488、版本 `33.5.0`、简体中文、可见模式。
失败点不同，因此“始终在第一次矩形”“只发生在切除后”“只因隐藏”均不成立。

`37730038675` 的 Wine 异常日志包含服务器端捕获的空地址访问异常，随后 COM
返回 `0x800703e6`。这证明该调用出现原生异常，不证明整个 SOLIDWORKS 进程已
崩溃，也不足以区分 SOLIDWORKS 缺陷、Wine 兼容性或其他宿主因素。日志中的
`slduiu.dll` 帧不能单独确定最初错误来源。

`ISupportErrorInfo` 封送警告在成功调用中也出现，不能单独作为失败原因。
超时后清理触发的 `WorkerStartupError` / `REGDB_E_CLASSNOTREG` 是后续错误，
不能取代首个超时，也不能倒推首次 COM 激活失败。

## 当前诊断版本

MacSW `498e3883b4a53a6c673e1e21d171a244282a9ea1` 同步 gitlink 与
`config/versions.env`，固定 SWCLI
`93d40e274be9d3714ccab00905fc36a6675fc195`（`0.1.0a6.dev0`）。
[37732440131](https://github.com/YJBeetle/MacSW/actions/runs/37732440131)
使用这一版本全新安装；调查记录撰写时已完成构建和安装，正在执行共享运行门禁，
尚无完整通过结论。

CI 设置 `SWCLI_TRACE_NATIVE_CALLS=1`，在普通 daemon 日志里记录立即刷新的
调用开始、结束与耗时。它不修改原生参数、几何断言、租约或恢复策略。
按 `(worker_pid, request_id, sequence)` 配对事件；`end` 只表示调用返回，不表示
业务成功。只对已经覆盖的调用边界作判断，不能把日志空白解释为任意原生方法阻塞。
特别是请求前的 `RevisionNumber` 探测和直接 `CloseDoc` 当前没有独立方法边界。
详见 [运行适配器与诊断约定](runtime-ci.md#原生调用分段诊断)。

## 本机交叉验证

2026-10-08 使用重新打包的 `build/app/MacSW.app` 和日常主 bottle，保留旧
Windows backend 后，仅同步 SWCLI Python 包。测试文件集中在一个独立的
`C:\Workspace\MacSW-trace-20261008.6A0yEq` 目录，没有修改安装样例或用户模型。
以自有可见模式启动，SW PID 376、版本 `33.5.0`，启用同一调用诊断。

共享 `verify-modeling.py` 已完成：`success=true`、85 个事件、清理错误为零，
包含 `native-model`、`reverse-cut`、`rejected-cut-then-sketch` 三个用例。
后台操作、保存关闭重开、预期原生失败后的继续建模均在同一宿主上通过。
第一次 `CreateCenterRectangle` 用时约 1.2 秒。MacSW 适配器没有传入可选的安装
Part/Assembly 样例，因此 85 个事件不等同于 Windows/DockerSW 含样例导出的
97 个事件。尺寸门禁仍在同一宿主上进行，隐藏模式尚未验证。

此结果仅证明本机现有主容器在该次可见序列中通过，不是托管 runner、全新安装、
缓存恢复、隐藏模式或 GUI 交互的替代证明，也不是故障已经修复的结论。

## 后续收口

1. 取得诊断 CI 的首个失败及最后已覆盖调用；若失败发生在未覆盖边界，只增加
   相应方法的开始/结束记录，不先改变调用顺序或超时。
2. 完成本机共享建模 → 尺寸的可见序列，再独立验证隐藏序列；每个序列内不得
   更换 daemon/SOLIDWORKS。
3. 只有具体调用和宿主证据支持时才修改 Wine/MacSW 或 SWCLI；修复后重新执行
   未削弱的共享门禁，并分别记录本机、全新安装和缓存恢复的结果。
4. App 更新时既有 bottle 的 Windows backend 同步仍需单独核查；本次为可恢复
   的显式测试升级，不把这个部署问题与托管 CI 的原生异常混为一项。
