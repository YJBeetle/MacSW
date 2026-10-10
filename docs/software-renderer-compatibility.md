# macOS 软件 renderer 兼容待办

这是独立的低优先级工作，不作为 SWCLI 主线的前置条件。Apple 软件 renderer、
SOLIDWORKS 的“软件 OpenGL”选项、`0008` 位图白图修复和托管 `CloseDoc` 异常
属于不同层面，不能将其中一项通过当成其余问题已解决。

## 已确认的托管环境

MacSW `76e4fcc` 的 [CI 37765558540](https://github.com/YJBeetle/MacSW/actions/runs/37765558540)
中，ARM64 和 Rosetta x86_64 都只枚举到一个未加速 renderer。主显示器加速和
任意加速 legacy 请求均在格式选择阶段返回 `10002`；自动选择和指定软件请求
均成功创建、绑定，报告 `Apple Software Renderer`、`2.1 APPLE-21.0.19`，支持
FBO、framebuffer blit、packed depth/stencil。

原 Wine `init_context()` 强制要求加速，因而 OpenGL 驱动初始化失败。八组
DIB/WGL 探针都停在 `create-context`，随后 loader 超过 60 秒期限；这轮没有
进入 SOLIDWORKS。上述证据不说明之前的 `CloseDoc / 0x800703e6` 已找到根因。

## 独立候选补丁

[`0009-winemac-software-renderer-fallback.patch`](../patches/wine-crossover/0009-winemac-software-renderer-fallback.patch)
在 `0008` 后应用，不重写 `0008` 的 FBO、像素转换或共享上下文实现：

- 首先保持原来的主显示器加速初始化请求。
- 仅 legacy 加速格式不存在（`kCGLBadPixelFormat` 或成功但无格式）时，尝试
  明确指定 `kCGLRendererGenericFloatID`；分配、创建、绑定错误直接失败。
- GL3/GL4 core 探测不降级为 legacy，版本与扩展继续读取实际 GL 上下文。
- 查询所选上下文的虚拟屏幕与 `kCGLPFAAccelerated`。只有实际选择了软件
  renderer 时才允许本次软件格式枚举，不写 `AllowSoftwareRendering` 注册表。
- 位图格式继承真实加速属性；软件格式通过原 Wine 描述路径报告
  `PFD_GENERIC_FORMAT`，不宣称硬件加速。
- 创建失败时不再绑定空上下文；查询或绑定失败释放临时资源，保留原上下文。

选取软件 renderer 的属性来自 Apple 的
[像素格式选择说明](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/OpenGL-MacProgGuide/opengl_pixelformats/opengl_pixelformats.html)。
它不等于启用 SOLIDWORKS 内部的“软件 OpenGL”。此前勾选后卡死的现象需要单独
调查；本补丁与验证都不更改用户这个选项，也不表示 Linux 已有相同能力。

补丁 SHA-256 接入 Wine 内部构建键、CI 的既有 `patches/wine-crossover/**`
缓存输入、`BuildManifest.plist` 的 `WineMacSoftwareRendererPatchSHA256` 与
`verify_app.sh`。独立 CGL mock 覆盖硬件优先、软件回退、core 不降级、空返回、
错误分类和资源释放；mock 不构成真实 renderer 或 SOLIDWORKS 验收。

## 验证边界

八组原生位图门禁保留全部像素、上下文、深度模板与状态恢复断言，并增加
实际 GL renderer/version 和 WGL 加速属性观察。Apple 软件 renderer 必须报告
`PFD_GENERIC_FORMAT` 和 `WGL_NO_ACCELERATION_ARB`；属性不符也是失败。

本机允许使用临时 CGL 测试夹具，拒绝加速格式选择来触发回退；其余软件 CGL
调用仍执行真实 Apple 实现。不增加产品强制软件开关，不将夹具注入发布 App，
也不把本机触发回退算作 CI-only 软件环境已通过。

## 本机验证：2026-10-08

在 M2 Max、macOS 15.8 上编译新的 Wine 模块，用临时 App 副本和用户授权的
主 bottle 验证。软件组通过临时 CGL interpose 拒绝加速格式选择，其余调用
仍进入真实 Apple CGL。这不是模拟 GL 返回值，也没有修改 SOLIDWORKS 内部
“软件 OpenGL”设置；夹具不进入产品构建、缓存或发布 App。

| 验证项 | 正常硬件路径 | 触发软件回退路径 |
| --- | --- | --- |
| 实际 GL renderer | Apple M2 Max | Apple Software Renderer |
| 实际 GL version | 2.1 Metal - 89.4 | 2.1 APPLE-21.1.1 |
| 八组位图门禁 | 8/8，GL error 0 | 8/8，GL error 0 |
| 像素格式加速属性 | `WGL_FULL_ACCELERATION_ARB` | `PFD_GENERIC_FORMAT` / `WGL_NO_ACCELERATION_ARB` |
| 共享建模 | 85 个事件，通过 | 85 个事件，通过 |
| 随后的共享尺寸 | 242 个事件，通过 | 242 个事件，通过 |
| SWCLI 报告的宿主 PID | 32，两项一致 | 1148，两项一致 |
| 清理错误 | 0 | 0 |

两组均为可见、daemon 独占的 SOLIDWORKS 33.5.0。每组的建模→尺寸使用同一个
daemon/SW 实例，未在两项间重启，未重试原生操作，也未修改共享断言。最终
文档列表为空，daemon 正常退出。硬件组首次调用因已有未修改的空白文档而被
共享测试的前置条件拒绝；该记录保留，关闭此空白文档后才开始上述连续测试。

运行基线是原 App 打包的 SWCLI `fb147c19e65a4d4b2a84e8e8c140c1589171c54e`，
共享脚本也从同一提交导出。硬件与软件证据保存在本机忽略目录
`build/diagnostics/renderer-20261008/`，包含 renderer 日志、共享测试 JSON、
失败的前置检查及最终退出记录；未上传主容器日志或模型。

`make winemac` 成功；四项新增离线测试包含 15 个真实补丁函数的 CGL mock
场景。补齐临时测试环境的 `jsonschema==4.26.0` 后，`make test` 通过：MacSW
Python 71 项（1 跳过）、Swift 141 项、当前 SWCLI 子模块 Python 621 项
（8 跳过）。完整 `make app` 则在打包前因已有 SWCLI 子模块 `4cde3b2…` 与
配置固定值 `fb147c19…` 不一致而停止；未改动此指针，也未将临时 App 当作正式
打包通过。新补丁的 manifest/校验接线已完成，但完整成品验证仍待版本一致后
执行。临时 App 副本和已编译的注入夹具已清理，正常 MacSW 已恢复，未部署
候选模块到日常 App。

## 剩余验收

### 扩充门禁的预算与时间日志（2026-10-11）

[成功运行 38049622744](https://github.com/YJBeetle/MacSW/actions/runs/38049622744)
同样报告 Apple Software Renderer；可见建模 175 个事件，用时 1630.6 秒，
可见尺寸 3122.7 秒。隐藏建模／尺寸分别 703.9／1247.0 秒，两个模式的
Toolbox 门禁也通过。这说明软件路径并非每次失败，不证明不存在偶发停滞。

[后续运行 38079035678](https://github.com/YJBeetle/MacSW/actions/runs/38079035678)
增加自建装配体与样例导出；超时前已完成 238 个事件、五组用例。最后的
`sketch.rectangle` 执行约 247 秒，原生边界仍持续返回，整套建模却被 1800 秒
总期限终止。因此不能将这两轮视为完全相同序列的随机成败，也不能仅凭该轮
认定死锁或确认纯性能原因。

按用户要求，将 MacSW CI 整套建模预算从 1800 加倍到 3600 秒，双模式共享步骤
从 225 调整为 300 分钟，仍在 360 分钟 job 期限内。单请求 300 秒、尺寸 3600 秒、
Toolbox 600 秒、原生调用超时与全部 CAD 断言不变；不重试或中途更换宿主。
这是预算调整，不是软件渲染故障修复，实际结果须由后续 CI 确认。

适配层从现有匿名 stdout 文件实时观察共享脚本的固定进度行，输出 UTC 时间、
本阶段累计耗时及距上一次进度的间隔，并保存 `shared-step-progress.log`。
时间基准明确为 `stdout-observed`（0.5 秒轮询）；它不是原生调用的精确耗时，
积压行可能在一次读取中被观察到。未识别的输出、参数、结果和 stderr 不转发。
每个外层命令在 `runtime.json` 保留开始／结束 UTC 时间和总耗时；非零退出与
真超时仍失败，日志观察错误不改变 CAD 结果，也不等待后台进程持有的管道 EOF。

后续 [CI 37790161984](https://github.com/YJBeetle/MacSW/actions/runs/37790161984)
已通过单元测试、构建、完整打包校验、真实安装和基底缓存保存。托管 Wine
确实回退到 `Apple Software Renderer` / `2.1 APPLE-21.0.19`，八组位图均输出
成功及真实无加速属性，但外层捕获命令在 60 秒处超时，因此整项门禁仍失败，
没有启动 SOLIDWORKS。这不构成共享建模或 `CloseDoc` 验收。

2026-10-09 将宿主日志接收改为私有匿名文件，等待真实子进程退出而非管道 EOF，
保留退出码、期限和所有断言。新增测试覆盖后台进程仍持有日志句柄、非零退出、
真超时和超时／退出竞态。该接线仍须新的托管 CI 验证；原运行未记录超时瞬间
的子进程状态，不能据此断言当时仅为管道假超时。
本机完整 `make test` 通过：MacSW Python 78 项（1 跳过）、Swift 141 项、
SWCLI Python 621 项（8 跳过）；离线测试不替代云端真实运行证据。

隐藏模式尚未验证。托管软件-only CI 还须依次通过八组位图、SOLIDWORKS 启动，
以及同一 daemon/SW 实例中的共享建模→尺寸门禁。继续遵守中途不重启、不重试
原生失败、不修改共享几何断言；某模式失败时保留证据，不继续后序尺寸门禁。

最终仍须在只存在软件 renderer 的托管 CI 获得上述证据。软件 OpenGL 2.1 的
能力、性能和稳定性都不能由原生上下文创建成功推定；硬件本机的历史通过也
不能作为新补丁或托管 `CloseDoc` 的完成证明。
