# Wine 11.21 隔离升级实验

- 基线：MacSW `eb41aca`（已提交的 SWCLI a16）；主工作区修改不带入。
- 工作区：`/private/tmp/macsw-wine1121/repo`，分支 `experiment/wine-11.21`。
- 克隆容器：`/private/tmp/macsw-wine1121/bottle`。APFS 克隆，重新生成独立 prefix ID；用户目录的 Desktop / Documents 等符号链接改为克隆内空目录。
- 实验 App 使用独立 bundle ID `com.macsw.wine1121.experiment`、固定实验数据根目录；关闭自动启动 SW、自动更新，不注册正式文件关联。
- Wine source SHA256 `5a40f593432d81fd3a1646db503f21ce42b8894d6d80c34c3a48b886edc54e3d`。
- Gcenx 11.21 devel runtime SHA256 `9909b486657e10ab66c7279371ae1f990345b596b3b1b3a0cf21f28af24fa0ce`，与 GitHub release asset digest 一致。

## 补丁决策

- 迁移 0002、0003、0004、0006、0009、0013、0019 到新接口。
- 0006 的 IME 入口已移到 `ime.c`；保留仅针对 SW 图形视口的空格行为。
- 0019 保留串行保护，使用上游新版本直接系统调用；不是删除 barrier。
- 0008 的驱动侧 FBO 实现由上游替代，win32u 的 24/32 位 DIB 转换逻辑仍需迁移保留；0011 由上游 PrintWindow surface copy 替代，并通过原有 110 项 aware / unaware 检查。
- 其他补丁包含 0021 热插拔，按既定顺序应用；保留 MSXML、字体、Finder、文件面板及禁止菜单助手行为。

## 已完成

Wine patched Unix / PE 模块、原生 Swift App 编译与打包成功。运行包哈希通过，克隆容器升级依赖检查通过。

- 8 / 16 线程 barrier 分别完成 4,000 / 8,000 次调用。
- MSXML schema 和空命名空间序列化探针通过。
- 上游 PrintWindow：DPI aware 和 unaware 各 110 项检查通过。
- 最初简化纯色探针只检查中间像素，曾误报位图通过；不能作为完整回归证据。原有八组探针复测时全部失败，已按下节修复。
- 屏幕取图：aware / unaware 各 16 项检查通过。
- 真实 SW 33.5.0：H_Casing 副本另存重开保留 10 项自定义属性；普通保存重开保留 11 项文档属性和 1 项配置属性，错误与警告均为 0。测试约 78.5 秒。原始文件 SHA256 `72793a36cef6bb6124f18260164c495bb166808b84aed968767b5fd44acf1d87` 未变。
- SWCLI a16 通过独立端口 `127.0.0.1:18921` 启动可见 SW；矩形 30×20 mm、拉伸 10 mm、保存 / 关闭 / 重开、STEP 导出成功。窗口截图确认模型正常显示。
- 11.21 运行包新增 GStreamer.framework 及 20 个原生工具，实验签名清单新增逐项策略，不泛化放行未知可执行文件。签名相关 70 项离线测试通过，包含新增框架依赖顺序、缺失 helper 和未知工具拒绝测试。

结果及完整原始日志：`probes/results.json`、`sw-regression.log`、`modeling/*.json`，均相对于实验根目录。

隔离阶段的本地临时签名已逐项完成，`codesign --verify --deep --strict` 通过；这不是 Developer ID 发布签名或公证。最终独立 App 和 SWCLI 会话已启动，打开已保存的测试方块。

## 位图像素错位修复

用户指出与旧 PDF 嵌入图片异常相似。旧报告 `docs/native-modeling-investigation.md` 的“bitmap-only FBO”章节明确记录了 24 位 BMP 条纹和转换修复。

Wine 11.21 的 `flush_memory_dc` 仍按 `biSizeImage / 4 / width` 计算高度，并将原始 DIB 直接按 BGRA 四字节传输。24 位图的字节边界 / 行方向因此错误，不是正常抖色或网点。0008 不能整体删除。

迁移只保留内存 DC + FBO 路径的 GDI 格式转换，使用 bottom-up 32 位 staging DIB；保持上游通用 FBO drawable。适应新的 root context / texture upload，显式保存和恢复 pack/unpack alignment、row length、skip rows/pixels、PBO 绑定，不依赖 core profile 不支持的 glPushClientAttrib。

