import Foundation

/// 随当前 App 生成的本机接入说明；只拼接路径和文字，不查询或启动任何进程。
public struct AIConnectionInfo: Sendable {
    public static let defaultEndpoint = "127.0.0.1:18495"

    public let app: URL
    public let cli: URL
    public let skillDirectory: URL
    public let skillEntry: URL
    public let usageGuide: URL
    public let pathHelper: URL
    public let paths: AppPaths
    public let endpoint: String

    public init(bundleURL: URL, paths: AppPaths, environment: [String: String] = [:]) {
        app = bundleURL.standardizedFileURL
        cli = app.appendingPathComponent("Contents/MacOS/sw-cli")
        let resources = app.appendingPathComponent("Contents/Resources/SWCLI", isDirectory: true)
        skillDirectory = resources.appendingPathComponent(
            "runtime/PythonNative/lib/python3.11/site-packages/swcli/skills/swcli",
            isDirectory: true
        )
        skillEntry = skillDirectory.appendingPathComponent("SKILL.md")
        usageGuide = skillDirectory.appendingPathComponent("references/usage.md")
        pathHelper = resources.appendingPathComponent("bin/swcli-path")
        self.paths = paths
        let configuredEndpoint = environment["SWCLI_ENDPOINT"] ?? ""
        endpoint = configuredEndpoint.isEmpty ? Self.defaultEndpoint : configuredEndpoint
    }

    public var discoveryCommands: [String] {
        let command = [
            "env",
            "MACSW_WINEPREFIX=\(Self.shellQuote(paths.bottle.path))",
            "SWCLI_ENDPOINT=\(Self.shellQuote(endpoint))",
            Self.shellQuote(cli.path)
        ].joined(separator: " ")
        return ["version --json", "daemon status --json", "capabilities --json"].map {
            "\(command) \($0)"
        }
    }

    public var text: String {
        """
        请通过本机 MacSW 内置的 SWCLI 操作 SOLIDWORKS。
        以下是接入路径与配置，不代表 daemon 或 SOLIDWORKS 已启动；复制时未执行任何检查命令。

        MacSW App：\(app.path)
        SWCLI：\(cli.path)
        完整 skill 文件夹：\(skillDirectory.path)
        Skill 入口：\(skillEntry.path)
        使用指南：\(usageGuide.path)
        MacSW 容器：\(paths.bottle.path)
        容器 C: 的本机目录：\(paths.bottle.appendingPathComponent("drive_c").path)
        本机路径转换工具：\(pathHelper.path)
        日志目录：\(paths.logs.path)
        Daemon 端点配置：\(endpoint)（未探测运行状态）

        请先完整阅读上述 SKILL.md 和使用指南。需要安装 skill 时，按你所在 agent 的机制和用户授权安装整个 skill 文件夹，保留 references；不要修改 App 内的资源。

        在终端依次执行以下检查命令；命令中的容器和端点配置应沿用到后续操作：
        \(discoveryCommands.joined(separator: "\n"))

        实际能力以当前 daemon 的 capabilities 为准，不要根据新版网上文档猜测命令。
        文档和建模命令不会隐式启动 daemon。未运行时先说明情况，按用户授权启动；共享现有 SOLIDWORKS 实例必须明确使用 --attach-existing，不要强制结束用户的实例。
        使用类型化 SWCLI 命令并验证原生几何、尺寸及保存结果，不以截图或命令退出成功代替验证。操作失败可能留下部分修改，不要盲目重试。
        文件路径按当前容器的实际映射转换，不假定存在 Z:；保存、覆盖或关闭已有文档须遵守用户任务的授权范围。
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
