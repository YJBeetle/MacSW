# SolidWorks 介质组件与语言定制提取部署实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 在 MacSW 部署向导中增加基于官方 ISO 介质的动态语言与组件定制选择面板，并使用原生多线程解包服务替代 32 位官方 Windows 向导，实现 1~2 分钟极速静默部署。

**架构：**
1. `MediaInspectorService` 解析介质内 `swwi/data/Setup.ini` 提取支持的语言（LCID），并扫描根目录与 `swwi/data` 识别可选组件与预估体积；
2. `WizardView` 在介质挂载后平滑展开毛玻璃风格的定制卡片（语言 Chips + 组件复选树 + 实时空间统计）；
3. `InstallExtractorService` 调度 `7z` 多线程解压目标组件的 CAB/MSI 至 WinePrefix，并自动写入语言注册表配置。

**技术栈：** Swift 5.9, SwiftUI, AppKit, 7-Zip (`p7zip`), Wine CLI, macOS Darwin.

---

## 文件结构计划

- **创建：** `macos/Bootstrap/Services/MediaInspectorService.swift`
  - 职责：解析 `Setup.ini` 的 `[Languages]` 节区，检测光盘功能组件文件夹与 CAB，构建 `InstallationConfig` 数据模型。
- **创建：** `macos/Bootstrap/Services/InstallExtractorService.swift`
  - 职责：调度 `7z` 执行组件与语言的多线程静默解包，实时报告进度，注入语言注册表项。
- **修改：** `macos/Bootstrap/AppState.swift`
  - 职责：持有 `installationConfig` 状态，暴露介质扫描与自定义解包接口。
- **修改：** `macos/Bootstrap/Views/WizardView.swift`
  - 职责：在步骤 1 挂载后展开定制卡片，步骤 3 接入 `InstallExtractorService`。
- **修改：** `macos/Bootstrap/build_bootstrap.sh`
  - 职责：将新增的 Swift 源码纳入 `swiftc` 编译文件列表。
- **测试：** `macos/Bootstrap/Tests/test_media_inspector.swift`
  - 职责：单元测试验证 `MediaInspectorService` 对真实光盘介质的语言与组件解析准确性。

---

### 任务 1：介质元数据扫描引擎与数据模型 (`MediaInspectorService.swift`)

**文件：**
- 创建：`macos/Bootstrap/Services/MediaInspectorService.swift`
- 修改：`macos/Bootstrap/build_bootstrap.sh:12-23`
- 测试：`macos/Bootstrap/Tests/test_media_inspector.swift`

- [ ] **步骤 1：编写失败的单元测试**

创建 `macos/Bootstrap/Tests/test_media_inspector.swift`，测试解析 `/Volumes/Solidworks1` 的语言与组件：

```swift
import Foundation

// 引入被测逻辑或编译时包含
let mediaPath = "/Volumes/Solidworks1"
guard FileManager.default.fileExists(atPath: mediaPath) else {
    print("[SKIP] /Volumes/Solidworks1 未挂载，跳过挂载点测试")
    exit(0)
}

let profile = MediaInspectorService.shared.inspect(mediaPath: mediaPath)
assert(!profile.languages.isEmpty, "必须能够解析出语言列表")
assert(profile.languages.contains(where: { $0.lcid == "0x0804" }), "必须包含简体中文 0x0804")
assert(profile.languages.contains(where: { $0.lcid == "0x0409" }), "必须包含英语 0x0409")
assert(profile.components.contains(where: { $0.id == "swwi" }), "必须包含核心主程序组件")
assert(profile.components.contains(where: { $0.id == "Toolbox" }), "必须包含 Toolbox 组件")
print("[PASS] MediaInspectorService 单元测试通过！")
```

- [ ] **步骤 2：运行测试验证失败**

运行：`swift macos/Bootstrap/Tests/test_media_inspector.swift`
预期：FAIL，报错 "cannot find 'MediaInspectorService' in scope"

- [ ] **步骤 3：实现 `MediaInspectorService.swift` 与数据模型**

创建 `macos/Bootstrap/Services/MediaInspectorService.swift`：

