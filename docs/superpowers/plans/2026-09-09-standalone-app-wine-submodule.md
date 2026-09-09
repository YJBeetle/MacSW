# 独立 macOS 应用程序 (MacSW) 与 Wine Submodule 补丁构建系统实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development 或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 构建一个完全脱离 CrossOver、无版权隐患、使用 Git Submodule 管理 Wine-crossover 源码并通过 Patches 补丁注入定制逻辑（Win7 Aero 标题栏按钮、Metal 避让）的独立 macOS 应用程序及 GitHub Actions CI 自动流水线。

**架构：** 采用开源上游 `Gcenx/winecx` 作为 Git Submodule，所有深度定制均以 Git Patch 文件维护；编写跨本地与 GitHub Actions 的一键编译打包脚本；配套开发轻量原生 macOS SwiftUI Bootstrap 向导应用，让用户自主指定 ISO 与许可服务，彻底消除法律合规风险。

**技术栈：** Git Submodules, C (Wine Win32u/Winemac.drv patches), Shell Scripting, GitHub Actions CI (macOS-14 ARM64), Swift 5.9+ / SwiftUI.

---

### 任务 1：配置 Git Submodule 与 Patches 补丁基础架构

**文件：**
- 创建：`.gitmodules`
- 创建：`scripts/init_submodules.sh`
- 创建目录：`patches/wine-crossover/`

- [ ] **步骤 1：创建 `.gitmodules` 配置文件**
- [ ] **步骤 2：编写高效浅克隆与检出脚本 `scripts/init_submodules.sh`**
- [ ] **步骤 3：运行初始化脚本测试 submodule 注册状态**
- [ ] **步骤 4：Commit**

---

### 任务 2：提取 Windows 7 Aero 标题栏原生绘制补丁

**文件：**
- 创建：`patches/wine-crossover/0001-defwnd-aero-caption-buttons.patch`
- 创建：`scripts/test_apply_patches.sh`

- [ ] **步骤 1：基于前期测绘完成的 Aero 像素生成逻辑，编写适用于 Wine `win32u/defwnd.c` 的源码补丁**
- [ ] **步骤 2：编写补丁验证脚本 `scripts/test_apply_patches.sh`**
- [ ] **步骤 3：验证补丁语法与上下文完整性**
- [ ] **步骤 4：Commit**

---

### 任务 3：编写本地与 CI 通用的 Wine 编译与打包脚本

**文件：**
- 创建：`scripts/build_wine.sh`

- [ ] **步骤 1：编写脚本参数解析、依赖探测（bison, flex, mingw, llvm）**
- [ ] **步骤 2：编写自动 apply 补丁、配置 configure 标志与多核编译逻辑**
- [ ] **步骤 3：编写产物提取与 tar.gz 打包逻辑**
- [ ] **步骤 4：测试运行脚本的 dry-run 与依赖检测**
- [ ] **步骤 5：Commit**

---

### 任务 4：编写 GitHub Actions 自动编译工作流

**文件：**
- 创建：`.github/workflows/build-wine.yml`

- [ ] **步骤 1：编写基于 `macos-14` (Apple Silicon M1) 的 GitHub Actions 工作流**
- [ ] **步骤 2：配置 Homebrew 构建依赖与 ccache 缓存加速**
- [ ] **步骤 3：配置自动化打 Tag 发布 Release 资产逻辑**
- [ ] **步骤 4：Commit 并推送到 GitHub 测试 CI 触发**

---

### 任务 5：编写 macOS 原生 Bootstrap 引导向导（SwiftUI）

**文件：**
- 创建：`macos/Bootstrap/MacSWApp.swift`
- 创建：`macos/Bootstrap/Views/WelcomeView.swift`
- 创建：`macos/Bootstrap/Views/IsoSelectorView.swift`
- 创建：`macos/Bootstrap/Views/LicenseConfigView.swift`
- 创建：`macos/Bootstrap/Services/WineRunner.swift`
- 创建：`macos/Bootstrap/Services/IsoExtractor.swift`

- [ ] **步骤 1：创建 SwiftUI 项目骨架与状态管理模型**
- [ ] **步骤 2：实现 ISO 介质选择、挂载与文件检测逻辑**
- [ ] **步骤 3：实现 FlexNet 许可服务外部路径关联逻辑**
- [ ] **步骤 4：实现 Wine 容器初始化与日常运行双模切换逻辑**
- [ ] **步骤 5：本地编译测试 Bootstrap 向导应用**
- [ ] **步骤 6：Commit**

---

### 任务 6：打包组装独立 SolidWorks.app

**文件：**
- 创建：`scripts/make_app.sh`
- 创建：`resources/Info.plist`

- [ ] **步骤 1：编写 App Bundle 目录结构生成逻辑**
- [ ] **步骤 2：集成 Wine Runtime、预置配置模板与 Bootstrap 可执行文件**
- [ ] **步骤 3：测试生成的 `SolidWorks.app` 结构合规性**
- [ ] **步骤 4：Commit**
