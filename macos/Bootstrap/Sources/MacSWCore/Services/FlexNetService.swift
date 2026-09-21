import Foundation

public struct ManagedFlexNetInstallation: Codable, Equatable, Sendable {
    public let port: UInt16
    public let licenseFile: String
    public let vendorDaemon: String

    public init(port: UInt16, licenseFile: String, vendorDaemon: String) {
        self.port = port
        self.licenseFile = licenseFile
        self.vendorDaemon = vendorDaemon
    }

    /// 托管即独占：容器注册表里只写这一条。
    public var managedAddress: String { "\(port)@localhost" }
}

public final class FlexNetService: @unchecked Sendable {
    public static let serviceName = "SolidWorks Flexnet Server"
    public static let manifestName = ".macsw-flexnet.json"

    private let paths: AppPaths
    private let wine: WineService
    private let registry: RegistryService

    public init(paths: AppPaths, wine: WineService = .shared, registry: RegistryService? = nil) {
        self.paths = paths
        self.wine = wine
        self.registry = registry ?? RegistryService(wine: wine)
    }

    public var installed: ManagedFlexNetInstallation? {
        let manifest = paths.managedFlexNet.appendingPathComponent(Self.manifestName)
        guard let data = try? Data(contentsOf: manifest),
              let recorded = try? JSONDecoder().decode(ManagedFlexNetInstallation.self, from: data),
              let inspected = try? inspect(directory: paths.managedFlexNet),
              recorded == inspected else { return nil }
        return recorded
    }

