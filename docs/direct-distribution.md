# Developer ID Direct Distribution

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

首次运行：同一个 master 提交先完成 Build & Package 的完整运行门禁，
再手动运行 Developer ID Direct Distribution，传入该 build run ID。
不接受其他提交、fork、PR、失败构建、仅安装验证或过期产物；核对服务端
artifact SHA-256 后才解开 App ZIP。仍未配置凭据时流程应失败，不退化为
ad-hoc 签名，不跳过公证。

## 嵌套代码和签名顺序

`scripts/sign_app.py inventory --app <staging/MacSW.app>` 只读取包。
按实际 Mach-O 头识别 Wine `.so`、Python 扩展、dylib 和通用二进制；Windows
PE、脚本、普通资源由外层签名封装，不做苹果代码签名。内部相对符号链接
不会重复签；外部、绝对、损坏的链接以及未知可执行文件/嵌套代码包会拒绝。
目录布局不变，新增本机可执行程序必须先审查签名策略。

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

## 公证与最终 ZIP

使用临时钥匙串与 0600 的凭据文件，错误输出不打印密码或私钥。显式限定
`codesign` 可访问私钥；`finally` 清理，并有 `always()` 步骤兜底。任务取消
或主机被终止时仍依赖 GitHub hosted runner 的销毁，不使用自托管机器。

签名后验证 native Python 导入/libffi callback、7zz、隔离 Wine prefix 中
CCW、MSXML 和 x64 BTLS 原语。原语沿用现有测试，不包含延后的 x86 BTLS 调查。
再次验签，确认测试没有改动密封 App。公证只接受 `Accepted`，保存公证结果
和日志，给 App staple 票据、validate、验签、Gatekeeper assess，再重新打
最终 ZIP 和 SHA-256。ZIP 本身不 staple。
参考 [Apple 自定义公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。

## 验证边界与后续

离线单测和只读 inventory 不证明正式签名可运行；原语测试也不等于完整
SOLIDWORKS GUI/CAD 门禁。当前完整 CAD CI 在原始 ad-hoc 构建上运行，往 App
内部添加 CI helpers，不能原封不动用于正式签名包。第一次 candidate 通过
后，仍需在不改密封包的条件下验证签名 App 启动、实际 SW、终端权限和
Toolbox/装配体保存重开，然后再接自动 Release 发布。

原 `build-app.yml` 的 tag 发布仍属于旧的未公证打包路径；切换正式发布前
必须撤掉旧路径，并让自动发布只消费通过签发和真实运行验收的最终产物。
本阶段没有改变它，不能把普通 build artifact 称作正式签名包。
公开发布时还要同时保留对应 Wine/Mono source archives，不能因为换了签名
ZIP 就丢掉现有开源运行时的源码分发。
