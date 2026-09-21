import Foundation

public struct WineProcess: Identifiable, Equatable, Sendable {
    public let name: String
    public let pid: Int32
    public let residentKB: Int64
    /// ps 的 etime，形如 "01:23:45" 或 "1-02:03:04"（天-时:分:秒）。
    public let elapsed: String

    public init(name: String, pid: Int32, residentKB: Int64, elapsed: String) {
        self.name = name
        self.pid = pid
        self.residentKB = residentKB
        self.elapsed = elapsed
    }

    public var id: Int32 { pid }

    public var residentMB: Int64 { max(residentKB / 1024, 1) }

    /// 表头排序用的秒数；解析不出来时退回 0，不影响显示。
    public var elapsedSeconds: Int {
        let parts = elapsed.split(separator: "-")
        let days = parts.count == 2 ? Int(parts[0]) ?? 0 : 0
        let clock = (parts.last ?? Substring(elapsed)).split(separator: ":").compactMap { Int($0) }
        guard clock.count == 3 else { return days * 86_400 }
        return days * 86_400 + clock[0] * 3600 + clock[1] * 60 + clock[2]
    }
}

/// 用 macOS 侧 ps 读取容器进程，不经过 Wine，因此打开面板也能即时刷新。
public enum ProcessInventory {
    public static let primaryProcess = "SLDWORKS.exe"
    /// SOLIDWORKS 自身的进程；命令行里只有 Windows 路径，只能按名字认。
    public static let solidWorksProcesses = ["SLDWORKS.exe", "sldworks_fs.exe", "sw_ui_daemon.exe"]

    /// 属于本容器的进程：命令行里带容器路径（我们启动托管进程时传的就是宿主路径），
    /// 或带本 App 的 Wine 运行时路径，或是 SOLIDWORKS 自己的进程。
    /// Wine 会把客户进程重新挂到 launchd 下，所以不能靠父子进程关系判断。
    public static func parse(
        _ psOutput: String,
        bottlePath: String,
        wineRuntimePath: String
    ) -> [WineProcess] {
        var found: [WineProcess] = []
        for line in psOutput.split(separator: "\n") {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard columns.count >= 4,
                  let pid = Int32(columns[0]),
                  let resident = Int64(columns[1]) else { continue }
            let command = columns[3...].joined(separator: " ")
            guard belongsToContainer(
                command: command, bottlePath: bottlePath, wineRuntimePath: wineRuntimePath
            ) else { continue }
            found.append(WineProcess(
                name: displayName(of: command),
                pid: pid,
                residentKB: resident,
                elapsed: columns[2]
            ))
        }
        return found.sorted { $0.residentKB > $1.residentKB }
    }

    private static func belongsToContainer(command: String, bottlePath: String, wineRuntimePath: String) -> Bool {
        // 我们自己起的 wine 命令行（reg import、taskkill 等）是宿主侧的临时工具，
        // 不是容器里的程序；wineserver 例外，它代表容器还活着。
        if isWineLauncher(command: command, wineRuntimePath: wineRuntimePath) { return false }
        if !bottlePath.isEmpty, command.localizedCaseInsensitiveContains(bottlePath) { return true }
        if !wineRuntimePath.isEmpty, command.localizedCaseInsensitiveContains(wineRuntimePath) { return true }
        return solidWorksProcesses.contains { command.contains($0) }
    }

    private static func isWineLauncher(command: String, wineRuntimePath: String) -> Bool {
        guard !wineRuntimePath.isEmpty,
              let executable = command.split(separator: " ").first,
              executable.hasPrefix(wineRuntimePath) else { return false }
        return (String(executable) as NSString).lastPathComponent != "wineserver"
    }

    /// Windows 客户进程的 argv[0] 会被改写成 `C:\...\X.exe`，参数跟在后面；
    /// 宿主进程则是可执行文件路径。两种都取到真正的程序名。
    private static func displayName(of command: String) -> String {
        let path: String
        if let exe = command.range(of: ".exe", options: [.caseInsensitive]) {
            path = String(command[..<exe.upperBound])
        } else if let flags = command.range(of: " -") {
            path = String(command[..<flags.lowerBound])
        } else {
            path = command
        }
        return path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    }

    /// 在后台执行器上跑 ps 并等待退出，避免非隔离 async 函数沿用主线程导致界面卡顿。
    public static func snapshot(bottlePath: String, wineRuntimePath: String) async -> [WineProcess] {
        await Task.detached(priority: .utility) {
            collect(bottlePath: bottlePath, wineRuntimePath: wineRuntimePath)
        }.value
    }

    private static func collect(bottlePath: String, wineRuntimePath: String) -> [WineProcess] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["axo", "pid=,rss=,etime=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self), bottlePath: bottlePath, wineRuntimePath: wineRuntimePath)
    }

    public static func isSolidWorksRunning(_ snapshot: [WineProcess]) -> Bool {
        snapshot.contains { $0.name.caseInsensitiveCompare(primaryProcess) == .orderedSame }
    }

    public static func totalResidentMB(_ snapshot: [WineProcess]) -> Int64 {
        snapshot.reduce(Int64(0)) { $0 + $1.residentMB }
    }

    /// ps 的 etime 转成中文可读时长。
    public static func formatElapsed(_ elapsed: String) -> String {
        let parts = elapsed.split(separator: "-")
        let dayText = parts.count == 2 ? "\(parts[0]) 天 " : ""
        let clock = (parts.last ?? Substring(elapsed)).split(separator: ":").map(String.init)
        guard clock.count == 3 else { return elapsed }
        let (hour, minute) = (Int(clock[0]) ?? 0, Int(clock[1]) ?? 0)
        if hour > 0 { return "\(dayText)\(hour) 小时 \(minute) 分" }
        if minute > 0 { return "\(dayText)\(minute) 分" }
        return "\(dayText)不到 1 分"
    }
}
