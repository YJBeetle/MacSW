import Foundation

public enum InstallationStep: Int, CaseIterable, Identifiable, Sendable {
    case media = 1
    case environment
    case vcRuntime
    case loginManager
    case installer
    case language
    case wpfThemes
    case licensing
    case validation

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .media: return "校验官方安装介质"
        case .environment: return "准备 Wine 运行环境与托管 COM"
        case .vcRuntime: return "安装微软 VC++ 运行库"
        case .loginManager: return "安装 SOLIDWORKS Login Manager"
        case .installer: return "静默部署 SOLIDWORKS 主体"
        case .language: return "安装官方语言资源"
        case .wpfThemes: return "补齐微软官方 WPF 主题库"
        case .licensing: return "部署许可服务器" 
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