- 原有 `scripts/diagnostics/check_bitmap_opengl.c` 修复前 0/8：24 位 initial-dib-upload 失败、32 位 row-orientation-and-pack-state 失败。
- 修复后 Apple M2 Max 8/8，Apple Software Renderer 8/8；覆盖全部像素、宽度 7/8、24/32 位、正反方向、深度模板、FBO、上下文及状态恢复，GL error 均 0。日志 `probes/full-bitmap-before.log` 和 `probes/full-bitmap-after-{auto,software}.log`。
- 3 项对应离线构建 / 转换契约测试通过。
- 同一真实 SW 模型重新导出 1024×768 BMP，逐图查看确认颜色和几何恢复正常；保留前后图 `modeling/wine1121-block{,-fixed}.{bmp,png}`。
- 独立 App 已重建、临时签名严格校验通过、克隆容器升级后重启。正式 App 和正式容器未替换。

## PDF 内嵌图片复测

在独立的 Wine 11.21 / SW 会话中，用实验方块创建临时 A4 工程图，插入等轴测视图并设为 shaded-with-edges，通过真实 `SaveAs3` 导出 PDF。确认 PDF 含实际 raster XObject，不能只用线框 / 矢量 PDF 代替验收。

- 最终文件 `pdf-regression/wine1121-shaded-layout.pdf`：1 页、75,561 字节、1 张 544×618 内嵌着色图片（提取为 RGBA PNG）。
- 用 pypdf 提取内嵌图片，pdftoppm 以 120 dpi 渲染整页，分别查看确认平面颜色连续、行方向正常、与轮廓吻合，没有再出现先前的条纹 / 像素错位。
- PDF 导出返回 0；临时图纸随后关闭，源方块仍为未修改状态，正式容器及用户原始模型未动。
- 原始导出脚本 / 日志、图片清单、提取图和整页渲染位于实验根目录 `pdf-regression/`。最终 PDF SHA256：`6cc7563b479b958fcf790465ed66ccba46fa4c3064821958e9dc51102c36e15f`。
- 此项是当前硬件渲染 SW 会话下的 PDF 验证；软件 renderer 已通过前述八组位图探针，尚未另跑真实 SW PDF 导出。

## 待验证

原生打开 / 保存面板、中文输入法、热插拔及长时间稳定性在隔离阶段未做完，正式阶段继续验收。

以上是隔离阶段记录；其后的正式集成及本机验收见下节。

构建日志和后续运行日志统一位于 `/private/tmp/macsw-wine1121`。

## 正式集成与本机验收（2026-11-06）

用户授权更新正式仓库、`/Applications/MacSW.app` 和默认容器后，将运行时迁移与新增 GStreamer 签名策略分别提交为 `40183e5`、`7cbd5d2`。保留主线后续 CI 摘要和 SWCLI 指针；没有带入实验 App 身份、数据根目录、独立端口或禁用更新设置。

退役 0011 本地补丁，构建清单明确使用 `WinePrintWindowImplementation=upstream-surface-copy`，不再写入失效的 opt-in 标志。21 个历史补丁中仍保留必要的 0008 格式转换，其他兼容修复继续按构建顺序应用。

- 正式仓库 373 项 Python 测试通过（1 skip），启动器路径/参数检查通过，13 项 RegistryService Swift 测试通过。
- 正式配置 App 重编译、打包校验和逐项 ad-hoc 签名完成，`codesign --verify --deep --strict` 通过。不是 Developer ID 发布签名或公证。
- 本机覆盖安装的测试候选标识为 0.1.11/build13，正式容器原地升级及 Mono/COM/Python/字体依赖检查通过。默认正式端口仍为 `127.0.0.1:18495`，真实可见 SW 33.5.0 启动成功。
- 用正式 App 在独立短生命周期探针前缀运行 x64/x86 原生文件面板 ABI：24/24 通过，覆盖控件、格式、只读菜单、多选、取消、缓冲区和回退。它不替代用户实际 AppKit 交互验收。
- 已安装 App 的 x64/x86 并发屏障，各 1/8 线程四项全部通过；探针临时前缀正常停止并清理。
- 正式容器中新建 30×20×10 mm 方块，建模、保存关闭重开、BMP 和 STEP 导出通过；测试文档正常关闭。
- 复杂 H_Casing 的实验副本三轮另存、关闭重开、添加属性、普通保存及再次重开全部通过。每轮 17.887 / 17.531 / 18.313 秒，保留 11 项文档属性、1 项配置属性；源副本 SHA 未变，无用户原始文件写入。
- 该短循环的 physical footprint 约 1.7 GiB → 1.8 GiB，峰值约 1.9 GiB。这不是长期泄漏或软件渲染内存回收结论。
- 软件渲染通过一次性进程环境选项启用；持久日志明确记录 SW PID 1780（`06f4`）的 `Apple Software Renderer` 和 `accelerated 0`。同一会话的真实 SW PDF 导出返回0，包含一张 544×618 图片，提取后与前一次软件配置导出像素完全一致；整页与提取图均检查正常。最终 PDF SHA256 `54b83759e6e7667813413bd7877813bf8bf3e1bde027032698517853c3798dc5`。
- 软件诊断后已关闭测试文档并重启恢复默认 renderer；该选项未写入注册表或用户偏好。

