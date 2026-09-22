import CryptoKit
import Foundation

public final class PrerequisiteService: @unchecked Sendable {
    public static let shared = PrerequisiteService()
    public static let themes = ["Luna", "Aero", "Classic", "Royale", "AeroLite"]
    public static let stdoleDestination = "drive_c/Program Files/Common Files/SOLIDWORKS Shared/stdole.dll"
    public static let loginManagerDestination = "drive_c/Program Files/Common Files/SOLIDWORKS Shared/LoginManager/sldLoginManager.dll"
    public static let fontsDestination = "drive_c/windows/Fonts"
    public static let notoSansSCRegularName = "NotoSansSC-Regular.otf"
    public static let notoSansSCBoldName = "NotoSansSC-Bold.otf"

    private let wine: WineService

    public init(wine: WineService = .shared) {
        self.wine = wine
    }

    public func configureMono(prefix: URL) async throws {
        let mono = wine.runtimeURL.appendingPathComponent("share/wine/mono/wine-mono-\(BuildInfo.monoVersion)")
        let data = try Data(contentsOf: mono.appendingPathComponent("bin/libmono-2.0-x86.dll"))
        guard Self.sha256(data) == BuildInfo.monoPatchSHA256 else {
            throw failure("App 内 Mono 修复版本校验失败，请使用重新打包的 App。")
        }
        let windowsPath = "Z:" + mono.path.replacingOccurrences(of: "/", with: "\\")
        let process = wine.makeProcess(arguments: [
            "reg", "add", "HKCU\\Software\\Wine\\Mono", "/v", "RuntimePath", "/t", "REG_SZ",
            "/d", windowsPath, "/f"
        ], prefix: prefix)
        let code = try await wine.runCancellable(
            process,
            log: wine.logDirectory(prefix.path).appendingPathComponent("mono-runtime.log")
        )
        guard code == 0 else { throw failure("Mono 运行时配置失败，请查看 mono-runtime.log。") }
    }

    public func prepareManagedCOMRegistration(prefix: URL) throws {
        try Self.prepareManagedCOMRegistration(runtime: wine.runtimeURL, prefix: prefix)
    }

