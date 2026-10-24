# Developer ID Direct Distribution

## GitHub 自动更新

MacSW 使用固定校验和的 Sparkle 2.10.0 官方 SPM 二进制框架。菜单栏和设置页
提供“检查更新”，默认定期检查、允许用户关闭；不启用无人值守安装或系统画像
上传。稳定入口为 `https://github.com/YJBeetle/MacSW/releases/latest/download/appcast.xml`。
草稿、预发布版不应设为 latest；每个今后的正式 Release 都必须携带此附件。

第一次接入需手动安装含更新器的版本；已发布的 0.1.2 不会自动获得更新器。
`CFBundleVersion` 必须逐次递增，不用公开版本字符串代替构建序号比较。

### 一次性更新密钥

更新 EdDSA 密钥与 Apple Developer ID 证书／公证凭据不同，不能互相替代。
使用依赖解析后的官方工具生成专用密钥（会保存到本机登录钥匙串）：

```sh
build/swift/artifacts/bootstrap/Sparkle/bin/generate_keys --account MacSW
build/swift/artifacts/bootstrap/Sparkle/bin/generate_keys --account MacSW -p
```

将输出的公开 Base64 公钥填入 `config/sparkle-public-key.txt` 并随源码提交。
用同一工具 `--account MacSW -x <私有文件路径>` 导出私钥，仅将文件中的 Base64
内容设置为 `macsw-release` Environment Secret `SPARKLE_PRIVATE_KEY`，然后安全
保管或移除导出文件。不要再对导出的 Base64 文本进行一次 Base64 编码。
CI 仅接受新格式的 32 字节 seed，旧密钥不可不经转换直接复用。不得把私钥
贴到聊天、写入仓库、公开产物或日志；本机钥匙串保留恢复副本。

空公钥仅供开发构建使用，更新器不启动；正式签名验证拒绝空公钥、未知 feed
或无人值守安装策略。不能用占位公钥先发版，否则已安装版本无法验证将来的包。

### 发布顺序及校验

`sign-app.yml` 在生成最终签名、Accepted 公证并 staple 的 ZIP 后，执行
`scripts/ci/update-feed.py`：从密封 App 读取公钥，用 CryptoKit 核对私钥对应的
公钥，再使用校验和固定的 Sparkle `sign_update` 对最终 ZIP 签名。私钥通过
stdin 传递，不在命令参数或临时文件中保存。更新 feed 记录构建号、展示版本、
最低 macOS 版本、完整包长度、EdDSA 签名和不可变的 GitHub 标签下载地址。
源包、公钥或构建配置变化都必须重新构建／公证，不能修改已密封的 App。

候选 artifact 增加 `appcast.xml`。签发和 macOS 15 初始化两个 job 都成功后，
才能将 App ZIP、`appcast.xml`、`release-info.zip`、Wine/Mono 源码及包含这些
附件的 `SHA256SUMS` 上传到 Release 草稿；核验齐备后才公开并设为 latest。
不单独覆盖当前 latest 的 feed 指向尚未公开或尚未通过签发的新版。
CI 四份原始 JSON 和 ZIP `.sha256` 仍保留，仅公开 Release 的 JSON 合并显示。

### 安装前保护与验证边界

更新替换整个 App（含 Wine／Mono），不删除外部 bottle 或文档。安装／迁移／
服务操作进行时不开始检查更新；更新触发退出时重新读取真实进程清单，清单
读取失败也拒绝继续。若 SW、CLI 或任何非已知基础服务仍在运行，提示先保存
并正常退出，不为了更新强杀。只剩 wineserver 与托管 FlexNet 时才沿用已有
收尾流程停止服务并确认容器退出。安装后启动仍走既有 Wine 身份和迁移检查，
不绕过升级／备份提示。保护覆盖立即安装和安装后退出的路径。

本地验证：Swift 206 项、Python 310 项（跳过 1）通过；真实 Sparkle 框架打包／
五个原生组件清单核验通过；测试密钥的实际签名、验签及篡改拒绝通过。
这些不代表生产密钥已配置，也不代表两版正式签名 App 之间的下载、退出、替换、
重启及迁移端到端验收通过。发布前仍需该项验证，不以单测或公证替代。

