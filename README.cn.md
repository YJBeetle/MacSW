# MacSW

[English](README.md) | **简体中文**

在 Apple Silicon Mac 上安装、运行和维护 SOLIDWORKS 的独立 macOS 应用。
MacSW 将固定版本的 Wine、兼容性修复和 [SWCLI](https://github.com/YJBeetle/SWCLI)
打包进 `MacSW.app`，提供引导安装、菜单栏启动器和命令行自动化入口。
使用构建好的 App 不需要源码目录、Homebrew、单独安装 Python 或外部启动脚本。

MacSW 是独立项目，与 Dassault Systèmes 或 SOLIDWORKS 没有关联，也未获得其认可或支持。
项目不提供 SOLIDWORKS 安装介质或许可，也不提供修改其官方程序文件的产品功能。

## 要求与验证范围

- Apple Silicon Mac，以及用于运行包内 x86_64 Wine 的 Rosetta 2。
- 应用最低部署目标为 macOS 13；具体实测系统和功能范围见[兼容性报告](docs/compatibility.md)。
- 自行准备 SOLIDWORKS 官方安装介质及适用的许可配置。
- 为 App、安装容器和安装过程预留磁盘空间；重装前备份容器里的文件。

当前仍是开发中的测试包，采用临时签名，未做 Developer ID 签名与公证。
SOLIDWORKS 2025 SP5.0 的安装、主窗口和部分交互已有实机验证，但不能据此认定
所有组件、插件或建模流程都受支持。SWCLI 随包固定到开发快照，也不代表该版本已正式发布。
安装成功、启动成功和完整自动化测试通过是不同的验证结果；详情分别见
[兼容性报告](docs/compatibility.md)和[真实运行 CI](docs/runtime-ci.md)。

## 安装与使用

**重装前先备份：干净安装会清空 MacSW 的唯一容器，包括其中保存的模型。**

1. 从 [GitHub Actions](https://github.com/YJBeetle/MacSW/actions/workflows/build-app.yml)
   的构建产物 `MacSW-macOS-App` 获取 App 压缩包，解压后将 `MacSW.app` 放到自己的应用目录。
   也可以[从源码构建](#源码构建)。
2. 打开 App。尚未安装 SOLIDWORKS 时会显示引导安装窗口。
3. 拖入或选择官方介质：ISO、`setup.exe`，或包含安装程序的目录。
4. 确认组件序列号、界面语言和许可服务器配置，然后开始安装。
   默认以静默部署模式执行；设置中可以切换到官方安装向导。
5. 安装完成后，从 MacSW 菜单栏图标启动 SOLIDWORKS。

默认打开 MacSW **不会自动启动 SOLIDWORKS**；可在设置中启用自动启动。
设置还提供 Wine 工具，以及许可服务器地址和托管 FlexNet 的安装、卸载、启动、停止。
托管服务器安装后复制到容器内，不再依赖最初选择的外部目录；启动 SOLIDWORKS 前，
MacSW 会按当前许可配置确保所需的本地托管服务运行。

中文界面使用 macOS 的苹方补缺失字形，不随 App 打包 Apple 字体。
打开 MacSW 时会在后台检查已安装容器的 Tahoma 字体链接，缺失时补回，保留原有回退项；
随后启动 SOLIDWORKS 会等待同一个准备任务。详见[字体说明](docs/font-fallback.md)。

## SWCLI 快速开始

App 内置 `sw-cli`，用于文档与零件自动化。**先启动 daemon，再执行文档操作**；
`document` 和 `part` 命令不会隐式拉起 SOLIDWORKS。

菜单栏的“复制 AI 接入信息”位于 SOLIDWORKS 操作和“查看日志”之间。将复制的文字发给
具备本地文件读取和终端能力的 agent，即可提供当前 App、CLI、完整 skill、指南、
容器及端点配置。skill 安装由 agent 按自身机制和用户授权完成；MacSW 不修改其配置。
复制不会执行检查命令、启动 Wine／SOLIDWORKS 或创建容器，也不代表 daemon 已就绪。

以下示例假设 App 位于 `/Applications/MacSW.app`；其他位置请修改第一行。

```bash
SWCLI="/Applications/MacSW.app/Contents/MacOS/sw-cli"

# SOLIDWORKS 尚未运行：创建可见实例；省略 --visible 则隐藏
"$SWCLI" daemon start --visible --json

# 启动命令等待宿主就绪后，再操作文档
"$SWCLI" document list --json
```

如果 SOLIDWORKS 已由 MacSW 启动，改用以下启动命令附着现有窗口，不创建第二个实例：

```bash
"$SWCLI" daemon start --attach-existing --json
```

没有 daemon 时，文档和零件命令返回 `DaemonUnavailable` 和启动提示。
本地路径按当前容器的实际盘符映射转换，不假定存在 Z:；没有可用映射就明确失败。
容器 `drive_c` 内的模型应通过对应的 C: 路径访问，不使用 Z: 别名。
更多命令和协议说明见 [SWCLI 中文文档](Dependencies/SWCLI/README.CN.md)。

## 数据与故障排查

MacSW 固定使用一个容器，不提供容器切换：

```text
~/Library/Application Support/MacSW/bottle
~/Library/Application Support/MacSW/logs
```

**干净安装会清空唯一容器。** 请先备份其中的模型和其他需要保留的文件。

安装失败先查看 `install_msi_errors.log`、`install_msi.log`、`prerequisites.log`；
启动问题查看 `sw_launch.log`。Login Manager、语言安装和 Wine 安装器也有独立日志。
反馈问题时请说明 MacSW 构建、macOS/芯片、SOLIDWORKS 版本、容器是否全新，以及复现步骤。

**不要直接公开完整日志或容器。** MSI 详细日志可能明文包含序列号；分享前清除
序列号、许可文件、凭据、用户名及私人路径。日志目录应保持私人。

## 源码构建

开发构建需要支持 Swift 5.10 的 macOS 工具链/SDK、Xcode Command Line Tools 和 Homebrew。
先检出源码及子模块，再执行：

```bash
git clone --recurse-submodules https://github.com/YJBeetle/MacSW.git
cd MacSW
brew install bison mingw-w64
make app
```

产物为 `build/app/MacSW.app`。首次构建联网获取并校验固定依赖，后续复用 `dist/` 缓存。
测试、打包流程、安装实现和 Wine 修复见[开发说明](docs/development.md)。
GitHub Actions 的 `build` job 分步执行 `make test` 和 `make archive`；独立的
`runtime-test` job 下载本轮构建的 App，执行隔离的真实安装/运行验证，不重新编译。
本仓库 master 的相关 push 自动运行，也支持手动触发；PR 不调用私有运行资源。

## 文档

- [开发与构建](docs/development.md)
- [兼容性与实测范围](docs/compatibility.md)
- [真实安装与运行 CI](docs/runtime-ci.md)
- [中文字体回退](docs/font-fallback.md)
- [树控件图标间距与裁切修复](docs/treeview-layout.md)
- [视口图层裁剪](docs/winemac-opengl-child-clipping.md)
- [OpenGL 前缓冲与预选修复](docs/opengl-front-buffer.md)
- [原生建模调查与离屏 BMP 绘制](docs/native-modeling-investigation.md)
- [中文输入法与模型视图快捷键](docs/solidworks-space-ime.md)
- [SWCLI](Dependencies/SWCLI/README.CN.md)

## 许可证

MacSW 原创代码使用 [Apache License 2.0](LICENSE)。Wine 及直接修改或派生自 Wine 的
[补丁](patches/wine-crossover)继续使用 LGPL-2.1-or-later；第三方组件保留各自许可证。
二进制发行包附带相应许可证、版权声明与 Wine 精确源码获取说明。

项目名称、Logo 和其他标识的归属及第三方说明见 [NOTICE](NOTICE)；
Apache-2.0 不授予将修改版或再发行版本表示为 MacSW 官方发布的品牌使用权。
