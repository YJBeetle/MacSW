import Foundation

public struct LicenseServerEndpoint: Hashable, Sendable {
    public let port: UInt16
    public let host: String

    public init(port: UInt16, host: String) {
        self.port = port
        self.host = host
    }

    public var canonical: String { "\(port)@\(host)" }

    public var isLoopback: Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1"
    }

    public static func == (lhs: LicenseServerEndpoint, rhs: LicenseServerEndpoint) -> Bool {
        lhs.port == rhs.port && lhs.host.caseInsensitiveCompare(rhs.host) == .orderedSame
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(port)
        hasher.combine(host.lowercased())
    }
}

public struct LicenseServerList: Equatable, Sendable {
    public private(set) var endpoints: [LicenseServerEndpoint]

    public init(endpoints: [LicenseServerEndpoint]) {
        var seen = Set<LicenseServerEndpoint>()
        self.endpoints = endpoints.filter { seen.insert($0).inserted }
    }

    public var canonical: String {
        endpoints.map(\.canonical).joined(separator: ";")
    }
}

public enum LicenseServerAddressError: LocalizedError, Equatable {
    case empty
    case invalidEntry(String)
    case invalidPort(String)
    case ambiguousIPv6(String)

    public var errorDescription: String? {
        switch self {
        case .empty: return "请输入至少一个许可服务器地址。"
        case .invalidEntry(let value): return "无法识别服务器地址：\(value)"
        case .invalidPort(let value): return "服务器端口无效：\(value)"
        case .ambiguousIPv6(let value): return "IPv6 冒号格式必须写成 [IPv6]:port：\(value)"
        }
    }
}