目标是 Mac App Store 之外的直接分发，而非 App Store 沙盒或商店上传。
当前新增流程仅由 `sign-app.yml` 手动运行，生成 CI candidate，不创建
GitHub Release，也不修改本机主 App、主容器或默认开发打包流程。

## 签发前的保护

先创建 GitHub Environment `macsw-release`，配置 required reviewers，且只
允许 `master` 部署。以下 Secrets 应放在该 Environment，不能提交到仓库、
贴到聊天、放入缓存或 artifact：

| Secret | 内容 |
| --- | --- |
| `SIGNING_CERTIFICATE_P12_BASE64` | 包含 Developer ID Application 证书和私钥的 P12，Base64 |
| `SIGNING_CERTIFICATE_PASSWORD` | P12 导出密码 |
| `NOTARY_API_KEY_BASE64` | 可选；App Store Connect **Team** API Key 的 P8，Base64，优先使用 |
| `NOTARY_APP_PASSWORD` | 未配置 API Key 时使用的 Apple Account App 专用密码，不是账户主密码 |

Environment Variables：`SIGNING_TEAM_ID`、`SIGNING_IDENTITY`（完整的
Developer ID Application 身份名）。使用 API Key 时另需 `NOTARY_KEY_ID`、
`NOTARY_ISSUER_ID`；只使用账户方式时不需要它们。
账户方式另需 `NOTARY_APPLE_ID`，可放 Secret 或 Variable（Secret 优先）；
Variable 不会自动掩码，介意邮箱出现在日志中就保留 Secret。
API Key 未配置时才使用账户方式；已配置但字段不完整或认证失败时直接报错，
不自动降级到其他账户。两种方式先验证并存入临时钥匙串，后续提交和查询
只引用该钥匙串内的 profile。Apple 账户需有对应开发者团队的公证权限；
Developer 角色即可，账户需开启双重认证后生成 App 专用密码。
参考 [Apple 公证认证](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)。
登录 Xcode 账户不等于这些 CI 凭据已配置；证书不能替代公证凭据。
配置 Environment 保护后再存入 Secrets，导出私钥须由账号持有人确认。
参考 [GitHub 临时钥匙串流程](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)。

默认流程：同一个 master 提交先完成 Build & Package 的轻量可见冒烟，
普通 master push 默认执行；手动选择 `verify_solidworks=true`、
`runtime_stage=full`、`runtime_profile=visible-smoke` 也可。
必须通过 runtime job 的 `Lightweight visible SOLIDWORKS smoke` 步骤；
缺失、失败、跳过或重复的 job／步骤均拒绝。只构建或只安装成功不算通过。
Mac 轻量冒烟显式给共享门禁传入 600 秒单请求预算（共享默认仍为 120 秒），
保留 900 秒整轮保护、原始断言和失败即停止；证据必须确认实际使用了该预算。
`runtime_profile=hidden-full` 是独立手动诊断，结果不作为签名／公证的前置条件，
也不能拿该运行的构建产物替代轻量构建输入。签名仍检查选定轻量 run 成功、
同一提交、可信来源及产物哈希；它不查询其他诊断 run。
再手动运行 Developer ID Direct Distribution，传入该 build run ID。
不接受其他提交、fork、PR、失败构建、仅安装验证或过期产物；核对服务端
artifact SHA-256 后才解开 App ZIP。仍未配置凭据时流程应失败，不退化为
ad-hoc 签名，不跳过公证。

用户明确授权快速发布时，可在手动签发中设 `skip_runtime_check=true`。
该选项默认关闭，只跳过安装／可见冒烟及整轮 run 成功的等待，仍要求唯一的
`Build & package` job 成功、可信 master 来源、同一提交及产物哈希。来源记录
中的 `runtime_verification.result` 标为 `skipped-by-manual-override`，不能据此
宣称运行冒烟通过；Release 说明也应披露此边界。正式签名、公证、票据和签名包
的原语／跨系统初始化校验不受此选项影响，后台安装测试可独立继续。

