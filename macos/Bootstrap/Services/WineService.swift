import Foundation
import AppKit

/// App-only runtime. Shared by setup, maintenance and every launch entry point.
final class WineService {
    static let shared = WineService()
    private let stateLock = NSLock()
    private var activePrefixes = Set<String>()
    func isRunning(prefix: String) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return activePrefixes.contains(prefix)
    }
    static let vcLibraries = ["concrt140", "msvcp140", "msvcp140_1", "msvcp140_2",
        "msvcp140_atomic_wait", "msvcp140_codecvt_ids", "vcruntime140", "vcruntime140_1", "vcomp140", "mfc140u"]
    var runtimeURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/wine") }
    func getWineBinary() -> String { runtimeURL.appendingPathComponent("bin/wineloader").path }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func environment(winePrefix: String, solidWorks: Bool = false) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["WINEDLLPATH", "CX_ROOT", "CX_BOTTLE", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH", "WINEDLLOVERRIDES", "MONO_ENV_OPTIONS"] {
            env.removeValue(forKey: key)
        }
        env["WINEPREFIX"] = winePrefix
        env["WINELOADER"] = getWineBinary()
        env["WINESERVER"] = runtimeURL.appendingPathComponent("bin/wineserver").path
        env["LANG"] = "zh_CN.UTF-8"
        env["LC_ALL"] = "zh_CN.UTF-8"
        env["WINEDEBUG"] = "-all"
        if solidWorks {
            env["WINEDLLOVERRIDES"] = (["atiadlxx=d"] + Self.vcLibraries.map { "\($0)=n,b" }).joined(separator: ";")
        }
        return env
    }

    func buildEnvironmentScript(winePrefix: String) -> String {
        let env = environment(winePrefix: winePrefix)
        return "unset WINEDLLPATH CX_ROOT CX_BOTTLE DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH WINEDLLOVERRIDES MONO_ENV_OPTIONS\n" +
            ["WINEPREFIX", "WINELOADER", "WINESERVER", "LANG", "LC_ALL", "WINEDEBUG"].map {
                "export \($0)=\(Self.quote(env[$0]!))"
            }.joined(separator: "\n")
    }

    func logDirectory(_ prefix: String) -> URL {
        URL(fileURLWithPath: prefix).deletingLastPathComponent().appendingPathComponent("logs")
    }

    func makeProcess(arguments: [String], prefix: String, solidWorks: Bool = false) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: getWineBinary())
        process.arguments = arguments
        process.environment = environment(winePrefix: prefix, solidWorks: solidWorks)
        return process
    }

    @discardableResult
    func run(_ process: Process, log: URL? = nil) throws -> Int32 {
        var handle: FileHandle?
        if let log = log {
            try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
            handle = try FileHandle(forWritingTo: log)
            try handle?.seekToEnd()
        }
        process.standardOutput = handle ?? FileHandle.nullDevice
        process.standardError = handle ?? FileHandle.nullDevice
        defer { try? handle?.close() }
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func killWineProcesses(winePrefix: String) {
        let process = makeProcess(arguments: ["-k"], prefix: winePrefix)
        process.executableURL = runtimeURL.appendingPathComponent("bin/wineserver")
        _ = try? run(process)
    }

    func launchInstaller(setupExe: String, winePrefix: String, completion: @escaping (Int32) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let logs = self.logDirectory(winePrefix)
            let args = setupExe.lowercased().hasSuffix(".msi")
                ? ["msiexec", "/i", setupExe, "DISABLEROLLBACK=1", "/l*v", logs.appendingPathComponent("install_msi.log").path]
                : [setupExe]
            let result = (try? self.run(self.makeProcess(arguments: args, prefix: winePrefix),
                                       log: logs.appendingPathComponent("installer-wine.log"))) ?? -1
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Retained until SW exits, so daemon lifetime follows the launched application.
    func launchSolidWorks(exePath: String, winePrefix: String, completion: @escaping (Bool, String) -> Void) {
        stateLock.lock()
        guard !activePrefixes.contains(winePrefix) else { stateLock.unlock(); return }
        activePrefixes.insert(winePrefix)
        stateLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            let daemon = self.makeProcess(arguments: [
                Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/sw_ui_daemon.exe").path, "--watch"
            ], prefix: winePrefix, solidWorks: true)
            defer {
                if daemon.isRunning { daemon.terminate() }
                self.stateLock.lock()
                self.activePrefixes.remove(winePrefix)
                self.stateLock.unlock()
            }
            do {
                let log = self.logDirectory(winePrefix).appendingPathComponent("sw_launch.log")
                for hive in ["HKCU", "HKLM"] {
                    _ = try self.run(self.makeProcess(arguments: ["reg", "add",
                        "\(hive)\\Software\\SolidWorks\\SOLIDWORKS 2025\\General",
                        "/v", "EnableSldLoginManager", "/t", "REG_DWORD", "/d", "0", "/f"],
                        prefix: winePrefix), log: log)
                }
                // No native mscoree/D3DMetal overrides: use the tested Wine 11 stack.
                let daemonLog = self.logDirectory(winePrefix).appendingPathComponent("ui-daemon.log")
                if !FileManager.default.fileExists(atPath: daemonLog.path) { FileManager.default.createFile(atPath: daemonLog.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: daemonLog)
                defer { try? handle.close() }
                try handle.seekToEnd()
                daemon.standardOutput = handle
                daemon.standardError = handle
                try daemon.run()
                let sw = self.makeProcess(arguments: [exePath], prefix: winePrefix, solidWorks: true)
                sw.currentDirectoryURL = URL(fileURLWithPath: exePath).deletingLastPathComponent()
                // run() is blocking only on the worker queue, never on the UI thread.
                let result = try self.run(sw, log: log)
                DispatchQueue.main.async { completion(result == 0, "SolidWorks 已退出（\(result)）。日志：\(log.path)") }
            } catch {
                DispatchQueue.main.async { completion(false, "启动失败：\(error.localizedDescription)") }
            }
        }
    }

    func runWineCommand(command: String, winePrefix: String, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = ["-c", "\(self.buildEnvironmentScript(winePrefix: winePrefix))\n\(Self.quote(self.getWineBinary())) \(command)"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                DispatchQueue.main.async { completion(task.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "") }
            } catch {
                DispatchQueue.main.async { completion(false, error.localizedDescription) }
            }
        }
    }
}
