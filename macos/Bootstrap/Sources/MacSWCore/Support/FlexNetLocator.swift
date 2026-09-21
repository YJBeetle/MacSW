import Foundation

/// 在介质同级与其一级子目录里寻找随附的 FlexNet 服务器目录。
public enum FlexNetLocator {
    public static let nameMarker = "flexnet_server"
    public static let maximumDepth = 2

    public static func matches(_ directoryName: String) -> Bool {
        directoryName.lowercased().contains(nameMarker)
    }

    /// 返回按路径排序的候选目录；调用方只在唯一命中时自动选中。
    public static func discover(
        near mediaSource: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        let parent = mediaSource.deletingLastPathComponent()
        let rootPath = parent.standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: parent,
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
