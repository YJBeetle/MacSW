# 中文界面字体

MacSW 优先使用 macOS 已提供给 Wine 的苹方，不下载、复制或随 App 打包 Apple 字体。
Wine 按系统语言登记字体，简体中文环境里的注册表值名通常是「苹方-简 …」；
安装程序因此在 Wine 的 Fonts 注册项中查找 PingFang.ttc 路径，而不依赖英文值名。
若系统尚未提供可用的苹方资源，SOLIDWORKS 安装仍继续，环境状态会提示中文可能显示不完整。

安装期将缺失的 Windows 界面字体名映射到 Tahoma，再把苹方加到 Tahoma 的
FontLink\SystemLink 首位，同时保留 Wine 原有的其他语言链接。这样只用苹方补缺失
字形，避免直接把 Tahoma 换成苹方后增大固定高度控件的行高。注册表文件采用带 BOM
的 UTF-16LE，REG_MULTI_SZ 采用标准 UTF-16LE hex(7)，中文别名不会乱码。
这些设置只在安装环境准备时写入，不在每次启动时重写已有容器。

如果容器里另有真实的微软雅黑、Segoe UI 等字体文件，Wine 可能直接命中它们而不走
苹方回退。此类历史手动安装的字体应单独备份、移出并清除对应注册项；MacSW 不会
在安装时删除用户已有字体。SOLIDWORKS 自带的工程字体不受影响。

验证范围：临时干净 Wine 前缀的 GDI 绘制已显示中文，Tahoma 的 -16 请求保持
约 19px 行高；注册表查询、编码和别名均有 XCTest 覆盖。SOLIDWORKS 完整界面、
字体粗细及固定高度控件仍需在最终 App 中验收。
