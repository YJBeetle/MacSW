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
        端点可连接不代表 SOLIDWORKS 可操作：只有 host_connected=true、worker_alive=true、recovery_required=false 且 host 非空，才可继续文档或建模操作。检查输出只需摘要状态、错误和操作清单，不要把完整 schema 全部贴进对话。
        文档和建模命令不会隐式启动 daemon。未运行或 host 断连时先说明情况，优先请用户在 MacSW 菜单点击“启动 SWCLI daemon”（断连时为“恢复 SWCLI daemon”），等待“SWCLI 可用”后重新执行上述检查。已有 SOLIDWORKS 时菜单共享接入，没有时不可见启动；菜单状态不替代检查命令。
        如需由 agent 启动或恢复，必须按用户明确授权执行生命周期命令；复制这段接入信息本身不是启动、重启、停止或安装 skill 的授权。已有实例必须明确使用 --attach-existing，不要强制结束用户的实例；新建 host 默认不可见，只有用户明确要求可见时才使用 --visible。host 断连而 daemon 仍可连接时，普通 daemon start 可能只返回已有服务，恢复需明确使用 daemon restart。
        若权限层拦截生命周期命令，说明命令尚未执行，停止重试；请用户通过 MacSW 菜单操作，或按该 agent 的审批机制提供明确确认，不要改用其他命令绕过审批。
        使用类型化 SWCLI 命令并验证原生几何、尺寸及保存结果，不以截图或命令退出成功代替验证。操作失败可能留下部分修改，不要盲目重试。
        文件路径按当前容器的实际映射转换，不假定存在 Z:；保存、覆盖或关闭已有文档须遵守用户任务的授权范围。
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
