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
    /// 裸工具名会先经过 Wine start.exe 的 Shell 解析，在 winemac 下平白加载一遍
    /// user32/shell32（实测约 3.5 秒）。只为已知系统工具补全路径，外部 EXE 原样保留。
    private static let systemToolPaths = [
        "cmd": #"C:\windows\system32\cmd.exe"#,
        "msiexec": #"C:\windows\system32\msiexec.exe"#,
        "reg": #"C:\windows\system32\reg.exe"#,
        "regedit": #"C:\windows\regedit.exe"#,
        "taskkill": #"C:\windows\system32\taskkill.exe"#,
        "wineboot": #"C:\windows\system32\wineboot.exe"#,
        "winecfg": #"C:\windows\system32\winecfg.exe"#
    ]
    /// 停止时必须覆盖整套进程，只杀主程序会留下文件服务。
    /// 名单与"哪些进程算 SOLIDWORKS 自己的"是同一件事，只在 ProcessInventory 里定义一次。
    public static let solidWorksProcessNames = ProcessInventory.solidWorksProcesses
    public var runtimeURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/wine")
    }

    public var wineBinary: URL {
        runtimeURL.appendingPathComponent("lib/wine/x86_64-unix/MacSW")
    }

    public var wineServerBinary: URL {
        runtimeURL.appendingPathComponent("bin/wineserver")
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
            "WINEDLLOVERRIDES", "MONO_ENV_OPTIONS", "MACSW_WINELOADER", "MACSW_APP_NAME"
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
        process.arguments = Self.resolvingSystemTool(in: arguments)
        process.environment = environment(winePrefix: prefix, solidWorks: solidWorks)
        return process
    }

    static func resolvingSystemTool(in arguments: [String]) -> [String] {
        guard let command = arguments.first,
              let explicit = systemToolPaths[command.lowercased()] else { return arguments }
        return [explicit] + arguments.dropFirst()
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
        // Wine 的常驻 wineserver 会继承子进程的 stderr。若用 Pipe 并等 EOF，
        // reg.exe 等短命令已经退出后，这里仍会一直等到 wineserver 退出。
        // 临时文件在命令退出后即可读取，不受后代进程持有描述符的影响。
        let outputFile = try CaptureFile()
        defer { outputFile.cleanup() }
        let errorFile = try CaptureFile()
        defer { errorFile.cleanup() }
        process.standardOutput = outputFile.handle
        process.standardError = errorFile.handle
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
        try Task.checkCancellation()
        try outputFile.handle.close()
        try errorFile.handle.close()
        let output = try Data(contentsOf: outputFile.url)
        let errors = try Data(contentsOf: errorFile.url)
        // Wine 工具在中文 locale 下会输出遗留代码页字节（如 reg 的本地化“默认”），
        // 严格解码会整体失败并丢掉 ASCII 内容，这里按有损 UTF-8 解码。
        return (status, String(decoding: output, as: UTF8.self), String(decoding: errors, as: UTF8.self))
    }

    private struct CaptureFile {
        let url: URL
        let handle: FileHandle

        init() throws {
            var path = Array(FileManager.default.temporaryDirectory
                .appendingPathComponent("MacSW-capture-XXXXXX").path.utf8CString)
            let descriptor = mkstemp(&path)
            guard descriptor >= 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            url = URL(fileURLWithPath: String(cString: path))
            handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }

        func cleanup() {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
        }
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
        onStarted: @escaping @MainActor @Sendable () -> Void,
        completion: @escaping @MainActor @Sendable (Bool, String) -> Void
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
            var launchHandle: FileHandle?
            defer {
                try? launchHandle?.close()
                self.stateLock.lock()
                self.activePrefixes.remove(prefix.path)
                self.stateLock.unlock()
            }
            do {
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

    /// CMD 是控制台程序；从图形应用直接启动时没有交互式终端，读到 EOF 就会退出。
    /// 通过 Terminal 的伪终端运行同一份 Wine 和容器，避免依赖当前不可用的 wineconsole 图形后端。
    public func launchCommandPromptInTerminal(prefix: URL) async throws {
        let script = """
        on run argv
            tell application "Terminal"
                activate
                do script (item 1 of argv)
            end tell
        end run
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, commandPromptTerminalCommand(prefix: prefix)]
        let (status, output) = try await captureCancellable(process)
        guard status == 0 else {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MacSWError.make(
                detail.isEmpty ? "无法打开 macOS 终端（退出码 \(status)）。" : "无法打开 macOS 终端：\(detail)",
                domain: "MacSW.WineService"
            )
        }
    }

    func commandPromptTerminalCommand(prefix: URL) -> String {
        let wineEnvironment = environment(winePrefix: prefix)
        let keys = ["WINEPREFIX", "WINELOADER", "WINESERVER", "LANG", "LC_ALL", "WINEDEBUG", "WINE_MONO_AOT"]
        let assignments = keys.compactMap { key in
            wineEnvironment[key].map { "\(key)=\(Self.shellQuote($0))" }
        }
        let cmd = Self.systemToolPaths["cmd"]!
        return (["env"] + assignments + [Self.shellQuote(wineBinary.path), Self.shellQuote(cmd)]).joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
