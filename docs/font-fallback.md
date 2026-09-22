# CJK 界面字体与回退

## 选择

MacSW 固定下载 Noto CJK `Sans2.004` 的 Noto Sans SC 区域包，只取 Regular、Bold 与 SIL Open
Font License 1.1。归档和三个解包文件均在 `config/versions.env` 固定 SHA-256；字体二进制留在
`dist/` 构建缓存，不提交 Git。当前只打包简体中文区域字形，日文、韩文、繁中/香港变体不随
中文安装无条件增加包体，后续可以沿同一目录和清单契约扩展。

没有直接依赖 macOS 苹方。Wine 的 macOS 字体后端会通过 CoreText 枚举宿主字体，但本机实测
`PingFang SC`、`PingFangSC-Regular` 与 `Hiragino Sans GB` 的 GDI 请求都回退为
`Microsoft Sans Serif`。苹方实际位于 FontServices 的 `Reserved/PingFangUI.ttc`，不能把
“CoreText 原生应用可使用”视为“Wine/FreeType 可按 Windows 字体名稳定打开”，也不能复制进
App 重新分发。可直接命中的 `STSong` 是宋体，不适合作为 SOLIDWORKS UI 默认字体。

## 安装

`make app` 在联网构建时下载并校验字体，放入：

- `Contents/Resources/fonts/NotoSansSC/NotoSansSC-Regular.otf`
- `Contents/Resources/fonts/NotoSansSC/NotoSansSC-Bold.otf`
- `Contents/Resources/fonts/NotoSansSC/LICENSE`

全新安装准备 Wine 容器时，App 再次校验包内哈希，原子写入 `C:\windows\Fonts`，并把字体
注册与现有 SOLIDWORKS 兼容设置合并为一次 `.reg` 导入。随后执行一次 `wineboot -u`，让 Wine
在官方 MSI 启动前重新建立字体缓存。该流程只属于安装环境准备，不在每次启动时改写旧容器。

注册表不把 Tahoma/System 整体替换成 Noto。Noto Sans SC 的 `usWinAscent/usWinDescent` 会使
同一 `-16` 请求得到约 24px 行高，而 Tahoma 约为 19px，直接替换会增加固定高度控件的裁切风险。
因此缺失的 Windows UI 族先归一到 Tahoma，再用 `FontLink\\SystemLink` 仅为 Tahoma、SimSun、
NSimSun 补充 Noto 中文字形；Wine 的 stock System 字体会继承 Tahoma 的链接。

Wine 11.16 的 `reg import` 对 `hex(7)` 与 Windows regedit 的行为不同：输入标准 UTF-16LE 会被
再次扩展成带交错 NUL 的损坏多字符串。MacSW 的注册表生成器只允许 FontLink 使用 ASCII 文件名
和族名，并按 Wine 实测的单字节 `hex(7)` 形式编码；XCTest 覆盖终止符、非法内容与最终映射。

## 已验证边界

临时全新 Wine 容器已验证：官方字体文件哈希一致、`REG_MULTI_SZ` 可被 Wine 正确查询、
`Noto Sans SC` 可由 GDI 创建，且链接后的 Tahoma 仍保持原来的约 19px 行高。SwiftPM 也覆盖
包内字体缺失、哈希损坏、已有旧文件替换以及重复执行。真实 SOLIDWORKS 全新安装后的完整界面
截图仍是独立验收，不由这些静态和最小 GDI 测试代替。