完整本机证据、脚本与日志位于 `/private/tmp/macsw-wine1121/integration/`。显示器物理拔插两轮记录 29 / 21 次通知，用户确认原先小区域拖动限制未再出现；窗口位置和最大化恢复差异另记在 `docs/display-hotplug.md`。随后用户完成了下述实际面板、中文输入和 Finder 交互验收；ABI 检查单独保留，不混作 GUI 证据。

### 0.2.0 定版边界

用户随后决定将 Wine 11.21、新 SWCLI 命令名和 MCP/skills 更新一起纳入 0.2.0，并明确要求暂缓发布。源码版本规划改为 0.2.0/build13，本机当前测试 App 仍是上述已验证的临时候选，后续需随最终 SWCLI/skills 重新构建。

当前固定 SWCLI c23792f/a16 已使用 `swcli` 命令，但仍使用旧 MCP 工具名。2026-11-06 只读核对远端主线 36e5799 的短工具名为 `status`、`daemon_start`、`daemon_stop`、`capabilities`、`execute`；对应公开版本与 MacSW 自有技能尚须对齐，不能只修改提示词使其引用当前包不存在的工具。

当前只做本地集成提交与验收，不触发签发、发布或替换公开 Release。正式版本须在最终 CLI/skills 固定后重新跑相应 CI，验收签名、公证与发布产物。

## 正式容器交互验收完成项（2026-11-06）

用户在上述正式容器、本地 ad-hoc 构建中完成：

1. 原生打开面板选择“以只读打开”，目标 `/private/tmp/MacSW-0.2-验收/验收零件.SLDPRT`；按精确路径枚举文档后，COM 返回 `IsOpenedReadOnly=true`、`GetSaveFlag=false`。
2. 原生面板保存中文文件名，并再次确认同名覆盖。最终文件 59,779 字节，自动关闭重开错误/警告均0，结构读取成功。
3. 格式选择 STEP AP214，“选项…”窗口打开正常；保存的 `中文导出验收.STEP` 为 13,484 字节，`FILE_SCHEMA` 为 `AUTOMOTIVE_DESIGN`，包含1个 `MANIFOLD_SOLID_BREP`。本轮没有额外声称所有 STEP 导入路径通过。
4. 切到中文输入法后，模型区域空格能够弹出视图方向；在 Wine 的 SW“属性→摘要”标题框使用输入法输入“中文验收”正常，随后取消。此项由用户实际操作确认，原生 AppKit 文件名输入不替代 Wine IME 验收。
5. 使用已安装的 x64 `SHOpenFolderAndSelectItems` 与 x86 相对 child PIDL 两条探针调用，均返回 `FINDER_BRIDGE_PASS`；用户确认 Finder 打开“Finder 定位验收”并选中“定位验收.txt”。
6. 两轮显示器热插拔探针最终均正常退出。原始小区域拖动限制未再出现；窗口回屏与最大化保持差异见显示器报告，仍不写成完全通过。

`integration/manual-acceptance.json` 汇总用户确认与对应原始文件。用户验收后 `document.list` 已为空，SW 保持默认渲染模式运行，未强制退出；两个诊断窗口已正常关闭。

同时使用与正式 App 相同的 `CommandLineToolService.perform(.install)` 迁移全局命令：操作前为 `legacyInstalled`，系统管理员授权路径只执行目录/链接操作，操作后为 `installed`。旧的、确属本 App 的悬空 `/usr/local/bin/sw-cli` 已移除；`/usr/local/bin/swcli` 指向 `/Applications/MacSW.app/Contents/MacOS/swcli`，真实 `swcli version --json` 返回 a16。没有修改其他同名工具或执行 Wine/App/Python 作为 root。此为实际服务与系统授权路径验证，不冒充设置按钮的自动点击验收。

剩余：长期稳定性/软件渲染内存趋势，以及 0.2.0 最终 CLI/MCP/skills 对齐后的重新构建与 CI。发布仍按用户要求暂停。
