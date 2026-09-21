import Foundation

/// 用户拖入或选择的东西如何变成一份 SOLIDWORKS 安装介质。
public enum ResolvedMedia: Equatable, Sendable {
    case iso(URL)
    /// 介质目录；explicitlySelected 表示用户直接选中的就是这个目录本身。
    case directory(URL, explicitlySelected: Bool)

    /// 附属文件（序列号文本、FlexNet 目录）的扫描根。
    public var attachmentDirectory: URL {
        switch self {
        case .iso(let url):
            return url.deletingLastPathComponent()
        case .directory(let url, let explicitlySelected):
            return explicitlySelected ? url : url.deletingLastPathComponent()
        }
    }

    /// 安装时真正使用的介质根目录。
    public var mediaDirectory: URL {
        switch self {
        case .iso(let url): return url.deletingLastPathComponent()
        case .directory(let url, _): return url
        }
    }

    public var isIso: Bool {
        if case .iso = self { return true }
        return false
    }

    public var displayURL: URL {
        switch self {
        case .iso(let url): return url
        case .directory(let url, _): return url
        }
    }
}

public enum InstallationMediaResolver {
    public static let maximumDepth = 1

    /// 在给定目录及其一级子目录里定位介质；找不到返回 nil。
    public static func resolve(_ dropped: URL, fileManager: FileManager = .default) -> ResolvedMedia? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dropped.path, isDirectory: &isDirectory) else { return nil }

        if !isDirectory.boolValue {
            let extensionName = dropped.pathExtension.lowercased()
            if extensionName == "iso" { return .iso(dropped.standardizedFileURL) }
            if extensionName == "exe", dropped.lastPathComponent.caseInsensitiveCompare("setup.exe") == .orderedSame {
                return .directory(dropped.deletingLastPathComponent().standardizedFileURL, explicitlySelected: false)
            }
            return nil
        }

        let selected = dropped.standardizedFileURL
        // 先在本级与一级子目录里找 setup.exe，再找 ISO；都按由浅到深、路径排序取首个。
        if let exe = findFile(named: "setup.exe", under: selected, fileManager: fileManager) {
            return .directory(
                exe.deletingLastPathComponent(),
                explicitlySelected: exe.deletingLastPathComponent().standardizedFileURL == selected
            )
        }
        if fileManager.fileExists(atPath: selected.appendingPathComponent("swwi/data/solidworks.msi").path) {
            return .directory(selected, explicitlySelected: true)
        }
        if let iso = findFile(withExtension: "iso", under: selected, fileManager: fileManager) {
            return .iso(iso)
        }
        return nil
    }

    private static func findFile(
        named name: String,
        under directory: URL,
        fileManager: FileManager,
        depth: Int = 0
    ) -> URL? {
        guard depth <= maximumDepth else { return nil }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let files = entries.filter {
            ((try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true)
                && $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
        }.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        if let found = files.first { return found }
        let subdirectories = entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        for child in subdirectories {
            if let found = findFile(named: name, under: child, fileManager: fileManager, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    private static func findFile(
        withExtension extensionName: String,
        under directory: URL,
        fileManager: FileManager,
        depth: Int = 0
    ) -> URL? {
        guard depth <= maximumDepth else { return nil }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let files = entries.filter {
            ((try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true)
                && $0.pathExtension.caseInsensitiveCompare(extensionName) == .orderedSame
        }.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        if let found = files.first { return found }
        let subdirectories = entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        for child in subdirectories {
            if let found = findFile(withExtension: extensionName, under: child, fileManager: fileManager, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

}
