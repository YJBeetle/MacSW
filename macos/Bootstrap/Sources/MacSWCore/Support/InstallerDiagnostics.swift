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

    /// 安装失败的完整说明：日志里才有真正的 MSI 返回码，摘要另存一份便于回看。
    /// 调用方给的是 `/l*v` 日志路径，几十 MB 的读取与正则请放到非主线程上跑。
    public static func failureDetail(log: URL) -> String {
        guard let data = try? Data(contentsOf: log), let text = PlainTextDecoder.decode(data) else {
            return "请查看 \(log.path)。"
        }
        let code = msiReturnCode(text).map { "MSI 返回 \($0)。" } ?? ""
        let summary = msiErrorSummary(text)
        guard !summary.isEmpty else { return code + "请查看 \(log.path)。" }
        let errors = log.deletingLastPathComponent().appendingPathComponent("install_msi_errors.log")
        try? summary.joined(separator: "\n").data(using: .utf8)?.write(to: errors)
        return code + "关键错误：\n\(summary.suffix(6).joined(separator: "\n"))\n完整摘要见 \(errors.path)。"
    }

    /// 真正的 MSI 返回码只写在 `/l*v` 日志里：Unix 进程状态只保留低 8 位，
    /// 1603 到调用方手上就成了 67，光看数字没法判断。取最后一条 MainEngineThread 的返回值。
    public static func msiReturnCode(_ log: String) -> Int32? {
        guard let expression = try? NSRegularExpression(
            pattern: #"MainEngineThread\s+(?:is\s+)?returning\s+(\d{1,5})"#,
            options: [.caseInsensitive]
        ) else { return nil }
        var found: Int32?
        for line in log.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let match = expression.firstMatch(
                in: text,
                options: [],
                range: NSRange(text.startIndex..., in: text)
            ), match.numberOfRanges == 2, let digits = Range(match.range(at: 1), in: text),
            let code = Int32(text[digits]) else { continue }
            found = code
        }
        return found
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
