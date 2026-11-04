import Foundation

/// 随当前 App 生成的本机接入说明；只拼接路径和文字，不查询或启动任何进程。
public struct AIConnectionInfo: Sendable {
    public static let defaultEndpoint = "127.0.0.1:18495"

    public let app: URL
    public let cli: URL
    public let skillDirectory: URL
    public let skillEntry: URL
    public let usageGuide: URL
    public let apiGuide: URL
    public let pathHelper: URL
    public let paths: AppPaths
    public let endpoint: String

    public init(bundleURL: URL, paths: AppPaths, environment: [String: String] = [:]) {
        app = bundleURL.standardizedFileURL
        cli = app.appendingPathComponent("Contents/MacOS/sw-cli")
        let resources = app.appendingPathComponent("Contents/Resources/SWCLI", isDirectory: true)
        skillDirectory = resources.appendingPathComponent("skills/macsw", isDirectory: true)
        skillEntry = skillDirectory.appendingPathComponent("SKILL.md")
        usageGuide = skillDirectory.appendingPathComponent("references/usage.md")
        apiGuide = skillDirectory.appendingPathComponent("references/solidworks-api.md")
        pathHelper = resources.appendingPathComponent("bin/swcli-path")
        self.paths = paths
        let configuredEndpoint = environment["SWCLI_ENDPOINT"] ?? ""
        endpoint = configuredEndpoint.isEmpty ? Self.defaultEndpoint : configuredEndpoint
    }

    public var text: String {
        let command = [
            "env",
            "MACSW_WINEPREFIX=\(Self.shellQuote(paths.bottle.path))",
            "SWCLI_ENDPOINT=\(Self.shellQuote(endpoint))",
            Self.shellQuote(cli.path)
        ].joined(separator: " ")
        return """
        请将 MacSW skill 安装到当前 agent 的用户级技能目录，供以后新对话自动发现。
        来源：\(skillDirectory.path)
        请先阅读 SKILL.md，并复制整个 macsw 文件夹（含 references）。如已有同源技能，请更新它。
        在已安装技能中创建 references/local-connection.md，记录以下命令前缀。每次在其后加所需的 SWCLI 子命令。
        \(command)

        请确认技能已安装并告知位置。以后处理 SOLIDWORKS、SLDPRT、SLDASM、SLDDRW 或 CAD STEP/STP 文件时使用它。
        这次只安装技能，无需启动 daemon、启动 SOLIDWORKS 或操作文档。
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
