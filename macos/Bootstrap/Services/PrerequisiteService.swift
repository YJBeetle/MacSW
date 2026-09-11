import Foundation
import CryptoKit

/// Only extracts prerequisites, never SolidWorks CAB payloads.
final class PrerequisiteService {
    static let shared = PrerequisiteService()
    static let themes = ["Luna", "Aero", "Classic", "Royale", "AeroLite"]

    static func configureMono(prefix: URL) throws {
        let service = WineService.shared
        let mono = service.runtimeURL.appendingPathComponent("share/wine/mono/wine-mono-11.3.0")
        let data = try Data(contentsOf: mono.appendingPathComponent("bin/libmono-2.0-x86.dll"))
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == "1541b5f189664e7f3d09d7e5ee5c3ae9e1c19534b79e8331fb9a51f9c1c21562" else {
            throw NSError(domain: "MacSW.Prerequisites", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "App 内 Mono 修复版本校验失败，请使用重新打包的 App。"])
        }
        let windowsPath = "Z:" + mono.path.replacingOccurrences(of: "/", with: "\\")
        let code = try service.run(service.makeProcess(arguments: ["reg", "add",
            "HKCU\\Software\\Wine\\Mono", "/v", "RuntimePath", "/t", "REG_SZ",
            "/d", windowsPath, "/f"], prefix: prefix.path),
            log: service.logDirectory(prefix.path).appendingPathComponent("mono-runtime.log"))
        guard code == 0 else {
            throw NSError(domain: "MacSW.Prerequisites", code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "Mono 运行时配置失败，请查看 mono-runtime.log。"])
        }
    }

    /// Installation continuity only: Wine RegAsm returns zero without registering COM types.
    /// Never replace an existing native or unknown registration tool.
    static func prepareRegAsmCompatibility(runtime: URL, prefix: URL) throws {
        let fm = FileManager.default
        let mappings = [("x86_64-windows", "Framework64"), ("i386-windows", "Framework")]
        var copies: [(URL, Data)] = []
        for (architecture, framework) in mappings {
            let source = runtime.appendingPathComponent("lib/wine/\(architecture)/regasm.exe")
            let data = try Data(contentsOf: source)
            guard !data.isEmpty else {
                throw NSError(domain: "MacSW.Prerequisites", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "App 内 RegAsm 兼容文件为空，请重新打包。"])
            }
            let target = prefix.appendingPathComponent("drive_c/windows/Microsoft.NET/\(framework)/v4.0.30319/regasm.exe")
            let directory = target.deletingLastPathComponent()
            // Windows paths are case-insensitive even on a case-sensitive host volume.
            let entries = fm.fileExists(atPath: directory.path)
                ? try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) : []
            for existing in entries where existing.lastPathComponent.lowercased() == "regasm.exe" {
                guard try Data(contentsOf: existing) == data else {
                    throw NSError(domain: "MacSW.Prerequisites", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "容器存在其他版本的 RegAsm，已停止以避免覆盖：\(existing.path)"])
                }
            }
            copies.append((target, data))
        }
        // Validate both architectures before writing either destination.
        for (target, data) in copies {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        }
        let logs = prefix.deletingLastPathComponent().appendingPathComponent("logs")
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let message = "\(Date()): Wine RegAsm compatibility enabled (x86/x64). Returns zero only; managed COM registration is SKIPPED, not successful. Runtime: \(runtime.path)\n"
        try Data(message.utf8).write(to: logs.appendingPathComponent("regasm-compatibility.log"), options: .atomic)
    }

    private func failure(_ message: String) -> Error {
        NSError(domain: "MacSW.Prerequisites", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func extract(_ archive: URL, names: [String], to directory: URL, log: URL) throws {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/7zz")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw failure("App 内缺少 7zz 解包工具，请重新打包。")
        }
        let task = Process()
        task.executableURL = executable
        task.arguments = ["e", archive.path] + names + ["-o\(directory.path)", "-y"]
        let code = try WineService.shared.run(task, log: log)
        guard code == 0 else { throw failure("前置库提取失败（7zz: \(code)），请查看 \(log.path)") }
    }

    func installThemes(media: URL, prefix: URL, target: URL) throws {
        let fm = FileManager.default
        let source = media.appendingPathComponent("PreReqs/dotNetFx/ndp48-x86-x64-allos-enu.exe")
        guard fm.fileExists(atPath: source.path) else { throw failure("所选介质缺少 .NET 4.8 安装包。") }
        let temp = fm.temporaryDirectory.appendingPathComponent("MacSW-WPF-\(UUID().uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let log = WineService.shared.logDirectory(prefix.path).appendingPathComponent("prerequisites.log")
        try extract(source, names: ["netfx_Full.mzz"], to: temp, log: log)
        let names = Self.themes.map {
            $0 == "AeroLite" ? "PresentationFramework.AeroLite.dll_amd64" : "PresentationFramework.\($0)_amd64.dll"
        }
        try extract(temp.appendingPathComponent("netfx_Full.mzz"), names: names, to: temp, log: log)
        let system = prefix.appendingPathComponent("drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/WPF")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.createDirectory(at: system, withIntermediateDirectories: true)
        // Validate all sources before replacing any destination.
        for name in names {
            guard fm.fileExists(atPath: temp.appendingPathComponent(name).path) else {
                throw failure("安装包中缺少 \(name)")
            }
        }
        for (theme, name) in zip(Self.themes, names) {
            let data = try Data(contentsOf: temp.appendingPathComponent(name))
            let filename = "PresentationFramework.\(theme).dll"
            // Atomic copies avoid sharing mutable DLL inodes with other prefixes or the App bundle.
            try data.write(to: target.appendingPathComponent(filename), options: .atomic)
            try data.write(to: system.appendingPathComponent(filename), options: .atomic)
        }
    }

    func installVC(media: URL, prefix: URL) throws {
        let installer = media.appendingPathComponent("PreReqs/VCRedist17/VC_redist.x64.exe")
        guard FileManager.default.fileExists(atPath: installer.path) else { throw failure("所选介质缺少 VC_redist.x64.exe。") }
        let service = WineService.shared
        let logs = service.logDirectory(prefix.path)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        // The official runtime installer worked in the Wine 11 validation; no Python/CAB filename assumptions.
        let task = service.makeProcess(arguments: [installer.path, "/install", "/quiet", "/norestart",
            "/log", logs.appendingPathComponent("vcredist-x64.log").path], prefix: prefix.path)
        let code = try service.run(task, log: logs.appendingPathComponent("vcredist-wine.log"))
        // Unix process exit status can truncate Windows 3010/1638 to 194/102.
        guard [Int32(0), 3010, 194, 1638, 102].contains(code) else { throw failure("VC++ 安装失败（\(code)），请查看 \(logs.path)") }
        for library in WineService.vcLibraries {
            guard FileManager.default.fileExists(atPath: prefix.appendingPathComponent("drive_c/windows/system32/\(library).dll").path) else {
                throw failure("VC++ 安装后仍缺少 \(library).dll")
            }
        }
    }
}