    public func inspect(directory: URL) throws -> ManagedFlexNetInstallation {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { throw failure("无法读取所选 FlexNet 目录。") }
        guard entries.contains(where: { $0.lastPathComponent.caseInsensitiveCompare("lmgrd.exe") == .orderedSame }) else {
            throw failure("FlexNet 目录缺少 lmgrd.exe。")
        }
        let licenses = entries.filter { $0.pathExtension.caseInsensitiveCompare("lic") == .orderedSame }
        guard licenses.count == 1, let license = licenses.first else {
            throw failure("FlexNet 目录必须且只能包含一个 .lic 文件。")
        }
        let text = try String(contentsOf: license, encoding: .utf8)
        let lines = text.components(separatedBy: .newlines)
        guard let serverLine = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("SERVER ") }),
              let portToken = serverLine.split(whereSeparator: \.isWhitespace).last,
              let port = UInt16(portToken), port > 0 else {
            throw failure(".lic 的 SERVER 行缺少有效端口。")
        }
        guard let vendorLine = lines.first(where: {
            let upper = $0.trimmingCharacters(in: .whitespaces).uppercased()
            return upper.hasPrefix("VENDOR ") || upper.hasPrefix("DAEMON ")
        }), vendorLine.split(whereSeparator: \.isWhitespace).count >= 2 else {
            throw failure(".lic 缺少 VENDOR/DAEMON 定义。")
        }
        let vendor = String(vendorLine.split(whereSeparator: \.isWhitespace)[1])
        guard let daemon = entries.first(where: {
            $0.lastPathComponent.caseInsensitiveCompare("\(vendor).exe") == .orderedSame
        }) else { throw failure("FlexNet 目录缺少许可证引用的 \(vendor).exe。") }
        return ManagedFlexNetInstallation(port: port, licenseFile: license.lastPathComponent, vendorDaemon: daemon.lastPathComponent)
    }

    /// 托管即独占：写入的服务器列表只有这一条 `端口@localhost`，不与用户手填的地址混排。
    public func install(from source: URL) async throws -> ManagedFlexNetInstallation {
        let fileManager = FileManager.default
        let sourceDirectory: URL
        var extractionDirectory: URL?
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw failure("所选 FlexNet 安装来源不存在。")
        }
        if isDirectory.boolValue {
            sourceDirectory = try locatePackageRoot(in: source)
        } else {
            let temporary = fileManager.temporaryDirectory.appendingPathComponent("MacSW-FlexNet-\(UUID().uuidString)")
            try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
            extractionDirectory = temporary
            let extractor = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/7zz")
            guard fileManager.isExecutableFile(atPath: extractor.path) else { throw failure("App 内缺少 7zz 解包工具。") }
            let process = Process()
            process.executableURL = extractor
            process.arguments = ["x", source.path, "-o\(temporary.path)", "-y"]
            let code = try await wine.runCancellable(
                process,
                log: paths.logs.appendingPathComponent("flexnet-install.log")
            )
            guard code == 0 else { throw failure("FlexNet 压缩包解压失败（\(code)）。") }
            sourceDirectory = try locatePackageRoot(in: temporary)
        }
        defer { if let extractionDirectory { try? fileManager.removeItem(at: extractionDirectory) } }

        let metadata = try inspect(directory: sourceDirectory)
        try Task.checkCancellation()
        let parent = paths.managedFlexNet.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".FlexNet.install-\(UUID().uuidString)")
        let backup = parent.appendingPathComponent(".FlexNet.backup-\(UUID().uuidString)")
        var replacedExistingInstallation = false
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for entry in try fileManager.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil) {
                try Task.checkCancellation()
                try fileManager.copyItem(at: entry, to: staging.appendingPathComponent(entry.lastPathComponent))
            }
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: staging.appendingPathComponent(Self.manifestName), options: .atomic)
            _ = try inspect(directory: staging)
            if fileManager.fileExists(atPath: paths.managedFlexNet.path) {
                try fileManager.moveItem(at: paths.managedFlexNet, to: backup)
                replacedExistingInstallation = true
            }
            do {
                try fileManager.moveItem(at: staging, to: paths.managedFlexNet)
            } catch {
                if fileManager.fileExists(atPath: backup.path) {
                    try? fileManager.moveItem(at: backup, to: paths.managedFlexNet)
                }
                throw error
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }

        do {
            try await registry.writeLicenseServers(
                .managed(port: metadata.port),
                prefix: paths.bottle,
                serviceName: Self.serviceName
            )
            if replacedExistingInstallation { try? fileManager.removeItem(at: backup) }
        } catch {
            try? fileManager.removeItem(at: paths.managedFlexNet)
            if replacedExistingInstallation { try? fileManager.moveItem(at: backup, to: paths.managedFlexNet) }
            throw error
        }
        return metadata
    }

    /// 卸载即清空列表：托管时它就是唯一一条地址，没有"保留其他地址"这回事。
    public func uninstall() async throws {
        guard installed != nil else { return }
        let target = paths.managedFlexNet.standardizedFileURL
        guard target == paths.bottle.appendingPathComponent("drive_c/opt/FlexNet").standardizedFileURL else {
            throw failure("托管 FlexNet 路径异常，拒绝删除。")
        }
        let backup = target.deletingLastPathComponent()
            .appendingPathComponent(".FlexNet.uninstall-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: target, to: backup)
        do {
            try await registry.clearLicenseServers(prefix: paths.bottle, includingServiceMarker: true)
            try? FileManager.default.removeItem(at: backup)
        } catch {
            if !FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.moveItem(at: backup, to: target)
            }
            throw error
        }
    }

    private func locatePackageRoot(in source: URL) throws -> URL {
        if (try? inspect(directory: source)) != nil { return source }
        guard let enumerator = FileManager.default.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { throw failure("无法检查 FlexNet 包结构。") }
        var matches: [URL] = []
        for case let candidate as URL in enumerator {
            guard (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if (try? inspect(directory: candidate)) != nil {
                matches.append(candidate)
                enumerator.skipDescendants()
            }
        }
        guard matches.count == 1, let match = matches.first else {
            throw failure(matches.isEmpty ? "未找到有效的 FlexNet 目录结构。" : "压缩包内存在多个 FlexNet 目录，无法自动选择。")
        }
        return match
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "MacSW.FlexNet", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
