# MCP daemon utilities 启动器修复

MacSW 的 SWCLI 固定到 3eba5c42776c6714d1a36a6458fab47aa7c3ff6d（0.1.0a16），包含 1204621 的 Windows 单元断言修复和新的宿主启动器管道 EOF 修复。纯原生客户端包装脚本与单独 Wine daemon utilities 的边界保持。

DockerSW [42116004763](https://github.com/YJBeetle/DockerSW/actions/runs/42116004763) 的宿主实际已开始工作，但常驻 Wine 后代继承了启动器的 stdout/stderr，PIPE 捕获等到启动预算结束才返回，随后入口退出中断容器测试（137）。现改用私有临时文件，只等待启动器进程；启动预算、原生时限、无失败重试及宿主所有权检查不变。完整源码 1600 项单元测试通过，21 skip。

SSH workspaceroot 隔离 Wine 11.16 / Windows Python 3.11.9 最小复现：PIPE 的父启动器 0.816 秒退出，捕获调用到 4.060 秒才返回；临时文件方式在 0.616 秒返回，后台子进程仍运行。未启动 SW，临时容器已正常退出并移除。原始 probe-results.json SHA-256：eccc915099d1f980764fde8ec8a97ad305d58ec100b9f0b53a9800f2bdb8e21d。

默认 MacSW App/bottle 的实际 MCP 启停验证另行保留原始回执，不能把最小复现或单元测试当作 App/Wine 真实接受结果。此次源码指针更新没有申请 Apple 公证或发布 App。