## 嵌套代码和签名顺序

`scripts/sign_app.py inventory --app <staging/MacSW.app>` 只读取包。
按实际 Mach-O 头识别 Wine `.so`、Python 扩展、dylib 和通用二进制；Windows
PE、脚本、普通资源由外层签名封装，不做苹果代码签名。内部相对符号链接
不会重复签；外部、绝对、损坏的链接以及未知可执行文件/嵌套代码包会拒绝。
`sw-cli` 脚本存放在 `Contents/Resources/sw-cli`，原命令入口
`Contents/MacOS/sw-cli` 是指向它的包内相对符号链接。两处入口的运行时路径
解析保持一致；不单独给脚本签名或依赖扩展属性保存其签名。签名前 inventory
拒绝 MacOS 代码目录里的普通非 Mach-O 文件，新增本机可执行程序仍须审查策略。

Wine 混合运行时存放在 `Contents/Resources/Wine`，`Contents/Frameworks/wine`
保留为指向它的包内相对链接。Wine 内部目录、Mono/Gecko 版本名及 Vulkan
配置文件的相对位置不变，App、CLI、模块哈希和容器升级仍可使用原入口。
这避免 `icd.d` 等带点的数据目录在 Frameworks 中被误当作代码包。
inventory 扫描真实 Resources 目录，逐个签名并验证其中的 Mach-O；不跟随
目录链接重复签名，不放宽未知本机代码或库的允许范围。资源封装也覆盖
Windows PE 与数据；外层 `--deep` 校验不能替代上述逐个原生签名检查。

1. 所有原生库和 Python 扩展先签名，再签辅助可执行程序。
2. 更新 BuildManifest 的 `WineMacModuleSHA256`、`WineInputModuleSHA256`、
   `WineNtdllModuleSHA256`、`WineLoaderSHA256` 四个签名后实际文件哈希。
   不更改 PE/Mono/source 下载哈希，不放宽模块或 Windows Python 清单校验。
3. 最后签外层 App，严格核对 Developer ID、Team、时间戳、Hardened Runtime
   和精确的 entitlement 策略。签名不用 `--deep`，仅外层校验使用它。

Wine 两个 loader 需要运行未签名的 Windows PE / Mono JIT 机器码，因此候选
策略仅给这两个进程 `allow-unsigned-executable-memory`；不关闭 library
validation，也不给所有程序套同一份宽松权限。MacSW 主程序只保留启动终端
所需的 Apple Events 权限。wineserver、7zz、原生 Python 默认无例外权限。
具体适配仍以正式签名后的实测为准，不能把候选策略当成已验证结论。

macOS 15 上，允许匿名可执行内存不代表允许直接把未签名 PE 文件页设为
可执行。v0.1.0 初始正式包（build 1）可在全新容器中复现 `wineboot` 返回 53；详细日志是
`wineboot.exe` / `ntdll.dll` 的 `.text` 页执行权限设置失败，而非缺少目录。
`0015-ntdll-probe-executable-file-mappings.patch` 在 macOS 映射可执行 PE
节时提前请求执行权限，使 `mmap` 的 EACCES/EPERM 进入既有读取回退；私有
代码页改用匿名内存，保留最终节权限及共享可写映射语义。无需新增 JIT、
关闭代码页保护或关闭库验证权限。补丁、重编译的 `ntdll.so` 均纳入构建缓存、
打包及 BuildManifest 校验，不能只修改开发机上的运行时。

## 公证与最终 ZIP

使用临时钥匙串与 0600 的凭据文件，错误输出不打印密码或私钥。显式限定
`codesign` 可访问私钥；`finally` 清理，并有 `always()` 步骤兜底。任务取消
或主机被终止时仍依赖 GitHub hosted runner 的销毁，不使用自托管机器。
创建钥匙串前保存原用户搜索列表，将临时钥匙串加入列表但保留原有条目；
不改变默认钥匙串、信任设置或使用 `security import -A`。即使指定
`codesign --keychain`，证书链构建仍会查用户搜索列表。清理时先恢复并核验
原列表，再删除临时钥匙串；0600 的恢复记录仅留在私有凭据目录，支持
独立的 `always()` 清理重试，绝不上传。

