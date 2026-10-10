import Darwin
import Foundation

/// Pure file-based preflight: querying Wine here would itself update the bottle.
public enum WineRuntimeService {
    private static func failure(_ message: String) -> NSError {
        MacSWError.make(message, domain: "MacSW.WineRuntime")
    }
    public enum State: String, Sendable {
        case unmanaged, fresh, baseline, ready, upgrade, recovery, invalid

        public var allowsLaunch: Bool { self == .ready || self == .fresh || self == .unmanaged }
        public var message: String {
            switch self {
            case .unmanaged: return "自定义容器未纳入 Wine 升级管理。"
            case .fresh: return "容器尚未初始化，安装完成后记录版本。"
            case .baseline: return "尚未记录已知可用的 Wine 版本。请确认当前版本可用后记录基线。"
            case .ready: return "容器与当前 Wine / Mono / 补丁一致。"
            case .upgrade: return "Wine、Mono、补丁或 App 位置已变化；请先备份并迁移容器。"
            case .recovery: return "有未完成的迁移；新版 Wine 已阻止启动，请先恢复。"
            case .invalid: return "Wine 版本记录无效；新版 Wine 已阻止启动，请检查升级日志。"
            }
        }
    }

    public static func root(prefix: URL) -> URL {
        prefix.deletingLastPathComponent().appendingPathComponent(".\(prefix.lastPathComponent).wine-runtime")
    }

    public static func identity(contents: URL) throws -> [String: String] {
        let data = try Data(contentsOf: contents.appendingPathComponent("Resources/BuildManifest.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
        let values = plist.reduce(into: [String: String]()) { result, entry in
            if (entry.key.hasPrefix("Wine") || entry.key.hasPrefix("Mono")), let value = entry.value as? String {
                result[entry.key] = value
            }
        }
        guard ["WineVersion", "MonoVersion", "WineMacModuleSHA256", "WineInputModuleSHA256",
               "WineCOMBaseModuleSHA256", "WineComctl32V6ModuleSHA256", "WineNtdllModuleSHA256",
               "WineLoaderSHA256", "MonoPatchSHA256", "MonoMscorlibSHA256", "MonoRegAsmX86SHA256",
               "MonoRegAsmX64SHA256"].allSatisfy({ !(values[$0] ?? "").isEmpty }) else {
            throw failure("Wine / Mono 构建身份不完整。")
        }
        let msxmlKeys = ["WineMSXMLSchemaPatchSHA256", "WineMSXML3ModuleSHA256"]
        if msxmlKeys.contains(where: { values[$0] != nil }),
           !msxmlKeys.allSatisfy({ !(values[$0] ?? "").isEmpty }) {
            throw failure("MSXML 运行时构建身份不完整。")
        }
        return values
    }

    public static func status(prefix: URL, bundle: URL = Bundle.main.bundleURL) -> State {
        let directory = root(prefix: prefix)
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.appendingPathComponent("pending.json").path) { return .recovery }
        let main = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacSW/bottle")
        guard prefix.standardizedFileURL == main || fm.fileExists(atPath: directory.path) else { return .unmanaged }
        guard fm.fileExists(atPath: prefix.appendingPathComponent("drive_c").path) else { return .fresh }
        let receipt = directory.appendingPathComponent("receipt.json")
        guard fm.fileExists(atPath: receipt.path) else { return .baseline }
        do {
            let value = try JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any] ?? [:]
            let marker = prefix.appendingPathComponent(".macsw-wine-prefix-id")
            guard let id = try? String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                  id == value["prefix_id"] as? String else { return .baseline }
            guard value["format"] as? Int == 1, let recorded = value["identity"] as? [String: String] else { return .invalid }
            let sameLocation = (value["active_app"] as? String).map { $0 == bundle.resolvingSymlinksInPath().path } ?? true
            return recorded == (try identity(contents: bundle.appendingPathComponent("Contents"))) && sameLocation ? .ready : .upgrade
        } catch { return .invalid }
    }

    public static func canRollback(prefix: URL) -> Bool {
        do {
            let directory = root(prefix: prefix)
            let journal = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("last-upgrade.json"))) as? [String: Any]
            let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("receipt.json"))) as? [String: Any]
            guard let previous = journal?["new_identity"] as? [String: String],
                  let current = receipt?["identity"] as? [String: String] else { return false }
            return previous == current
        } catch { return false }
    }

    /// Shared launch-lock protocol with wine_runtime.py. Hold only across
    /// preflight + Process.run, so explicit migration can stop existing hosts.
    static func withLaunchLock<T>(prefix: URL, checkIdentity: Bool = true, operation: () throws -> T) throws -> T {
        guard status(prefix: prefix) != .unmanaged else { return try operation() }
        let directory = root(prefix: prefix)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try directory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw failure("Wine 升级状态目录不能是符号链接。")
        }
        let fd = open(directory.appendingPathComponent("launch.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("无法打开 Wine 启动锁。") }
        defer { close(fd) }
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { throw failure("Wine 容器升级正在执行。") }
        defer { flock(fd, LOCK_UN) }
        let state = status(prefix: prefix)
        guard !checkIdentity || state.allowsLaunch else { throw failure(state.message + " 请打开设置 → 维护。") }
        return try operation()
    }

    public static func perform(_ command: String, prefix: URL, bundle: URL = Bundle.main.bundleURL) async throws -> String {
        try await Task.detached {
            let contents = bundle.appendingPathComponent("Contents")
            let resources = contents.appendingPathComponent("Resources/SWCLI")
            let process = Process()
            process.executableURL = resources.appendingPathComponent("runtime/PythonNative/bin/python3")
            process.arguments = ["-I", resources.appendingPathComponent("bin/wine_runtime.py").path,
                                 command, "--contents", contents.path, "--prefix", prefix.path]
            let log = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-wine-upgrade-\(UUID().uuidString).log")
            guard FileManager.default.createFile(atPath: log.path, contents: nil) else { throw failure("无法创建迁移日志。") }
            defer { try? FileManager.default.removeItem(at: log) }
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            process.waitUntilExit()
            let message = String(decoding: try Data(contentsOf: log), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else { throw failure(message) }
            return message
        }.value
    }
}
