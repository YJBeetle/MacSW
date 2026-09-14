import Foundation

public enum InstallationStep: Int, CaseIterable, Identifiable, Sendable {
    case environment = 1
    case vcRuntime
    case loginManager
    case serialNumbers
    case installer
    case wpfThemes
    case validation

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .environment: return "准备运行环境与挂载介质"
        case .vcRuntime: return "安装微软 VC++ 运行库"
        case .loginManager: return "安装 SOLIDWORKS Login Manager"
        case .serialNumbers: return "预载安装序列号"
        case .installer: return "运行 SOLIDWORKS 官方安装器"
        case .wpfThemes: return "补齐微软官方 WPF 主题库"
        case .validation: return "检查部署结果"
        }
    }
}

public enum InstallationStepStatus: String, Sendable {
    case pending = "等待中"
    case running = "进行中"
    case completed = "已完成"
    case warning = "有警告"
    case failed = "失败"
    case skipped = "已跳过"
    case cancelled = "已取消"
}

public enum InstallationState: Equatable, Sendable {
    case idle
    case preparing
    case installing(InstallationStep)
    case cancelling
    case cancelled
    case failed(String)
    case completed

    public var isActive: Bool {
        switch self {
        case .preparing, .installing, .cancelling: return true
        default: return false
        }
    }
}

public enum SerialInputMode: String, CaseIterable, Identifiable, Sendable {
    case text = "文本输入"
    case file = "选择文件"
    public var id: String { rawValue }
}

public enum SerialInputFileKind: Hashable, Sendable {
    case text
    case registry
}

public struct SerialInputFile: Identifiable, Hashable, Sendable {
    public let url: URL
    public let kind: SerialInputFileKind
    public let depth: Int

    public init(url: URL, kind: SerialInputFileKind, depth: Int) {
        self.url = url
        self.kind = kind
        self.depth = depth
    }

    public var id: String { url.standardizedFileURL.path }
}
