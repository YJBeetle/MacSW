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

    /// MSI 只认 ASCII 大写字母与数字。`CharacterSet.alphanumerics` 是 Unicode 范围的，
    /// 全角 `１`、西里尔 `Ｖ` 都会被留下并凑够 24 位，`String.count` 数的是字形簇也挡不住，
    /// 所以先按标量滤到 ASCII 再大写：这样"长度"才等于真正会传给 msiexec 的字符数。
    private static let allowedScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    public static func normalized(_ raw: String) -> String {
        let kept = raw.unicodeScalars.filter { allowedScalars.contains($0) }
        return String(String.UnicodeScalarView(kept)).uppercased()
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

    /// 填过内容、规范化之后却不是六组四字符的字段。判定看原始输入而不是规范化结果：
    /// 一整串全角数字规范化后会变成空，只查长度就会漏成"没填"，用户看到的是莫名其妙的提示。
    public func invalidFields() -> [InstallSerialField] {
        InstallSerialField.allCases.filter { field in
            let typed = self[field].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typed.isEmpty else { return false }
            return normalized(field).count != Self.expectedLength
        }
    }

    /// 只回填用户尚未填写的字段，不覆盖手工输入（哪怕是还没改对的输入）。
    public func merging(_ discovered: InstallSerials) -> InstallSerials {
        var result = self
        for field in InstallSerialField.allCases
        where self[field].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
