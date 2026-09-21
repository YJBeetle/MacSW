import Foundation

/// 在附属资源目录（介质所在目录）及其一级子目录里寻找随附的 FlexNet 服务器目录。
public enum FlexNetLocator {
    public static let maximumDepth = 2

    /// 目录名形如 *Flexnet*Server*（不区分大小写）。
    public static func matches(_ directoryName: String) -> Bool {
        let lowered = directoryName.lowercased()
        return lowered.contains("flexnet") && lowered.contains("server")
    }

    /// 返回按路径排序的候选目录；调用方只在唯一命中时自动选中。
    public static func discover(
        in root: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        let rootPath = root.standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [URL] = []
        for case let url as URL in enumerator {
            let relative = url.standardizedFileURL.path.dropFirst(rootPath.count + 1)
            let depth = relative.split(separator: "/").count
            if depth > maximumDepth {
                enumerator.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  matches(url.lastPathComponent) else { continue }
            found.append(url)
        }
        return found.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }
}
