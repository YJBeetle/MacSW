import Foundation

public struct WineProcess: Equatable, Sendable {
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

    public var residentMB: Int64 { max(residentKB / 1024, 1) }
}

/// 用 macOS 侧 ps 读取容器进程，不经过 Wine，因此打开菜单面板也能即时刷新。
public enum ProcessInventory {
    public static let monitoredProcesses = [
        "SLDWORKS.exe", "sldworks_fs.exe", "sw_ui_daemon.exe", "wineserver"
    ]
    public static let primaryProcess = "SLDWORKS.exe"

    public static func parse(_ psOutput: String) -> [WineProcess] {
        var found: [WineProcess] = []
        for line in psOutput.split(separator: "\n") {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard columns.count >= 4,
                  let pid = Int32(columns[0]),
                  let resident = Int64(columns[1]) else { continue }
            let command = columns[3...].joined(separator: " ")
            guard let name = monitoredProcesses.first(where: { command.contains($0) }) else { continue }
            if found.contains(where: { $0.name == name }) { continue }
            found.append(WineProcess(name: name, pid: pid, residentKB: resident, elapsed: columns[2]))
        }
        return monitoredProcesses.compactMap { name in found.first { $0.name == name } }
    }

    /// 在后台执行器上跑 ps 并等待退出，避免非隔离 async 函数沿用主线程导致界面卡顿。
    public static func snapshot() async -> [WineProcess] {
        await Task.detached(priority: .utility) { collect() }.value
    }

    private static func collect() -> [WineProcess] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["axo", "pid=,rss=,etime=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    public static func isSolidWorksRunning(_ snapshot: [WineProcess]) -> Bool {
        snapshot.contains { $0.name == primaryProcess }
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
