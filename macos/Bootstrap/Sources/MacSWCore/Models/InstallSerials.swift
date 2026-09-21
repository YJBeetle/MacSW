import Foundation

/// 官方 SOLIDWORKS MSI 接受的四个序列号公共属性；其余产品只能走注册表。
public enum InstallSerialField: String, CaseIterable, Identifiable, Sendable {
    case solidWorks
    case simulation
    case motion
    case mbd

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .solidWorks: return "SOLIDWORKS"
        case .simulation: return "Simulation"
        case .motion: return "Motion"
        case .mbd: return "MBD"
        }
    }

    public var msiProperty: String {
        switch self {
        case .solidWorks: return "SOLIDWORKSSERIALNUMBER"
        case .simulation: return "SIMULATIONSERIALNUMBER"
        case .motion: return "MOTIONSERIALNUMBER"
        case .mbd: return "MBDSERIALNUMBER"
        }
    }

    public var product: SolidWorksProduct {
        switch self {
        case .solidWorks: return .solidWorks
        case .simulation: return .cosmosWorks
        case .motion: return .cosmosMotion
        case .mbd: return .mbd
        }
    }

    public static func forProduct(_ product: SolidWorksProduct) -> InstallSerialField? {
        allCases.first { $0.product == product }
    }
}

public struct InstallSerials: Equatable, Sendable {
    public static let groupCount = 6
    public static let groupLength = 4
    public static var expectedLength: Int { Self.groupCount * Self.groupLength }

    public var values: [InstallSerialField: String]

    public init(values: [InstallSerialField: String] = [:]) {
        self.values = values
    }

    public subscript(field: InstallSerialField) -> String {
        get { values[field] ?? "" }
        set { values[field] = newValue }
    }

    public static func normalized(_ raw: String) -> String {
        raw.uppercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    public func normalized(_ field: InstallSerialField) -> String {
        Self.normalized(self[field])
    }

    public var isEmpty: Bool {
        InstallSerialField.allCases.allSatisfy { normalized($0).isEmpty }
    }

    public var isComplete: Bool {
        !normalized(.solidWorks).isEmpty
    }

    public var msiProperties: [String] {
        InstallSerialField.allCases.compactMap { field in
            let value = normalized(field)
            guard !value.isEmpty else { return nil }
            return "\(field.msiProperty)=\(value)"
        }.sorted()
    }

    /// 已填写但不符合六组四字符格式的字段。
    public func invalidFields() -> [InstallSerialField] {
        InstallSerialField.allCases.filter { field in
            let value = normalized(field)
            return !value.isEmpty && value.count != Self.expectedLength
        }
    }

    /// 只回填用户尚未填写的字段，不覆盖手工输入。
    /// 交互安装时用于预写注册表，让官方向导预填序列号。
    public var parsedForRegistry: ParsedSerialNumbers {
        ParsedSerialNumbers(values: Dictionary(uniqueKeysWithValues: InstallSerialField.allCases.compactMap { field in
            let value = self[field].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            return (field.product, value)
        }))
    }

    public func merging(_ discovered: InstallSerials) -> InstallSerials {
        var result = self
        for field in InstallSerialField.allCases where normalized(field).isEmpty {
            let value = discovered[field]
            guard !Self.normalized(value).isEmpty else { continue }
            result[field] = value
        }
        return result
    }
}

public enum InstallSerialsError: LocalizedError {
    case malformedFields([InstallSerialField])

    public var errorDescription: String? {
        switch self {
        case .malformedFields(let fields):
            let names = fields.map(\.title).joined(separator: "、")
            return "\(names) 序列号不符合六组四字符格式。"
        }
    }
}
