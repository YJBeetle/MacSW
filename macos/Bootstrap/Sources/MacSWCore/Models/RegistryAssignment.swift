public struct RegistryAssignment: Equatable, Sendable {
    public enum ValueKind: Equatable, Sendable {
        case string
        case multiString
    }

    public let key: String
    public let name: String
    public let value: String
    public let valueKind: ValueKind

    public init(key: String, name: String, value: String) {
        self.key = key
        self.name = name
        self.value = value
        self.valueKind = .string
    }

    public init(key: String, name: String, multiStringValues: [String]) {
        self.key = key
        self.name = name
        self.value = multiStringValues.joined(separator: "\0")
        self.valueKind = .multiString
    }
}
