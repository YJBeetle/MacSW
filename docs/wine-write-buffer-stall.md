# macOS / Rosetta 并发进程内存屏障阻塞

2026-11-05 本机 SOLIDWORKS 2025 SP5.0（33.5.0）的特征解除压缩现场中，
原生采样发现 8 个线程同时停在 Wine `NtFlushProcessWriteBuffers` 的
`thread_get_register_pointer_values → thread_get_state` 路径。主程序 CPU 接近 0，
physical footprint 约 2 GiB；现场没有持续计算或内存增长的证据。
Wine 调试器能列出进程，但附加现场不返回；MiniDumpWriteDump 也未完成。
这些诊断请求因此没有被当成成功的 Windows 调用栈证据。

## 对照与范围

使用同一份磁盘模型的副本、同一默认配置和精确的 11 个已压缩特征：

| 操作 | 原版 Wine 11.16 | 加串行化补丁 | Windows 原生 SW |
| --- | --- | --- | --- |
| 直接打开后批量解除压缩 | 8 轮通过 | — | 8 轮通过 |
| 先另存为，再批量解除压缩 | 第 1 轮不返回 | 实验构建 8 轮通过，2.005–3.143 秒；完整打包构建另 2 轮通过 | 6 轮通过，2.756–2.936 秒 |

每轮检查实际选中的特征、解除压缩后的状态，并关闭自己的测试文档。
模型复制到独立容器；没有保存、修改用户原始模型，也未替换系统 App。
模型不加入仓库。

独立 C 探针无需 SW：8 个 Windows 线程同时重复调用该屏障，每线程 500 次。
旧实现出现超时；串行化实现完成全部 4,000 次。修复后的 x64 与 WoW64 x86
单线程／8 线程用例均通过，探针也检查每个工作线程的返回值与总完成数。
这提供了不依赖商业模型的进展性回归，并不单独证明所有内存排序语义。

## 修复

`0019-ntdll-serialize-process-write-buffer-flush.patch` 仅给 macOS 实现的
寄存器查询循环加进程内互斥锁，阻止多个屏障调用同时进入该循环。
每次调用仍遍历所有已枚举线程、执行原来的屏障请求，并释放 Mach 端口和数组；
没有将屏障改为本地 fence 或空操作，也没有修改 Linux 路径。
构建缓存、BuildManifest 与打包校验均包含新补丁。

本次实验定位到并发路径，并验证了上述最小修正；尚未确定 Rosetta／内核中具体的
循环等待机制，也不能将此前 fork 或软件渲染内存积累等其他现场一并归为此问题。
Windows 与 Wine 先另存为的区别解释了只测“直接打开”时未能复现。

## 运行回归

```sh
python3 scripts/diagnostics/verify_write_buffers.py \
  --app /Applications/MacSW.app \
  --evidence /private/tmp/macsw-write-buffers-evidence
```

需要两个 MinGW 编译器和 Rosetta。脚本只创建并停止自己的临时 prefix，
不启动 SOLIDWORKS；不复用已有证据目录。每个探针有 30 秒进程内 watchdog，
外层另有 60 秒期限。原版对照预期非零退出，这不是可以跳过的断言。
开发时可以用 `--runtime /path/to/prepared/wine` 代替 `--app`。
CI 在打包后执行，日志与结果单独上传。完整源码构建、工作区 App 打包校验、打包后四项探针均已通过；
351 项 MacSW Python 回归通过（1 项跳过）。单独混入新 ntdll 的临时运行时
曾发生初始化失败，不作为最终验收产物；完整打包 App 的全新 prefix 初始化通过。

原始采样、原版／修复版模型 JSONL 和独立探针结果位于本机
`/private/tmp/macsw-current-stall.qXKtGY`，不包含在发布包中。