```swift
import Foundation

public struct LanguageOption: Identifiable, Hashable {
    public let id: String
    public let lcid: String
    public let name: String
    public var isSelected: Bool
    
    public init(id: String, lcid: String, name: String, isSelected: Bool) {
        self.id = id
        self.lcid = lcid
        self.name = name
        self.isSelected = isSelected
    }
}

public enum ComponentCategory: String, CaseIterable {
    case core = "核心设计"
    case simulation = "仿真分析"
    case manufacturing = "制造加工"
    case utilities = "扩展组件"
}

public struct ComponentOption: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let category: ComponentCategory
    public let description: String
    public let approximateBytes: Int64
    public let isRequired: Bool
    public var isSelected: Bool
    public let folderName: String
    
    public init(id: String, name: String, category: ComponentCategory, description: String, approximateBytes: Int64, isRequired: Bool, isSelected: Bool, folderName: String) {
        self.id = id
        self.name = name
        self.category = category
        self.description = description
        self.approximateBytes = approximateBytes
        self.isRequired = isRequired
        self.isSelected = isSelected
        self.folderName = folderName
    }
}

public struct MediaProfile {
    public var languages: [LanguageOption]
    public var components: [ComponentOption]
    
    public var totalEstimatedBytes: Int64 {
        components.filter { $0.isSelected }.reduce(0) { $0 + $1.approximateBytes }
    }
}

public class MediaInspectorService {
    public static let shared = MediaInspectorService()
    
    private let lcidNameMap: [String: String] = [
        "0x0804": "简体中文",
        "0x0404": "繁体中文",
        "0x0409": "English",
        "0x0411": "日本語",
        "0x0407": "Deutsch",
        "0x040c": "Français",
        "0x0410": "Italiano",
        "0x0412": "한국어",
        "0x0419": "Русский",
        "0x0416": "Português",
        "0x040a": "Español",
        "0x0415": "Polski",
        "0x0405": "Čeština",
        "0x041f": "Türkçe"
    ]
    
    public func inspect(mediaPath: String) -> MediaProfile {
        let langs = parseLanguages(mediaPath: mediaPath)
        let comps = scanComponents(mediaPath: mediaPath)
        return MediaProfile(languages: langs, components: comps)
    }
    
    private func parseLanguages(mediaPath: String) -> [LanguageOption] {
        var options: [LanguageOption] = []
        let iniPath = (mediaPath as NSString).appendingPathComponent("swwi/data/Setup.ini")
        
        if let data = try? Data(contentsOf: URL(fileURLWithPath: iniPath)) {
            let content = String(data: data, encoding: .utf16LittleEndian) ?? String(data: data, encoding: .utf8) ?? ""
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.lowercased().starts(with: "supported") && trimmed.contains("=") {
                    let parts = trimmed.split(separator: "=")
                    if parts.count >= 2 {
                        let lcids = parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        for lcid in lcids {
                            let name = lcidNameMap[lcid.lowercased()] ?? lcid
                            let isDefaultSelected = (lcid.lowercased() == "0x0804" || lcid.lowercased() == "0x0409")
                            options.append(LanguageOption(id: lcid, lcid: lcid, name: name, isSelected: isDefaultSelected))
                        }
                    }
                }
            }
        }
        
        if options.isEmpty {
            options = [
                LanguageOption(id: "0x0804", lcid: "0x0804", name: "简体中文", isSelected: true),
                LanguageOption(id: "0x0409", lcid: "0x0409", name: "English", isSelected: true)
            ]
        }
        return options
    }
    
    private func scanComponents(mediaPath: String) -> [ComponentOption] {
        let fm = FileManager.default
        var list: [ComponentOption] = []
        
        // 核心主程序 (必选)
        list.append(ComponentOption(
            id: "swwi",
            name: "SOLIDWORKS 核心主程序",
            category: .core,
            description: "零件建模、装配体、工程图设计环境",
            approximateBytes: 8_500_000_000,
            isRequired: true,
            isSelected: true,
            folderName: "swwi"
        ))
        
        let definitions: [(id: String, folder: String, name: String, cat: ComponentCategory, desc: String, size: Int64, defSelect: Bool)] = [
            ("Toolbox", "Toolbox", "Toolbox 标准件库", .core, "包含 GB/ISO 等常用螺栓、轴承、齿轮标准件库", 650_000_000, true),
            ("flow_sim", "Flow Simulation", "Flow Simulation 流体分析", .simulation, "内外部流体动力学与电子散热热仿真", 1_200_000_000, false),
            ("plastics", "plastics", "Plastics 注塑模流分析", .simulation, "零件注塑充填、保压与翘曲变形预测", 550_000_000, false),
            ("cam", "cam", "SOLIDWORKS CAM", .manufacturing, "2.5轴/3轴铣削与车削数控加工编程", 850_000_000, false),
            ("visualize", "visualize", "SOLIDWORKS Visualize", .utilities, "照片级写实渲染与动态产品动画输出", 1_600_000_000, false),
            ("eDrawings", "eDrawings", "eDrawings 图纸查看器", .utilities, "轻量化 2D/3D CAD 图纸查看与协同审阅", 220_000_000, false),
            ("swelectric", "swelectric", "Electrical 电气设计套件", .utilities, "原理图设计与 3D 智能布线嵌入集成", 900_000_000, false),
            ("SWPDMClient", "SWPDMClient", "PDM 客户端套件", .utilities, "企业级产品数据与工程版本协同管理", 350_000_000, false)
        ]
        
        for def in definitions {
            let path = (mediaPath as NSString).appendingPathComponent(def.folder)
            if fm.fileExists(atPath: path) {
                list.append(ComponentOption(
                    id: def.id,
                    name: def.name,
                    category: def.cat,
                    description: def.desc,
                    approximateBytes: def.size,
                    isRequired: false,
                    isSelected: def.defSelect,
                    folderName: def.folder
                ))
            }
        }
        
        return list
    }
}
```

修改 `macos/Bootstrap/build_bootstrap.sh`，在 `SWIFT_FILES` 中加入 `MediaInspectorService.swift`。