签发先在指定临时钥匙串中匹配配置的 Developer ID 身份，要求唯一有效证书，
再以该证书指纹传给 `codesign`，避免名称查找差异；正式签名后仍严格核对 Team、
Developer ID、时间戳、Hardened Runtime 与 entitlement。
改动 App 前先编译一个最小原生可执行文件，用同一钥匙串和证书签名，
验证上述签名属性（无例外 entitlement）并执行。失败立即停止，不签 App、
不提交公证；日志区分编译、签名、验证和执行阶段，探针文件自动清理。
签发诊断只输出指定身份是否存在、有效签名身份数量，以及 `codesign` 的阶段、
包内相对目标、退出码和固定错误分类。原始 stderr、命令参数、证书／私钥及
密码不进入日志；未识别的签名错误明确记为 `unclassified`，不据此猜测原因。
清理额外文件时记录受限钥匙串文件名和不跟随链接的文件类型；未知文件名隐藏，
只额外允许由本次钥匙串 basename 精确推导的原生 `.fl…` 锁文件，
不允许任意 `.fl*`／sidecar 或符号链接，仍拒绝删除其他白名单外文件。
锁文件规则来自 [Apple Security 实现](https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_filedb/lib/AtomicFile.cpp)。
Base64 继续要求单行，不增加多行兼容。

签名后验证 native Python 导入/libffi callback、7zz、隔离 Wine prefix 中
CCW、MSXML 和 x64 BTLS 原语。原语沿用现有测试，不包含延后的 x86 BTLS 调查。
Wine 初始化使用与安装器一致的 `interp` 环境及绝对路径
`C:\windows\system32\wineboot.exe -u`，要求全新容器中部署有效的系统 PE
文件，再实际执行 x64 / x86 `cmd.exe` 并匹配完成标记。初始化单项限时 240 秒，
其他原语仍是 120 秒；不能用裸命令经 Shell 回退的零退出码代替初始化成功。
再次验签，确认测试没有改动密封 App。公证只接受 `Accepted`，保存公证结果
和日志，给 App staple 票据、validate、验签、Gatekeeper assess，再重新打
最终 ZIP 和 SHA-256。ZIP 本身不 staple。
参考 [Apple 自定义公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。

签发后另在 `macos-15` runner 下载同一工作流产生的最终签名 ZIP，校验
SHA-256、Developer ID / Team / 权限及公证票据，执行上述 `--bootstrap-only`
回归后再验签。该 job 不接触签名或公证凭据，不安装 SOLIDWORKS，不修改密封包；
失败将使整个签发工作流失败。签发 runner 上的原语通过不替代跨系统初始化验证。

## 验证边界与后续

离线单测和只读 inventory 不证明正式签名可运行；原语测试也不等于完整
SOLIDWORKS GUI/CAD 门禁。当前完整 CAD CI 在原始 ad-hoc 构建上运行，往 App
内部添加 CI helpers，不能原封不动用于正式签名包。第一次 candidate 通过
后，仍需在不改密封包的条件下验证签名 App 启动、实际 SW、终端权限和
Toolbox/装配体保存重开，然后再接自动 Release 发布。

`build-app.yml` 不再响应 tag 或写入 Release，已移除旧的未公证 ZIP 自动发布
路径。普通 build artifact 不能称作正式签名包。发布仅消费签发工作流全部
成功后的最终 ZIP；覆盖既有版本时也必须同步标签、校验和、公证日志及来源
记录，不能混用旧 ZIP 与新清单。v0.1.0 修订包使用 build 2 区分初始包。
公开发布时还要同时保留对应 Wine/Mono source archives，不能因为换了签名
ZIP 就丢掉现有开源运行时的源码分发。
