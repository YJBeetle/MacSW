import CryptoKit
import Foundation
import MacSWCore

/// CI-only host preparation, deliberately separate from the official installer
/// and its base-cache identity. Never packaged in the public App or base bottle.
@main
struct MacSWCIRuntime {
    static func main() async {
        do {
            try await run()
        } catch {
            // Only guards, Core monitor errors and public Wine/VC file paths can
            // reach this entrypoint; preserve the diagnostic reason, never data.
            FileHandle.standardError.write(Data("CI host preparation/inspection failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard env["GITHUB_ACTIONS"] == "true", let temporary = env["RUNNER_TEMP"],
              arguments.count == 2, ["prepare", "inspect"].contains(arguments[0]),
              ["visible", "hidden"].contains(arguments[1]) else { throw failure() }
        let root = URL(fileURLWithPath: temporary).resolvingSymlinksInPath()
            .appendingPathComponent("MacSW-runtime")
        guard Bundle.main.bundleURL.resolvingSymlinksInPath().path == root.appendingPathComponent("MacSW.app").path else {
            throw failure()
        }
        let paths = AppPaths(appSupportDirectory: root.appendingPathComponent("app-support"))
        guard paths.bottleExists, paths.solidWorksInstalled,
              paths.solidWorksExecutable.resolvingSymlinksInPath().path.hasPrefix(paths.bottle.path + "/") else {
            throw failure()
        }
        let monitor = SolidWorksResourceMonitorService()
        if arguments[0] == "prepare", monitor.state(paths: paths) == .enabled {
            // Same reversible operation as MacSW Settings and DockerSW's host
            // profile; no modification of the SOLIDWORKS CAD executable.
            try monitor.setDisabled(true, paths: paths)
        }
        let monitorState = monitor.state(paths: paths)
        guard monitorState != .enabled else { throw failure() }
        var monoWindowsPath = ""
        if arguments[0] == "prepare" {
            let wine = WineService.shared
            let mono = wine.runtimeURL.appendingPathComponent("share/wine/mono/wine-mono-\(BuildInfo.monoVersion)")
            // The cache deliberately removes runner-root drives. Rebind this
            // public runtime to an actual mapping (the adapter supplies M:),
            // rather than inheriting an installer-time Z: registry value.
            monoWindowsPath = try await wine.windowsPath(for: mono, prefix: paths.bottle)
            let process = wine.makeProcess(arguments: [
                "reg", "add", #"HKCU\Software\Wine\Mono"#, "/v", "RuntimePath", "/t", "REG_SZ",
                "/d", monoWindowsPath, "/f"
            ], prefix: paths.bottle)
            let (status, _) = try await wine.captureCancellable(process)
            guard status == 0 else { throw failure() }
        }
        var modules: [[String: Any]] = []
        for name in WineService.vcLibraries {
            let file = paths.bottle.appendingPathComponent("drive_c/windows/system32/\(name).dll")
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            let builtin = data.prefix(4096).range(of: Data("Wine builtin DLL".utf8)) != nil
            let fake = data.prefix(4096).range(of: Data("Wine placeholder DLL".utf8)) != nil
            modules.append(["name": name, "bytes": data.count, "wine_builtin": builtin,
                            "wine_placeholder": fake,
                            "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()])
        }
        let record: [String: Any] = [
            "completed": true, "phase": arguments[0],
            "resource_monitor": monitorState == .disabled ? "disabled" : "not-installed",
            "vc_modules": modules, "mono_runtime_path": monoWindowsPath
        ]
        let evidence = root.appendingPathComponent("evidence")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: evidence.appendingPathComponent("\(arguments[1])-host-\(arguments[0]).json"), options: .atomic)
        print("CI isolated host \(arguments[0]) completed.")
    }

    static func failure() -> NSError {
        NSError(domain: "MacSW.CI.Runtime", code: 1)
    }
}
