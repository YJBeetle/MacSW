# SolidWorks 2025 on macOS (Apple Silicon) via Wine/CrossOver 技术设计文档

## 1. 背景与目标

### 1.1 背景
SolidWorks 2025 是一款深度依赖 Windows 体系结构的大型 3D CAD 工程设计软件，其底层紧密集成：
- Microsoft .NET Desktop Runtime / .NET Framework 4.8+
- Visual C++ 2015–2022 Runtimes
- Visual Studio Tools for Applications (VSTA) & VBA 7.1
- Microsoft Access Database Engine (ACE/DAO)
- SolidWorks FlexNet 授权守护服务 (`lmgrd.exe` / `sw_d.exe` 监听 TCP 25734)
- 强化 3D 图形渲染引擎 (基于 DirectX 11 / Direct3D 11)

传统在 Wine / Linux 环境直接运行官方安装向导（`sldim.exe`）时极易遭遇安装器白屏、死锁和 WMI/RPC 错误。目前用户已在 Parallels Desktop 的 Windows 虚拟机中完成安装与激活，并将核心程序、数据文件及注册表导出到了工作区，具备通过“整机抽取与容器重构”在 Wine 中运行的先决条件。

### 1.2 目标
在 Apple Silicon (arm64) macOS 环境下，借助 CrossOver 26.3.0（支持 64 位 Wine、Apple Metal、D3DMetal 及 Rosetta 2 转译）构建专用的 SolidWorks 2025 运行容器（Prefix），完成环境初始化、依赖注入、文件布局、注册表导入、授权绑定及 3D 渲染适配，尝试启动 `SLDWORKS.exe` 并排查运行故障。

---

## 2. 运行环境与技术栈架构

- **宿主系统**：macOS 15.x (Sequoia), Apple Silicon (arm64), Rosetta 2
- **兼容层核心**：CrossOver 26.3.0 (`/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine`)
- **图形转译后端**：Apple D3DMetal / DXVK 2.x (DirectX 11 -> Metal)
- **容器路径 (WINEPREFIX)**：`/Volumes/Data/Workspace/WineSW/bottle`
- **抽取数据源**：
  - `C/Program Files/SOLIDWORKS Corp/SOLIDWORKS`
  - `C/ProgramData/SOLIDWORKS`
  - `C/SOLIDWORKS Data`
  - `C/opt/SolidWorks_Flexnet_Server`
  - `C/SWHKLM.reg` 与 `C/SWHKCU.reg`

---

## 3. 详细设计与步骤分解

### 3.1 容器规划与初始化
- 创建 64 位 Windows 10 兼容模式容器：
  - `WINEARCH=win64`
  - `WINEPREFIX=/Volumes/Data/Workspace/WineSW/bottle`
- 初始化 Wine 基本结构并验证 `wineserver` 通信。
- 配置 Wine 注册表环境，设置 Windows 版本为 Windows 10 (Version 21H2/22H2)。

### 3.2 依赖运行时注入
SolidWorks 主程序依赖核心动态库和基础组件：
1. **Visual C++ 2015-2022 Redistributable (x64 & x86)**：
   - 提取或安装 MSVCP140, VCRUNTIME140, UCRTBASE 等核心组件，确保 C++ 基础几何运算无缺失。
2. **DirectX 11 依赖**：
   - `d3dcompiler_47.dll`, `d3dx11_43.dll`, `dxgi.dll`。
   - 配置 Wine DLL 覆盖策略为原生优先 (`native,builtin`)。
3. **COM / OLE 基础设施**：
   - `ole32.dll`, `oleaut32.dll`, `msxml6.dll`, `riched20.dll`。

### 3.3 文件系统布局对齐
在容器的虚拟 C 盘路径下建立规范的目录结构：
- `bottle/drive_c/Program Files/SOLIDWORKS Corp/SOLIDWORKS`
- `bottle/drive_c/ProgramData/SOLIDWORKS`
- `bottle/drive_c/SOLIDWORKS Data`
- `bottle/drive_c/SolidWorks_Flexnet_Server`
采用软链接或拷贝方式映射已有抽取文件，避免重复占用存储空间同时保持读写隔离。

### 3.4 注册表恢复与 COM 注册
1. **注册表格式适配与导入**：
   - `SWHKLM.reg` 与 `SWHKCU.reg` 转换为标准 UTF-8/UTF-16 兼容格式。
   - 使用 Wine 的 `regedit` 工具按顺序将注册表项导入到容器的 `system.reg` 和 `user.reg` 中。
   - 验证关键注册表键：
     - `HKLM\SOFTWARE\SolidWorks`
     - `HKCU\Software\SolidWorks`
     - `HKLM\SOFTWARE\FLEXlm License Manager`
2. **核心 COM 组件注册**：
   - 对 SolidWorks 目录下的关键 ActiveX/COM DLL 调用 `regsvr32` 完成组件注册（如 `sldotu.dll`, `swsecwrap.dll` 等），确保主界面框架与插件系统初始化正常。

### 3.5 许可授权（FlexNet Licensing）对接
SolidWorks 启动时通过 FlexNet 握手 `25734` 端口：
- **方案 A（首选直连虚拟机）**：配置注册表将许可服务指向 Parallels 虚拟机的 Windows 宿主 IP（`25734@<VM_IP>`），绕过 Wine 下创建系统常驻服务的复杂性。
- **方案 B（本地守护进程）**：在 Wine 容器后台通过子进程直接拉起 `lmgrd.exe -c sw_d_SSQ.lic`，并在本地监听 `25734@127.0.0.1`。

### 3.6 启动脚本与调试跟踪
编写专用启动包装脚本 `run_sw.sh`：
- 配置环境变量：`WINEPREFIX`, `PATH`, `WINEDLLOVERRIDES`, `DXVK_HUD` 等。
- 分级日志输出：针对 `loaddll`, `seh`, `relay` 记录崩溃调用栈。
- 异常场景对策：针对视口黑屏、CEF 欢迎屏崩溃等典型故障，通过添加命令行参数（如 `/safe`、禁用主页 WebView）或覆盖 OpenGL/D3D 配置做针对性微调。

---

## 4. 验证与成功标准

1. **容器验证**：WINEPREFIX 顺利创建，基础 64 位 Windows 10 架构正常就绪。
2. **注册表与库验证**：SWHKLM / SWHKCU 注册表完整生效，无严重语法错误。
3. **进程拉起**：`SLDWORKS.exe` 能够被 Wine 正常调度，Rosetta 2 转译无指令集缺失。
4. **许可认证**：成功与 FlexNet 授权握手，无 "Cannot connect to license server" 弹窗阻断。
5. **界面与视口渲染**：主窗口出现，新建零件时视口有基本图形响应。
