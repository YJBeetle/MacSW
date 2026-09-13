import Foundation
import CryptoKit

/// Only extracts prerequisites, never SolidWorks CAB payloads.
final class PrerequisiteService {
    static let shared = PrerequisiteService()
    static let themes = ["Luna", "Aero", "Classic", "Royale", "AeroLite"]
    static let stdoleDestination = "drive_c/Program Files/Common Files/SOLIDWORKS Shared/stdole.dll"
    static let loginManagerDestination = "drive_c/Program Files/Common Files/SOLIDWORKS Shared/LoginManager/sldLoginManager.dll"

    static func configureMono(prefix: URL) throws {
        let service = WineService.shared
        let mono = service.runtimeURL.appendingPathComponent("share/wine/mono/wine-mono-\(BuildInfo.monoVersion)")
        let data = try Data(contentsOf: mono.appendingPathComponent("bin/libmono-2.0-x86.dll"))
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == BuildInfo.monoPatchSHA256 else {
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

    /// Validate the matched Wine-Mono registration runtime and install its managed frontends.
    static func prepareManagedCOMRegistration(
        runtime: URL,
        prefix: URL,
        expectedMscorlibSHA256: String = BuildInfo.monoMscorlibSHA256,
        expectedRegAsmX86SHA256: String = BuildInfo.monoRegAsmX86SHA256,
        expectedRegAsmX64SHA256: String = BuildInfo.monoRegAsmX64SHA256
    ) throws {
        let fm = FileManager.default
        let monoRoot = runtime.appendingPathComponent("share/wine/mono/wine-mono-\(BuildInfo.monoVersion)")
        let mscorlib = monoRoot.appendingPathComponent("lib/mono/4.5/mscorlib.dll")
        let mscorlibData = try Data(contentsOf: mscorlib)
        guard sha256(mscorlibData) == expectedMscorlibSHA256 else {
            throw NSError(domain: "MacSW.Prerequisites", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "App 内 Wine-Mono COM 注册运行库校验失败，请使用重新打包的 App。"])
        }
        let mappings = [
            ("x86_64-windows", "Framework64", expectedRegAsmX64SHA256),
            ("i386-windows", "Framework", expectedRegAsmX86SHA256)
        ]
        var copies: [(URL, Data)] = []
        for (architecture, framework, expectedSHA256) in mappings {
            let source = runtime.appendingPathComponent("lib/wine/\(architecture)/regasm.exe")
            let data = try Data(contentsOf: source)
            guard sha256(data) == expectedSHA256 else {
                throw NSError(domain: "MacSW.Prerequisites", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "App 内 \(framework) RegAsm 校验失败，请使用重新打包的 App。"])
            }
            let target = prefix.appendingPathComponent("drive_c/windows/Microsoft.NET/\(framework)/v4.0.30319/regasm.exe")
            copies.append((target, data))
        }
        for (target, data) in copies {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path), try Data(contentsOf: target) == data {
                continue
            }
            try data.write(to: target, options: .atomic)
        }
        let logs = prefix.deletingLastPathComponent().appendingPathComponent("logs")
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let message = "\(Date()): Wine-Mono COM registration runtime verified; managed x86/x64 RegAsm frontends installed. Runtime: \(runtime.path)\n"
        try Data(message.utf8).write(to: logs.appendingPathComponent("managed-com-registration.log"), options: .atomic)
    }

    /// Place the exact stdole assembly validated with SOLIDWORKS next to the shared managed components.
    static func prepareManagedCOMDependencies(
        bundleURL: URL = Bundle.main.bundleURL,
        prefix: URL,
        expectedSHA256: String = BuildInfo.stdoleSHA256
    ) throws {
        let source = bundleURL.appendingPathComponent("Contents/Resources/managed/stdole.dll")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw NSError(domain: "MacSW.Prerequisites", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "App 内缺少 stdole \(BuildInfo.stdoleVersion)，请使用重新打包的 App。"])
        }
        let data = try Data(contentsOf: source)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == expectedSHA256 else {
            throw NSError(domain: "MacSW.Prerequisites", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "App 内 stdole \(BuildInfo.stdoleVersion) 校验失败，请使用重新打包的 App。"])
        }
        let target = prefix.appendingPathComponent(stdoleDestination)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path),
           try Data(contentsOf: target) == data {
            return
        }
        try data.write(to: target, options: .atomic)
    }

    private func failure(_ message: String) -> Error {
        NSError(domain: "MacSW.Prerequisites", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

    /// The root setup.exe normally orchestrates this prerequisite. MacSW runs the main MSI directly,
    /// so install it silently first while preserving a separate verbose log.
    func installLoginManager(media: URL, prefix: URL) throws {
        let installer = media.appendingPathComponent("swloginmgr/SOLIDWORKS Login Manager.msi")
        guard FileManager.default.fileExists(atPath: installer.path) else {
            throw failure("所选介质缺少 swloginmgr/SOLIDWORKS Login Manager.msi。")
        }
        let service = WineService.shared
        let logs = service.logDirectory(prefix.path)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let msiLog = logs.appendingPathComponent("login-manager-install.log")
        let task = service.makeProcess(arguments: [
            "msiexec", "/i", installer.path, "/qn", "/norestart", "DISABLEROLLBACK=1",
            "/l*v", msiLog.path
        ], prefix: prefix.path)
        let code = try service.run(task, log: logs.appendingPathComponent("login-manager-wine.log"))
        guard WineService.isSuccessfulPrerequisiteStatus(code) else {
            throw failure("SOLIDWORKS Login Manager 安装失败（\(code)），请查看 \(msiLog.path)。")
        }
        guard FileManager.default.fileExists(atPath: prefix.appendingPathComponent(Self.loginManagerDestination).path) else {
            throw failure("Login Manager 安装器已退出，但未找到 sldLoginManager.dll，请查看 \(msiLog.path)。")
        }
    }
}
