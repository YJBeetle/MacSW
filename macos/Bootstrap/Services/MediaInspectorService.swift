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
    
    public init(languages: [LanguageOption], components: [ComponentOption]) {
        self.languages = languages
        self.components = components
    }
    
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
    
    public init() {}
    
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
