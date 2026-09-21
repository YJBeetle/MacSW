import AppKit
import Darwin
import Foundation

public final class WineService: @unchecked Sendable {
    public static let shared = WineService()
    private let stateLock = NSLock()
    private var activePrefixes = Set<String>()

    /// 单个日志文件的大小上限，超过就从头写。
    static let maximumLogBytes: Int64 = 4 * 1024 * 1024
    public static let vcLibraries = [
        "concrt140", "msvcp140", "msvcp140_1", "msvcp140_2", "msvcp140_atomic_wait",
        "msvcp140_codecvt_ids", "vcruntime140", "vcruntime140_1", "vcomp140", "mfc140u"
    ]
    /// 停止时必须覆盖整套进程，只杀主程序会留下文件服务与 UI 守护进程。
    /// 名单与"哪些进程算 SOLIDWORKS 自己的"是同一件事，只在 ProcessInventory 里定义一次。
    public static let solidWorksProcessNames = ProcessInventory.solidWorksProcesses
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

    /// 随 App 打包的界面守护进程，启动 SOLIDWORKS 时一起拉起来。
    public var uiDaemonExecutable: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/sw_ui_daemon.exe")
    }

    public func isRunning(prefix: URL) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activePrefixes.contains(prefix.path)
    }

    /// `Process.terminationStatus` 只有退出码的低 8 位：msiexec 的 1603 到这里是 67，
    /// 3010（需要重启）是 194，1638 是 102。两边都归一到 8 位再比，
    /// 成功码列表里写四位码还是写截断值都不会漏判。
    private static func statusMatches(_ code: Int32, _ accepted: [Int32]) -> Bool {
        accepted.contains { ($0 & 0xFF) == (code & 0xFF) }
    }

    public static func isSuccessfulPrerequisiteStatus(_ code: Int32) -> Bool {
        statusMatches(code, [0, 3010, 194, 1638, 102])
    }

    public static func isSuccessfulInstallerStatus(_ code: Int32) -> Bool {
        statusMatches(code, [0, 3010, 194])
    }

    public static func isCancelledInstallerStatus(_ code: Int32) -> Bool {
        // Windows ERROR_INSTALL_USEREXIT (1602) 截断成 66；被信号打死时是信号号 15。
        statusMatches(code, [1602, 66, 15])
    }

    public static func isSuccessfulCleanupStop(killStatus: Int32, waitStatus: Int32) -> Bool {
        [Int32(0), 1].contains(killStatus) && waitStatus == 0
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
        let capture = try await capturePairCancellable(process)
        return (capture.status, [capture.standardOutput, capture.standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n"))
    }

    /// 分流捕获：`hdiutil -plist`、`reg query` 这类要把标准输出交给解析器的调用，
    /// 混进 stderr 的告警会让整段解析失败，所以两条流必须分开返回。
    public func capturePairCancellable(_ process: Process) async throws
        -> (status: Int32, standardOutput: String, standardError: String)
    {
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let outputTask = Task.detached { Self.drain(outputPipe.fileHandleForReading) }
        let errorTask = Task.detached { Self.drain(errorPipe.fileHandleForReading) }
        let status = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
                do {
                    try process.run()
                    if Task.isCancelled, process.isRunning { process.terminate() }
                } catch {
                    process.terminationHandler = nil
                    // 没启动成功时父进程仍握着写端，两个采集任务会永远读不到 EOF，先关掉。
                    try? outputPipe.fileHandleForWriting.close()
                    try? errorPipe.fileHandleForWriting.close()
                    continuation.resume(throwing: error)
                }
            }
        }, onCancel: {
            self.terminateProcess(process)
        })
        let output = await outputTask.value
        let errors = await errorTask.value
        try Task.checkCancellation()
        // Wine 工具在中文 locale 下会输出遗留代码页字节（如 reg 的本地化“默认”），
        // 严格解码会整体失败并丢掉 ASCII 内容，这里按有损 UTF-8 解码。
        return (status, String(decoding: output, as: UTF8.self), String(decoding: errors, as: UTF8.self))
    }

    private static func drain(_ handle: FileHandle) -> Data {
        defer { try? handle.close() }
        return handle.readDataToEndOfFile()
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
            let daemon = self.makeProcess(arguments: [self.uiDaemonExecutable.path], prefix: prefix, solidWorks: true)
            var daemonHandle: FileHandle?
            var launchHandle: FileHandle?
            defer {
                if daemon.isRunning { daemon.terminate() }
                try? daemonHandle?.close()
                try? launchHandle?.close()
                self.stateLock.lock()
                self.activePrefixes.remove(prefix.path)
                self.stateLock.unlock()
            }
            do {
                // 输入兼容设置是一次性的注册表写入，安装链路已经做过；
                // 每次启动再跑一个 wine 进程要多等 6 秒，还可能把能用的启动判成失败。
                let daemonLog = self.logDirectory(prefix.path).appendingPathComponent("ui-daemon.log")
                daemonHandle = try self.logHandle(for: daemonLog)
                daemon.standardOutput = daemonHandle ?? FileHandle.nullDevice
                daemon.standardError = daemonHandle ?? FileHandle.nullDevice
                try daemon.run()

                let solidWorks = self.makeProcess(arguments: [executable.path], prefix: prefix, solidWorks: true)
                solidWorks.currentDirectoryURL = executable.deletingLastPathComponent()
                let launchLog = self.logDirectory(prefix.path).appendingPathComponent("sw_launch.log")
                launchHandle = try self.logHandle(for: launchLog)
                solidWorks.standardOutput = launchHandle ?? FileHandle.nullDevice
                solidWorks.standardError = launchHandle ?? FileHandle.nullDevice
                try solidWorks.run()
                DispatchQueue.main.async { onStarted() }
                solidWorks.waitUntilExit()
                let result = solidWorks.terminationStatus
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

    /// 打开（必要时创建）一个追加写的日志句柄；调用方负责关闭。
    public func logHandle(for log: URL?) throws -> FileHandle? {
        guard let log else { return nil }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: log.path) {
            fileManager.createFile(atPath: log.path, contents: nil)
        } else if let size = (try? fileManager.attributesOfItem(atPath: log.path))?[.size] as? NSNumber,
                  size.int64Value > Self.maximumLogBytes {
            // wine 的输出每次都往上追加，几 MB 之后查看器只剩卡顿；旧内容已经没价值了。
            if let truncate = try? FileHandle(forWritingTo: log) {
                try? truncate.truncate(atOffset: 0)
                try? truncate.close()
            }
        }
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        return handle
    }

    private func error(_ message: String, _ code: Int32) -> NSError {
        MacSWError.make(message, domain: "MacSW.Wine", code: Int(code))
    }
}
