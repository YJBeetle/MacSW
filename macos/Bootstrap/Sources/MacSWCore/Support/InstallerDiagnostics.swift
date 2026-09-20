import Foundation

/// 安装器退出码不足以证明安装成功，这里提供可判定的日志摘要与 COM 注册校验。
public enum InstallerDiagnostics {
    public static let loginManagerCLSID = "{69EF7FA2-6705-47CF-AA78-2E4264D24EB3}"

    /// 托管 COM 必须同时具备 mscoree 宿主、托管类和程序集 CodeBase。
    public static let loginManagerRequirements = [
        "mscoree.dll",
        "sldLoginManager.LoginManager",
        "sldLoginManager.dll"
    ]

    public static let solidWorksRequirements = [
        "LocalServer32",
        "SLDWORKS.exe",
        "VersionIndependentProgID",
        "SldWorks.Application",
        "TypeLib"
    ]

    private static let secretMarkers = ["SERIALNUMBER", "SERVERLIST"]
    private static let summaryLimit = 40

    public static func msiErrorSummary(_ log: String) -> [String] {
        let expression = try? NSRegularExpression(
            pattern: #"SW MESSAGE\|ERROR\||Return value 3|Error [0-9]{4}|source file.{0,80}not found|cannot find|unable to"#,
            options: [.caseInsensitive]
        )
        guard let expression else { return [] }
        let matched = log.split(separator: "\n", omittingEmptySubsequences: true).compactMap { rawLine -> String? in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            let uppercased = line.uppercased()
            guard !secretMarkers.contains(where: { uppercased.contains($0) }) else { return nil }
            let range = NSRange(line.startIndex..., in: line)
            guard expression.firstMatch(in: line, options: [], range: range) != nil else { return nil }
            return line
        }
        return Array(matched.suffix(Self.summaryLimit))
    }

    public static func missingRequirements(output: String, required: [String]) -> [String] {
        let lowered = output.lowercased()
        return required.filter { !lowered.contains($0.lowercased()) }
    }

    public static func registeredCLSID(fromQuery output: String) -> String? {
        let expression = try? NSRegularExpression(
            pattern: #"REG_SZ\s+(\{[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\})"#
        )
        guard let expression,
              let match = expression.firstMatch(in: output, options: [], range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return String(output[range])
    }
}
