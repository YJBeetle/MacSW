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
    /// 许可清单是纯文本，再大就不是许可文件。
    static let maximumLicenseBytes = 1_024_000
    /// 托管目录里的单个文件上限：FlexNet 组件是几十 MB 量级，超出的更像是误选的整个盘。
    static let maximumPackageFileBytes: Int64 = 512 * 1024 * 1024

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
        // 只认真正有内容的普通文件：目录、符号链接、0 字节占位文件都不算 lmgrd.exe 或许可证。
        let files = entries.compactMap { url -> (url: URL, size: Int64)? in
            guard case .regularFile(let size)? = entryKind(of: url) else { return nil }
            return (url, size)
        }.filter { $0.size > 0 }

        guard files.contains(where: { $0.url.lastPathComponent.caseInsensitiveCompare("lmgrd.exe") == .orderedSame }) else {
            throw failure("FlexNet 目录缺少有效的 lmgrd.exe。")
        }
        let licenses = files.filter { $0.url.pathExtension.caseInsensitiveCompare("lic") == .orderedSame }
        guard let license = licenses.first, licenses.count == 1 else {
            throw failure("FlexNet 目录必须且只能包含一个 .lic 文件。")
        }
        guard license.size <= Self.maximumLicenseBytes else {
            throw failure("许可证文件超过 \(Self.maximumLicenseBytes / 1024) KB，不像许可清单。")
        }
        let lines = try licenseText(at: license.url).components(separatedBy: .newlines)
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
        guard let daemon = files.first(where: {
            $0.url.lastPathComponent.caseInsensitiveCompare("\(vendor).exe") == .orderedSame
        }) else { throw failure("FlexNet 目录缺少许可证引用的 \(vendor).exe。") }
        return ManagedFlexNetInstallation(
            port: port,
            licenseFile: license.url.lastPathComponent,
            vendorDaemon: daemon.url.lastPathComponent
        )
    }

    /// 许可文件只需要 ASCII 关键字；Windows 导出的 .lic 常带 ANSI/GBK 注释，
    /// 严格 UTF-8 会整体失败并把可用文件判死，所以退到有损 UTF-8。
    private func licenseText(at url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else { throw failure("无法读取许可证文件。") }
        return PlainTextDecoder.decode(data) ?? String(decoding: data, as: UTF8.self)
    }

    /// 跟随符号链接会把 /dev/zero 之类的目标当成"有效的 exe"，所以统一用 lstat 判类型和大小。
    private enum EntryKind {
        case regularFile(Int64)
        case directory
    }

    private func entryKind(of url: URL) -> EntryKind? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return .regularFile(Int64(info.st_size))
        case S_IFDIR: return .directory
        default: return nil
        }
    }

    /// 托管即独占：写入的服务器列表只有这一条 `端口@localhost`，不与用户手填的地址混排。
    public func install(from source: URL) async throws -> ManagedFlexNetInstallation {
        let fileManager = FileManager.default
        let sourceDirectory: URL
        var extractionDirectory: URL?
        // 解包之后到写入完成之前任何一步抛错都要清临时目录，所以 defer 必须紧跟在创建之后。
        defer { if let extractionDirectory { try? fileManager.removeItem(at: extractionDirectory) } }
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
                switch entryKind(of: entry) {
                case .regularFile(let size) where size > Self.maximumPackageFileBytes:
                    throw failure("\(entry.lastPathComponent) 有 \(size / (1024 * 1024)) MB，不像 FlexNet 组件。")
                case .regularFile, .directory:
                    try fileManager.copyItem(at: entry, to: staging.appendingPathComponent(entry.lastPathComponent))
                case nil:
                    continue
                }
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

    /// 在解压结果里找包根目录，层数上限与介质扫描用同一条规则（FlexNetLocator）。
    private func locatePackageRoot(in source: URL) throws -> URL {
        if (try? inspect(directory: source)) != nil { return source }
        let rootPath = source.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { throw failure("无法检查 FlexNet 包结构。") }
        var matches: [URL] = []
        for case let candidate as URL in enumerator {
            let depth = candidate.standardizedFileURL.path.dropFirst(rootPath.count + 1)
                .split(separator: "/").count
            if depth > FlexNetLocator.maximumDepth {
                enumerator.skipDescendants()
                continue
            }
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
        MacSWError.make(message, domain: "MacSW.FlexNet")
    }
}