    public static func prepareManagedCOMRegistration(
        runtime: URL,
        prefix: URL,
        expectedMscorlibSHA256: String = BuildInfo.monoMscorlibSHA256,
        expectedRegAsmX86SHA256: String = BuildInfo.monoRegAsmX86SHA256,
        expectedRegAsmX64SHA256: String = BuildInfo.monoRegAsmX64SHA256
    ) throws {
        let fileManager = FileManager.default
        let monoRoot = runtime.appendingPathComponent("share/wine/mono/wine-mono-\(BuildInfo.monoVersion)")
        let mscorlib = monoRoot.appendingPathComponent("lib/mono/4.5/mscorlib.dll")
        guard Self.sha256(try Data(contentsOf: mscorlib)) == expectedMscorlibSHA256 else {
            throw Self.failure("App 内 Wine-Mono COM 注册运行库校验失败，请使用重新打包的 App。")
        }
        let mappings = [
            ("x86_64-windows", "Framework64", expectedRegAsmX64SHA256),
            ("i386-windows", "Framework", expectedRegAsmX86SHA256)
        ]
        for (architecture, framework, expectedHash) in mappings {
            try Task.checkCancellation()
            let source = runtime.appendingPathComponent("lib/wine/\(architecture)/regasm.exe")
            let data = try Data(contentsOf: source)
            guard Self.sha256(data) == expectedHash else {
                throw Self.failure("App 内 \(framework) RegAsm 校验失败，请使用重新打包的 App。")
            }
            let target = prefix.appendingPathComponent("drive_c/windows/Microsoft.NET/\(framework)/v4.0.30319/regasm.exe")
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: target.path), try Data(contentsOf: target) == data { continue }
            try data.write(to: target, options: .atomic)
        }
        let logs = prefix.deletingLastPathComponent().appendingPathComponent("logs")
        try fileManager.createDirectory(at: logs, withIntermediateDirectories: true)
        let message = "\(Date()): Wine-Mono COM registration runtime verified; managed x86/x64 RegAsm frontends installed. Runtime: \(runtime.path)\n"
        try Data(message.utf8).write(
            to: logs.appendingPathComponent("managed-com-registration.log"),
            options: .atomic
        )
    }

    public func prepareManagedCOMDependencies(prefix: URL) throws {
        try Self.prepareManagedCOMDependencies(bundleURL: Bundle.main.bundleURL, prefix: prefix)
    }

    public func prepareManagedFonts(prefix: URL) throws {
        try Self.prepareManagedFonts(bundleURL: Bundle.main.bundleURL, prefix: prefix)
    }

    /// App 只携带 OFL 许可的 SC 区域子集。其他 CJK 区域可以沿用同一目录契约扩展，
    /// 但不在当前中文安装里无条件增加包体。
    public static func prepareManagedFonts(
        bundleURL: URL = Bundle.main.bundleURL,
        prefix: URL,
        expectedRegularSHA256: String = BuildInfo.notoSansSCRegularSHA256,
        expectedBoldSHA256: String = BuildInfo.notoSansSCBoldSHA256
    ) throws {
        let sourceDirectory = bundleURL.appendingPathComponent("Contents/Resources/fonts/NotoSansSC")
        let targetDirectory = prefix.appendingPathComponent(fontsDestination)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        for (name, expectedHash) in [
            (notoSansSCRegularName, expectedRegularSHA256),
            (notoSansSCBoldName, expectedBoldSHA256)
        ] {
            let source = sourceDirectory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw failure("App 内缺少 Noto Sans SC 字体，请使用重新打包的 App。")
            }
            let data = try Data(contentsOf: source)
            guard sha256(data) == expectedHash else {
                throw failure("App 内 Noto Sans SC 字体校验失败，请使用重新打包的 App。")
            }
            let target = targetDirectory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: target.path),
               try Data(contentsOf: target) == data { continue }
            try data.write(to: target, options: .atomic)
        }
    }

    public static func prepareManagedCOMDependencies(
        bundleURL: URL = Bundle.main.bundleURL,
        prefix: URL,
        expectedSHA256: String = BuildInfo.stdoleSHA256
    ) throws {
        let source = bundleURL.appendingPathComponent("Contents/Resources/managed/stdole.dll")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw Self.failure("App 内缺少 stdole \(BuildInfo.stdoleVersion)，请使用重新打包的 App。")
        }
        let data = try Data(contentsOf: source)
        guard Self.sha256(data) == expectedSHA256 else {
            throw Self.failure("App 内 stdole \(BuildInfo.stdoleVersion) 校验失败，请使用重新打包的 App。")
        }
        let target = prefix.appendingPathComponent(Self.stdoleDestination)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path), try Data(contentsOf: target) == data { return }
        try data.write(to: target, options: .atomic)
    }

    public func installVC(media: URL, prefix: URL) async throws {
        let installer = media.appendingPathComponent("PreReqs/VCRedist17/VC_redist.x64.exe")
        guard FileManager.default.fileExists(atPath: installer.path) else {
            throw failure("所选介质缺少 VC_redist.x64.exe。")
        }
        let logs = wine.logDirectory(prefix.path)
        let process = wine.makeProcess(arguments: [
            installer.path, "/install", "/quiet", "/norestart", "/log",
            logs.appendingPathComponent("vcredist-x64.log").path
        ], prefix: prefix)
        let code = try await wine.runCancellable(process, log: logs.appendingPathComponent("vcredist-wine.log"))
        guard WineService.isSuccessfulPrerequisiteStatus(code) else {
            throw failure("VC++ 安装失败（\(code)），请查看 \(logs.path)。")
        }
        for library in WineService.vcLibraries {
            try Task.checkCancellation()
            guard FileManager.default.fileExists(atPath: prefix.appendingPathComponent("drive_c/windows/system32/\(library).dll").path) else {
                throw failure("VC++ 安装后仍缺少 \(library).dll。")
            }
        }
    }

    public func installLoginManager(media: URL, prefix: URL) async throws {
        let installer = media.appendingPathComponent("swloginmgr/SOLIDWORKS Login Manager.msi")
        guard FileManager.default.fileExists(atPath: installer.path) else {
            throw failure("所选介质缺少 swloginmgr/SOLIDWORKS Login Manager.msi。")
        }
        let logs = wine.logDirectory(prefix.path)
        let msiLog = logs.appendingPathComponent("login-manager-install.log")
        let process = wine.makeProcess(arguments: [
            "msiexec", "/i", installer.path, "/qn", "/norestart", "DISABLEROLLBACK=1",
            "/l*v", msiLog.path
        ], prefix: prefix)
        let code = try await wine.runCancellable(process, log: logs.appendingPathComponent("login-manager-wine.log"))
        guard WineService.isSuccessfulPrerequisiteStatus(code) else {
            throw failure("SOLIDWORKS Login Manager 安装失败（\(code)），请查看 \(msiLog.path)。")
        }
        guard FileManager.default.fileExists(atPath: prefix.appendingPathComponent(Self.loginManagerDestination).path) else {
            throw failure("Login Manager 安装器已退出，但未找到 sldLoginManager.dll。")
        }
    }

    public func installLanguage(media: URL, language: SolidWorksLanguage, prefix: URL) async throws {
        let installer = media.appendingPathComponent(LanguageCatalog.relativeMSIPath(language))
        guard FileManager.default.fileExists(atPath: installer.path) else {
            throw failure("所选介质缺少 \(language.displayName) 语言资源。")
        }
        let logs = wine.logDirectory(prefix.path)
        let msiLog = logs.appendingPathComponent("language-install.log")
        let code = try await wine.runMSIExec(
            arguments: SilentInstallerPlan.languageInstallArguments(msi: installer, log: msiLog),
            prefix: prefix,
            log: logs.appendingPathComponent("language-wine.log")
        )
        guard WineService.isSuccessfulPrerequisiteStatus(code) else {
            throw failure("\(language.displayName) 语言资源安装失败（\(code)），请查看 \(msiLog.path)。")
        }
        let resources = AppPaths.resolveSolidWorksExecutable(in: prefix)
            .deletingLastPathComponent()
            .appendingPathComponent("lang/\(language.directoryName)")
        guard FileManager.default.fileExists(atPath: resources.path) else {
            throw failure("语言安装器已退出，但未找到 \(resources.path)。")
        }
    }

    /// Wine 侧部分安装动作会按 8.3 短名解析 Program Files；真实目录存在时补符号链接。
    public static func prepareShortNameAliases(prefix: URL, fileManager: FileManager = .default) throws {
        for (directory, alias) in [("Program Files", "PROGRA~1"), ("Program Files (x86)", "PROGRA~2")] {
            let root = prefix.appendingPathComponent("drive_c")
            guard fileManager.fileExists(atPath: root.appendingPathComponent(directory).path) else { continue }
            let link = root.appendingPathComponent(alias)
            let values = try? link.resourceValues(forKeys: [.isSymbolicLinkKey])
            // 已经是指向正确目标的链接就跳过；是真实目录时绝不覆盖删除。
            if values?.isSymbolicLink == true {
                let destination = (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) ?? ""
                if destination == directory { continue }
                try fileManager.removeItem(at: link)
            } else if values?.isSymbolicLink == false {
                continue
            }
            try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: directory)
        }
    }

    public func prepareShortNameAliases(prefix: URL) throws {
        try Self.prepareShortNameAliases(prefix: prefix)
    }

    /// Wine 把 drive_c/users/<用户>/Desktop 链接到真实的 macOS 桌面，官方 MSI 创建的
    /// .lnk 因此泄漏到桌面（winecfg「桌面整合」页显示的 Links to 就是这个链接）。
    /// 安装期间把 Desktop 换成容器内真实目录，结束后按原目标恢复。
    public struct DesktopRedirection: Equatable, Sendable {
        public let account: String
        /// 原有链接目标；空字符串表示原本就是真实目录或缺失，恢复时保持不动。
        public let originalDestination: String
    }

    public static func redirectDesktopFolders(
        prefix: URL,
        fileManager: FileManager = .default
    ) throws -> [DesktopRedirection] {
        var redirected: [DesktopRedirection] = []
        for account in try userAccounts(in: prefix, fileManager: fileManager) {
            let desktop = account.appendingPathComponent("Desktop")
            let destination = (try? fileManager.destinationOfSymbolicLink(atPath: desktop.path)) ?? ""
            if destination.isEmpty {
                try fileManager.createDirectory(at: desktop, withIntermediateDirectories: true)
            } else {
                try fileManager.removeItem(at: desktop)
                try fileManager.createDirectory(at: desktop, withIntermediateDirectories: true)
            }
            redirected.append(DesktopRedirection(
                account: account.lastPathComponent,
                originalDestination: destination
            ))
        }
        return redirected
    }

    public static func restoreDesktopFolders(
        prefix: URL,
        to redirected: [DesktopRedirection],
        fileManager: FileManager = .default
    ) throws {
        for entry in redirected where !entry.originalDestination.isEmpty {
            let desktop = prefix.appendingPathComponent("drive_c/users")
                .appendingPathComponent(entry.account)
                .appendingPathComponent("Desktop")
            // 已经是符号链接说明此前恢复过，保持不动。
            let existing = try? fileManager.destinationOfSymbolicLink(atPath: desktop.path)
            if existing != nil { continue }
            try? fileManager.removeItem(at: desktop)
            try? fileManager.createSymbolicLink(atPath: desktop.path, withDestinationPath: entry.originalDestination)
        }
    }

    private static func userAccounts(in prefix: URL, fileManager: FileManager) throws -> [URL] {
        guard let accounts = try? fileManager.contentsOfDirectory(
            at: prefix.appendingPathComponent("drive_c/users"),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return accounts.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    public func redirectDesktopFolders(prefix: URL) throws -> [DesktopRedirection] {
        try Self.redirectDesktopFolders(prefix: prefix)
    }

    public func restoreDesktopFolders(prefix: URL, to redirected: [DesktopRedirection]) throws {
        try Self.restoreDesktopFolders(prefix: prefix, to: redirected)
    }

    public func installThemes(media: URL, prefix: URL, target: URL) async throws {
        let fileManager = FileManager.default
        let source = media.appendingPathComponent("PreReqs/dotNetFx/ndp48-x86-x64-allos-enu.exe")
        guard fileManager.fileExists(atPath: source.path) else { throw failure("所选介质缺少 .NET 4.8 安装包。") }
        let temporary = fileManager.temporaryDirectory.appendingPathComponent("MacSW-WPF-\(UUID().uuidString)")
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporary) }
        let log = wine.logDirectory(prefix.path).appendingPathComponent("prerequisites.log")
        try await extract(source, names: ["netfx_Full.mzz"], to: temporary, log: log)
        let archive = temporary.appendingPathComponent("netfx_Full.mzz")
        let names = Self.themes.map {
            $0 == "AeroLite" ? "PresentationFramework.AeroLite.dll_amd64" : "PresentationFramework.\($0)_amd64.dll"
        }
        try await extract(archive, names: names, to: temporary, log: log)

        let framework = prefix.appendingPathComponent("drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/WPF")
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: framework, withIntermediateDirectories: true)
        for name in names {
            guard fileManager.fileExists(atPath: temporary.appendingPathComponent(name).path) else {
                throw failure("安装包中缺少 \(name)。")
            }
        }
        for (theme, name) in zip(Self.themes, names) {
            try Task.checkCancellation()
            let data = try Data(contentsOf: temporary.appendingPathComponent(name))
            let filename = "PresentationFramework.\(theme).dll"
            try data.write(to: target.appendingPathComponent(filename), options: .atomic)
            try data.write(to: framework.appendingPathComponent(filename), options: .atomic)
        }
    }

    private func extract(_ archive: URL, names: [String], to directory: URL, log: URL) async throws {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/7zz")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw failure("App 内缺少 7zz 解包工具，请重新打包。")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["e", archive.path] + names + ["-o\(directory.path)", "-y"]
        let code = try await wine.runCancellable(process, log: log)
        guard code == 0 else { throw failure("前置库提取失败（7zz: \(code)）。") }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func failure(_ message: String) -> NSError {
        MacSWError.make(message, domain: "MacSW.Prerequisites")
    }

    private func failure(_ message: String) -> NSError { Self.failure(message) }
}
