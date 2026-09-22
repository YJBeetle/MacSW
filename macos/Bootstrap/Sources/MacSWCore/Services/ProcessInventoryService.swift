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

    /// 单行显示用的近似值（再小也记 1 MB）；合计不要用它累加，见 `totalResidentMB`。
    public var residentMB: Int64 { max(residentKB / 1024, 1) }

    /// ps 的 etime 是 `[[DD-]hh:]mm:ss`，不满一小时只有 `mm:ss` 两段。
    private var elapsedComponents: (days: Int, clock: [Int]) {
        let parts = elapsed.split(separator: "-")
        let days = parts.count == 2 ? Int(parts[0]) ?? 0 : 0
        return (days, (parts.last ?? Substring(elapsed)).split(separator: ":").compactMap { Int($0) })
    }

    /// 表头排序用的秒数；解析不出来时退回 0，不影响显示。
    public var elapsedSeconds: Int {
        let parsed = elapsedComponents
        switch parsed.clock.count {
        case 3: return parsed.days * 86_400 + parsed.clock[0] * 3600 + parsed.clock[1] * 60 + parsed.clock[2]
        case 2: return parsed.days * 86_400 + parsed.clock[0] * 60 + parsed.clock[1]
        default: return parsed.days * 86_400
        }
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

    /// 宿主侧起的 wine 工具（reg import、taskkill 这些临时命令行）不是容器里的程序，
    /// wineserver 例外，它代表容器还活着。按 `<运行时>/bin/` 前缀认，
    /// 不能按空格切第一个字段：容器或 App 的路径里可能有空格。
    private static func isWineLauncher(command: String, wineRuntimePath: String) -> Bool {
        guard !wineRuntimePath.isEmpty else { return false }
        let binaries = wineRuntimePath.hasSuffix("/") ? wineRuntimePath + "bin/" : wineRuntimePath + "/bin/"
        guard command.hasPrefix(binaries) else { return false }
        return !command.hasPrefix(binaries + "wineserver")
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

    /// 合计按 KB 累加后再换算：逐行向上取整会把五十个小进程报成多出的 50 MB。
    public static func totalResidentMB(_ snapshot: [WineProcess]) -> Int64 {
        snapshot.reduce(Int64(0)) { $0 + $1.residentKB } / 1024
    }

    /// MB 数字超过 1 GB 时换成 GB 显示。
    public static func formatMegabytes(_ megabytes: Int64) -> String {
        megabytes >= 1024 ? String(format: "%.1f GB", Double(megabytes) / 1024) : "\(megabytes) MB"
    }

    /// ps 的 etime 转成中文可读时长。
    public static func formatElapsed(_ elapsed: String) -> String {
        let parts = elapsed.split(separator: "-")
        let dayText = parts.count == 2 ? "\(parts[0]) 天 " : ""
        let clock = (parts.last ?? Substring(elapsed)).split(separator: ":").compactMap { Int($0) }
        switch clock.count {
        case 3:
            if clock[0] > 0 { return "\(dayText)\(clock[0]) 小时 \(clock[1]) 分" }
            if clock[1] > 0 { return "\(dayText)\(clock[1]) 分" }
            return "\(dayText)不到 1 分"
        case 2:
            // 不满一小时 ps 只给 mm:ss，别把原始串直接甩给用户。
            if clock[0] > 0 { return "\(dayText)\(clock[0]) 分" }
            return "\(dayText)不到 1 分"
        default:
            return elapsed
        }
    }
}
