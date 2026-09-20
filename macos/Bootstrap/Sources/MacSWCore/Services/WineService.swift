import AppKit
import Darwin
import Foundation

public final class WineService: @unchecked Sendable {
    public static let shared = WineService()
    private let stateLock = NSLock()
    private var activePrefixes = Set<String>()

    public static let vcLibraries = [
        "concrt140", "msvcp140", "msvcp140_1", "msvcp140_2", "msvcp140_atomic_wait",
        "msvcp140_codecvt_ids", "vcruntime140", "vcruntime140_1", "vcomp140", "mfc140u"
    ]
    /// 停止时必须覆盖整套进程，只杀主程序会留下文件服务与 UI 守护进程。
    public static let solidWorksProcessNames = ["SLDWORKS.exe", "sldworks_fs.exe", "sw_ui_daemon.exe"]
    public static let solidWorksCompatibilityArguments = [
        "reg", "add", "HKCU\\Software\\Microsoft\\Windows NT\\CurrentVersion\\AppCompatFlags\\Layers",
        "/v", "sldworks.exe", "/t", "REG_SZ", "/d", "WINE_NOCAPTURERESEND", "/f"
    ]

    public var runtimeURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/wine")
    }

    public var wineBinary: URL {
        runtimeURL.appendingPathComponent("bin/wineloader")
    }

    public var wineServerBinary: URL {
        runtimeURL.appendingPathComponent("bin/wineserver")
    }

    public func isRunning(prefix: URL) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activePrefixes.contains(prefix.path)
    }

    public func isSolidWorksProcessRunning(prefix: URL) async -> Bool {
        if isRunning(prefix: prefix) { return true }
        guard FileManager.default.fileExists(atPath: prefix.path),
              FileManager.default.isExecutableFile(atPath: wineBinary.path) else { return false }
        let process = makeProcess(arguments: [
            "tasklist", "/fi", "IMAGENAME eq SLDWORKS.exe", "/fo", "csv", "/nh"
        ], prefix: prefix)
        guard let (status, output) = try? await captureCancellable(process), status == 0 else { return false }
        return output.range(of: "SLDWORKS.exe", options: .caseInsensitive) != nil
    }

    public static func isSuccessfulPrerequisiteStatus(_ code: Int32) -> Bool {
        [Int32(0), 3010, 194, 1638, 102].contains(code)
    }

    public static func isSuccessfulInstallerStatus(_ code: Int32) -> Bool {
        [Int32(0), 3010, 194].contains(code)
    }

    public static func isCancelledInstallerStatus(_ code: Int32) -> Bool {
        // Windows ERROR_INSTALL_USEREXIT (1602) is truncated to 66 by a Unix process status.
        [Int32(1602), 66, 15].contains(code)
    }

    public static func isSuccessfulCleanupStop(killStatus: Int32, waitStatus: Int32) -> Bool {
        [Int32(0), 1].contains(killStatus) && waitStatus == 0
    }

    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public func environment(winePrefix: URL, solidWorks: Bool = false) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in [
            "WINEDLLPATH", "CX_ROOT", "CX_BOTTLE", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH",
            "WINEDLLOVERRIDES", "MONO_ENV_OPTIONS"
        ] {
            environment.removeValue(forKey: key)
        }
        environment["WINEPREFIX"] = winePrefix.path
        environment["WINELOADER"] = wineBinary.path
        environment["WINESERVER"] = wineServerBinary.path
        environment["LANG"] = "zh_CN.UTF-8"
        environment["LC_ALL"] = "zh_CN.UTF-8"
        environment["WINEDEBUG"] = "-all"
        environment["WINE_MONO_AOT"] = solidWorks ? "none" : "interp"
        if solidWorks {
            environment["WINEDLLOVERRIDES"] = (["atiadlxx=d"] + Self.vcLibraries.map { "\($0)=n,b" })
                .joined(separator: ";")
        }
        return environment
    }

    public func buildEnvironmentScript(winePrefix: URL) -> String {
        let values = environment(winePrefix: winePrefix)
        return "unset WINEDLLPATH CX_ROOT CX_BOTTLE DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH WINEDLLOVERRIDES MONO_ENV_OPTIONS\n" +
            ["WINEPREFIX", "WINELOADER", "WINESERVER", "LANG", "LC_ALL", "WINEDEBUG", "WINE_MONO_AOT"]
                .map { "export \($0)=\(Self.quote(values[$0]!))" }
                .joined(separator: "\n")
    }

    public func logDirectory(_ prefix: String) -> URL {
        URL(fileURLWithPath: prefix).deletingLastPathComponent().appendingPathComponent("logs")
    }

    public func makeProcess(arguments: [String], prefix: String, solidWorks: Bool = false) -> Process {
        makeProcess(arguments: arguments, prefix: URL(fileURLWithPath: prefix), solidWorks: solidWorks)
    }

    public func makeProcess(arguments: [String], prefix: URL, solidWorks: Bool = false) -> Process {
        let process = Process()
        process.executableURL = wineBinary
        process.arguments = arguments
        process.environment = environment(winePrefix: prefix, solidWorks: solidWorks)
        return process
    }

    @discardableResult
    public func run(_ process: Process, log: URL? = nil) throws -> Int32 {
        let handle = try logHandle(for: log)
        process.standardOutput = handle ?? FileHandle.nullDevice
        process.standardError = handle ?? FileHandle.nullDevice
        defer { try? handle?.close() }
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    public func runCancellable(_ process: Process, log: URL? = nil) async throws -> Int32 {
        try Task.checkCancellation()
        let handle = try logHandle(for: log)
        process.standardOutput = handle ?? FileHandle.nullDevice
        process.standardError = handle ?? FileHandle.nullDevice
        defer { try? handle?.close() }

        let status = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                    if Task.isCancelled, process.isRunning { process.terminate() }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        }, onCancel: {
            self.terminateProcess(process)
        })
        try Task.checkCancellation()
        return status
    }

    public func captureCancellable(_ process: Process) async throws -> (Int32, String) {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let readTask = Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }
        let status = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
                do {
                    try process.run()
                    if Task.isCancelled, process.isRunning { process.terminate() }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        }, onCancel: {
            self.terminateProcess(process)
        })
        let data = await readTask.value
        try Task.checkCancellation()
        // Wine 工具在中文 locale 下会输出遗留代码页字节（如 reg 的本地化“默认”），
        // 严格解码会整体失败并丢掉 ASCII 内容，这里按有损 UTF-8 解码。
        return (status, String(decoding: data, as: UTF8.self))
    }

    public func stopWineServerForCleanup(prefix: URL) async throws -> Bool {
        let log = logDirectory(prefix.path).appendingPathComponent("clean-install-wineserver.log")
        let kill = makeProcess(arguments: ["-k"], prefix: prefix)
        kill.executableURL = wineServerBinary
        let killStatus = try await runCancellable(kill, log: log)
        let wait = makeProcess(arguments: ["-w"], prefix: prefix)
        wait.executableURL = wineServerBinary
        let waitStatus = try await runCancellable(wait, log: log)
        return Self.isSuccessfulCleanupStop(killStatus: killStatus, waitStatus: waitStatus)
    }

    public func configureSolidWorksCompatibility(prefix: URL) async throws {
        let status = try await runCancellable(
            makeProcess(arguments: Self.solidWorksCompatibilityArguments, prefix: prefix),
            log: logDirectory(prefix.path).appendingPathComponent("solidworks-compatibility.log")
        )
        guard status == 0 else {
            throw error("SOLIDWORKS 输入兼容设置失败，请查看 solidworks-compatibility.log。", status)
        }
    }

    public func runMSIExec(arguments: [String], prefix: URL, log: URL) async throws -> Int32 {
        try await runCancellable(
            makeProcess(arguments: arguments, prefix: prefix),
            log: log
        )
    }

    /// msiexec 返回后 wineserver 可能仍在收尾；官方安装包也会留下更新器
    /// 之类的辅助进程，必须在继续之前让它们沉降或退出。
    public func waitWineserver(prefix: URL, seconds: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                let process = self.makeProcess(arguments: ["-w"], prefix: prefix)
                process.executableURL = self.wineServerBinary
                let status = try? await self.runCancellable(
                    process,
                    log: self.logDirectory(prefix.path).appendingPathComponent("wineserver.log")
                )
                return status == 0
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return false
            }
            let settled = await group.next() ?? false
            group.cancelAll()
            return settled
        }
    }

    public func launchSolidWorks(
        executable: URL,
        prefix: URL,
        onStarted: @escaping () -> Void,
        completion: @escaping (Bool, String) -> Void
    ) {
        stateLock.lock()
        guard !activePrefixes.contains(prefix.path) else {
            stateLock.unlock()
            // 必须回调，否则调用方会永远停在“启动中”；真正退出由已接管该容器的那次启动通知。
            DispatchQueue.main.async { onStarted() }
            return
        }
        activePrefixes.insert(prefix.path)
        stateLock.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            let daemon = self.makeProcess(arguments: [
                Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/sw_ui_daemon.exe").path
            ], prefix: prefix, solidWorks: true)
            defer {
                if daemon.isRunning { daemon.terminate() }
                self.stateLock.lock()
                self.activePrefixes.remove(prefix.path)
                self.stateLock.unlock()
            }
            do {
                let compatibility = self.makeProcess(arguments: Self.solidWorksCompatibilityArguments, prefix: prefix)
                let compatibilityStatus = try self.run(
                    compatibility,
                    log: self.logDirectory(prefix.path).appendingPathComponent("solidworks-compatibility.log")
                )
                guard compatibilityStatus == 0 else {
                    throw self.error("SOLIDWORKS 输入兼容设置失败。", compatibilityStatus)
                }

                let daemonLog = self.logDirectory(prefix.path).appendingPathComponent("ui-daemon.log")
                let daemonHandle = try self.logHandle(for: daemonLog)
                daemon.standardOutput = daemonHandle ?? FileHandle.nullDevice
                daemon.standardError = daemonHandle ?? FileHandle.nullDevice
                try daemon.run()

                let solidWorks = self.makeProcess(arguments: [executable.path], prefix: prefix, solidWorks: true)
                solidWorks.currentDirectoryURL = executable.deletingLastPathComponent()
                let launchLog = self.logDirectory(prefix.path).appendingPathComponent("sw_launch.log")
                let handle = try self.logHandle(for: launchLog)
                solidWorks.standardOutput = handle ?? FileHandle.nullDevice
                solidWorks.standardError = handle ?? FileHandle.nullDevice
                do { try solidWorks.run() } catch {
                    try? handle?.close()
                    throw error
                }
                DispatchQueue.main.async { onStarted() }
                solidWorks.waitUntilExit()
                let result = solidWorks.terminationStatus
                try? handle?.close()
                try? daemonHandle?.close()
                DispatchQueue.main.async {
                    completion(result == 0, "SOLIDWORKS 已退出（\(result)）。")
                }
            } catch {
                DispatchQueue.main.async { completion(false, "启动失败：\(error.localizedDescription)") }
            }
        }
    }

    public func requestSolidWorksQuit(prefix: URL) async throws -> Int32 {
        try await runCancellable(
            makeProcess(arguments: Self.taskkillArguments(force: false), prefix: prefix),
            log: logDirectory(prefix.path).appendingPathComponent("solidworks-stop.log")
        )
    }

    public func forceStopSolidWorks(prefix: URL) async throws -> Int32 {
        try await runCancellable(
            makeProcess(arguments: Self.taskkillArguments(force: true), prefix: prefix),
            log: logDirectory(prefix.path).appendingPathComponent("solidworks-stop.log")
        )
    }

    static func taskkillArguments(force: Bool) -> [String] {
        var arguments = ["taskkill"]
        if force { arguments.append("/f") }
        for name in solidWorksProcessNames { arguments.append(contentsOf: ["/im", name]) }
        return arguments
    }

    public func launchTool(_ name: String, prefix: URL) throws {
        let process = makeProcess(arguments: [name], prefix: prefix)
        try process.run()
    }

    private func terminateProcess(_ process: Process) {
        guard process.isRunning else { return }
        let processIdentifier = process.processIdentifier
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if process.isRunning { Darwin.kill(processIdentifier, SIGKILL) }
        }
    }

    private func logHandle(for log: URL?) throws -> FileHandle? {
        guard let log else { return nil }
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        return handle
    }

    private func error(_ message: String, _ code: Int32) -> NSError {
        NSError(domain: "MacSW.Wine", code: Int(code), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
