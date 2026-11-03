# Wine 文档打开／保存时的进程创建阻塞

2026-11-03 至 11-04，在本机 MacSW 0.1.7 的 SOLIDWORKS 2025 现场观察到：
打开或保存文档后，Windows 主线程停在
`NtCreateUserProcess → spawn_process → fork()`，CPU 近 0%。
首次现场的两份采样一致。第二次使用进程日志复现，最后一条未返回的启动请求是
`winemenubuilder.exe -w ...\\Recent\\PowerInHolderB.SLDPRT.lnk`；当时用户经 Finder 的
“打开方式 → MacSW”打开文档，并非保存操作。

`SHAddToRecentDocs` 写入 Recent 快捷方式后，shell32 的 `IPersistFile::Save`
会同步调用 `CreateProcessW` 启动 winemenubuilder。助手负责宿主桌面／菜单及文件关联集成，
Recent 路径本身会被助手忽略。它不是 SOLIDWORKS 模型保存所需的组件。

MacSW 已自行处理 Finder 文件关联，因此统一设置
`WINEDLLOVERRIDES=winemenubuilder.exe=d`。App 的普通工具和 SOLIDWORKS 环境、
CLI、安装／升级运行时工具、运行门禁及本地探针均使用这一禁用项。
Recent 的 Windows 内部记录仍正常写入；未关闭 SOLIDWORKS 的最近文件功能。
这消除了本次已捕获的触发路径，尚未证明底层 fork 阻塞涉及的具体锁或 Rosetta 根因。

## 检查

独立 Wine 容器中，x86 和 x64 都验证 Recent 注册表记录及 `.lnk` 的真实目标路径：
启用助手的对照组确实创建助手进程；禁用组创建数为 0，Recent 数据保持正确。
可重新运行：

```sh
python3 -B scripts/diagnostics/verify_recent_docs.py \
  --app /Applications/MacSW.app \
  --evidence /private/tmp/macsw-recent-docs-evidence
```

需安装两个 MinGW 编译器。脚本仅操作临时容器，结束时停止该容器的 wineserver。

在禁用前，Git HEAD 模型及首次现场的磁盘模型副本各完成 3 次 API 保存，
错误／警告均为 0；另完成 12 次界面等价保存命令。这些通过结果并未复现原来的阻塞。
基础 AppKit 的 ARM64／Rosetta、0／64 线程 fork／posix_spawn 对照 800 次，
以及 Wine 0／64 线程 CreateProcess 对照 200 次也均通过，不能据此宣称任意负载下无死锁。

禁用后的实际 SOLIDWORKS 交互验收交由用户正常工作验证，不在后台自动操作文档。
原始现场、模型副本、调用日志及探针结果暂存于
`/private/tmp/macsw-save-stall-20261103`；项目未包含用户模型或本地崩溃转储。