- [ ] **步骤 4：运行测试验证通过**

运行：`swift -I macos/Bootstrap macos/Bootstrap/Services/MediaInspectorService.swift macos/Bootstrap/Tests/test_media_inspector.swift`
预期：PASS，输出 "[PASS] MediaInspectorService 单元测试通过！"

- [ ] **步骤 5：Commit**

```bash
git add macos/Bootstrap/Services/MediaInspectorService.swift macos/Bootstrap/Tests/test_media_inspector.swift macos/Bootstrap/build_bootstrap.sh
git commit -m "feat(inspector): 引入 MediaInspectorService 支持介质语言与组件动态解析"
```

---

### 任务 2：高并发静默解包与注册表注入服务 (`InstallExtractorService.swift`)

**文件：**
- 创建：`macos/Bootstrap/Services/InstallExtractorService.swift`
- 修改：`macos/Bootstrap/build_bootstrap.sh`

- [ ] **步骤 1：编写解包服务核心逻辑**

创建 `macos/Bootstrap/Services/InstallExtractorService.swift`：
- 检测系统 `7z` 路径（优先 `/opt/homebrew/bin/7z`，其次 `/usr/local/bin/7z`）；
- 定位所选组件的 CAB 文件；
- 解包主程序 CAB（`swwi/data/*.cab`）到 `Program Files/SOLIDWORKS/`；
- 解包 Toolbox 数据到 `drive_c/SOLIDWORKS Data/`；
- 写入 Windows 注册表语言键值（`Current Language` = `Chinese Simplified`）；
- 提供 `progressHandler: (Double, String) -> Void` 驱动向导进度条。

- [ ] **步骤 2：测试解包与注册表注入**

编写针对 `InstallExtractorService` 的解包测试验证函数并在命令行执行，验证解包出 `SLDWORKS.exe` 与关联 DLL。

- [ ] **步骤 3：修改 `build_bootstrap.sh` 包含该服务**

将 `macos/Bootstrap/Services/InstallExtractorService.swift` 写入 `build_bootstrap.sh` 的 `SWIFT_FILES`。

- [ ] **步骤 4：Commit**

```bash
git add macos/Bootstrap/Services/InstallExtractorService.swift macos/Bootstrap/build_bootstrap.sh
git commit -m "feat(extractor): 实现原生多线程 CAB 解包与语言注册表注入服务"
```

---

### 任务 3：UI 定制展开面板与向导链路整合 (`WizardView.swift` & `AppState.swift`)

**文件：**
- 修改：`macos/Bootstrap/AppState.swift`
- 修改：`macos/Bootstrap/Views/WizardView.swift`

- [ ] **步骤 1：更新 `AppState.swift` 状态流**

在 `AppState.swift` 中添加：
```swift
@Published var mediaProfile: MediaProfile? = nil
func inspectSelectedMedia(path: String)
func performCustomInstallation(completion: @escaping (Bool) -> Void)
```

- [ ] **步骤 2：更新 `WizardView.swift` 界面交互**

- 在 ISO 路径卡片下方添加 DisclosureCard：
  - 语言 Chips 列表（带圆角边框胶囊式多选按钮）；
  - 组件树列表（显示分类 Badge、名称、功能简介与体积）；
  - 底部统计栏：显示预估占用空间。
- 在“运行 SolidWorks 安装向导”步骤 3 中：
  - 调用 `AppState.performCustomInstallation` 代替旧的 `WineService.launchInstaller`；
  - 绑定百分比进度条与实时解包文件名。

- [ ] **步骤 3：编译原生 App 验证**

运行：`./macos/Bootstrap/build_bootstrap.sh`
预期：原生 Mach-O 构建成功无报错。

- [ ] **步骤 4：Commit**

```bash
git add macos/Bootstrap/AppState.swift macos/Bootstrap/Views/WizardView.swift
git commit -m "feat(ui): 在向导中集成语言 Chips 与组件选择面板及解包链路"
```

---

### 任务 4：端到端部署验证与 App 打包发布

**文件：**
- 运行打包：`./scripts/make_app.sh`

- [ ] **步骤 1：执行全量打包**

运行：`./scripts/make_app.sh`
预期：自动检测 GPTK 运行时、内置修复版 mscoree 与 Mono 10.4.1，构建出完整的 `build/app/MacSW.app`。

- [ ] **步骤 2：运行 MacSW.app 验证**

拉起 `MacSW.app`，执行部署向导测试：
1. 选取挂载好的 ISO 介质；
2. 验证定制面板是否平滑展开并正确列出简体中文、English 及 Toolbox/Simulation 各组件；
3. 点击“开始部署”，验证步骤 3 是否高速静默解包（无 Windows 假死弹窗），并在 2 分钟内完成；
4. 验证核心文件 `bottle/drive_c/Program Files/SOLIDWORKS/SLDWORKS.exe` 存在。

- [ ] **步骤 3：最终 Commit 与推送**

```bash
git commit -am "chore(release): 完成组件定制部署向导与 GPTK 独立运行时完整集成"
```
