import Foundation
import Darwin

public struct WineProcess: Identifiable, Equatable, Sendable {
    public let name: String
    public let pid: Int32
    public let residentKB: Int64
    /// ps 的 etime，形如 "01:23:45" 或 "1-02:03:04"（天-时:分:秒）。
    public let elapsed: String
    /// Native process generation; elapsed time alone cannot detect PID reuse.
    public let startIdentity: UInt64?

    public init(name: String, pid: Int32, residentKB: Int64, elapsed: String, startIdentity: UInt64? = nil) {
        self.name = name
        self.pid = pid
        self.residentKB = residentKB
        self.elapsed = elapsed
        self.startIdentity = startIdentity
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
    /// SOLIDWORKS 自身的进程；Windows 命令行不携带可区分容器的宿主路径。
    public static let solidWorksProcesses = ["SLDWORKS.exe", "sldworks_fs.exe"]

    /// 优先根据进程实际继承的 WINEPREFIX 区分容器，不能把共享运行时或同名 SW
    /// 当成归属证明。环境不可读时保留原有保守检查，避免漏掉待删除容器的进程。
    /// Wine 会把客户进程重新挂到 launchd 下，所以不能靠父子进程关系判断。
    public static func parse(
        _ psOutput: String,
        bottlePath: String,
        wineRuntimePath: String,
        processPrefixes: [Int32: String] = [:]
    ) -> [WineProcess] {
        var found: [WineProcess] = []
        for line in psOutput.split(separator: "\n") {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard columns.count >= 4,
                  let pid = Int32(columns[0]),
                  let resident = Int64(columns[1]) else { continue }
            let command = columns[3...].joined(separator: " ")
            guard belongsToContainer(
                command: command, bottlePath: bottlePath, wineRuntimePath: wineRuntimePath,
                processPrefix: processPrefixes[pid]
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

    private static func belongsToContainer(command: String, bottlePath: String, wineRuntimePath: String,
                                          processPrefix: String?) -> Bool {
        // 我们自己起的 wine 命令行（reg import、taskkill 等）是宿主侧的临时工具，
        // 不是容器里的程序；wineserver 例外，它代表容器还活着。
        if isWineLauncher(command: command, wineRuntimePath: wineRuntimePath) { return false }
        if let processPrefix {
            guard !bottlePath.isEmpty else { return false }
            return canonicalPath(processPrefix) == canonicalPath(bottlePath)
        }
        if !bottlePath.isEmpty, command.localizedCaseInsensitiveContains(bottlePath) { return true }
        if !wineRuntimePath.isEmpty, command.localizedCaseInsensitiveContains(wineRuntimePath) { return true }
        // COM 隐藏启动会把 argv[0] 写成小写 sldworks.exe -Embedding。
        // 候选阶段就要忽略大小写，否则后面根本没有机会读取它的 WINEPREFIX。
        return solidWorksProcesses.contains { command.localizedCaseInsensitiveContains($0) }
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// KERN_PROCARGS2: argc、可执行路径、填充 NUL、argc 个 argv、填充 NUL、环境变量。
    /// 只提取 WINEPREFIX，不缓存或输出其他环境（其中可能包含许可/凭据）。
    static func winePrefix(from arguments: Data) -> String? {
        let bytes = [UInt8](arguments)
        guard bytes.count >= MemoryLayout<Int32>.size else { return nil }
        let argc = arguments.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 4096 else { return nil }
        var cursor = MemoryLayout<Int32>.size
        func nextString() -> ArraySlice<UInt8>? {
            guard cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0) else { return nil }
            let value = bytes[cursor..<end]
            cursor = end + 1
            return value
        }
        guard nextString() != nil else { return nil }
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
        for _ in 0..<Int(argc) {
            guard nextString() != nil else { return nil }
        }
        // 参数区与环境区间也可能有填充；Wine 改写 argv 后尤其会留下大量 NUL。
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
        let key = Array("WINEPREFIX=".utf8)
        while let entry = nextString(), !entry.isEmpty {
            guard entry.starts(with: key) else { continue }
            guard let prefix = String(bytes: entry.dropFirst(key.count), encoding: .utf8),
                  prefix.hasPrefix("/") else { return nil }
            return prefix
        }
        return nil
    }

    static func winePrefix(pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
              size >= MemoryLayout<Int32>.size, size <= 4 * 1024 * 1024 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let status = buffer.withUnsafeMutableBytes { pointer in
            sysctl(&mib, UInt32(mib.count), pointer.baseAddress, &size, nil, 0)
        }
        guard status == 0 else { return nil }
        return winePrefix(from: Data(buffer.prefix(size)))
    }

    static func startIdentity(pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    /// Never use the UI's path/name heuristics as permission to signal a PID.
    /// Recheck its generation, live name and actual prefix immediately before use.
    static func signalAuxiliary(_ target: WineProcess, signal: Int32,
                                bottlePath: String, wineRuntimePath: String) async throws {
        guard let identity = target.startIdentity,
              let live = try await snapshotForUpdate(bottlePath: bottlePath, wineRuntimePath: wineRuntimePath)
                .first(where: { $0.pid == target.pid }),
              live.startIdentity == identity, live.name == target.name,
              live.name.caseInsensitiveCompare(primaryProcess) != .orderedSame,
              let prefix = winePrefix(pid: live.pid), canonicalPath(prefix) == canonicalPath(bottlePath),
              startIdentity(pid: live.pid) == identity else { return }
        if kill(live.pid, signal) != 0 && errno != ESRCH {
            throw MacSWError.make("未能结束容器进程 \(live.name)（\(live.pid)）。", domain: "MacSW.Shutdown")
        }
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
            (try? collect(bottlePath: bottlePath, wineRuntimePath: wineRuntimePath)) ?? []
        }.value
    }

    /// Destructive/update decisions must not interpret a failed ps as no clients.
    public static func snapshotForUpdate(bottlePath: String, wineRuntimePath: String) async throws -> [WineProcess] {
        try await Task.detached(priority: .utility) {
            try collect(bottlePath: bottlePath, wineRuntimePath: wineRuntimePath)
        }.value
    }

    private static func collect(bottlePath: String, wineRuntimePath: String) throws -> [WineProcess] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["axo", "pid=,rss=,etime=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MacSWError.make("无法确认容器进程状态，暂不允许安装更新。", domain: "MacSW.Update")
        }
        let output = String(decoding: data, as: UTF8.self)
        // 只对 Wine 路径或 Windows 形式命令行的候选读取归属，不扫描其他应用环境。
        let candidates = parse(output, bottlePath: bottlePath, wineRuntimePath: wineRuntimePath)
        var candidateIDs = Set(candidates.map(\.pid))
        // Windows rewrites argv[0]. Generic helpers (Python, Notepad, etc.) do
        // not necessarily contain a host path; discover them before reading
        // only their WINEPREFIX, then use that prefix as ownership evidence.
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = Int32(fields[0]) else { continue }
            let command = String(fields[3]).trimmingCharacters(in: .whitespaces)
            if command.range(of: #"(?i)^(?:[a-z]:[\\/]|[^\s/\\]+\.exe(?:\s|$))"#,
                             options: .regularExpression) != nil { candidateIDs.insert(pid) }
        }
        var prefixes: [Int32: String] = [:]
        var identities: [Int32: UInt64] = [:]
        for pid in candidateIDs {
            let before = startIdentity(pid: pid)
            if let prefix = winePrefix(pid: pid) { prefixes[pid] = prefix }
            if let before, startIdentity(pid: pid) == before { identities[pid] = before }
        }
        return parse(output, bottlePath: bottlePath, wineRuntimePath: wineRuntimePath, processPrefixes: prefixes).map {
            WineProcess(name: $0.name, pid: $0.pid, residentKB: $0.residentKB, elapsed: $0.elapsed,
                        startIdentity: identities[$0.pid])
        }
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
