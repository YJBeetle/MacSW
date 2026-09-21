import Foundation

/// 在附属资源目录里寻找随附的 FlexNet 服务器包：判据是目录里有 `lmgrd.exe`，
/// 不再依赖目录命名（*Flexnet*Server* 只是常见写法，不是契约）。
public enum FlexNetLocator {
    /// `lmgrd.exe` 所在目录相对搜索根的层数上限。
    public static let maximumDepth = 2
    public static let daemonName = "lmgrd.exe"

    /// 返回按路径排序的候选目录；调用方只在唯一命中时自动选中。
    public static func discover(
        in root: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        var found: [URL] = []
        collect(directory: root, depth: 0, fileManager: fileManager, into: &found)
        return found.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private static func collect(
        directory: URL,
        depth: Int,
        fileManager: FileManager,
        into found: inout [URL]
    ) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        if entries.contains(where: { $0.lastPathComponent.caseInsensitiveCompare(daemonName) == .orderedSame }) {
            // 命中即止：安装包内部不会再有第二个服务器包。
            found.append(directory)
            return
        }
        guard depth < maximumDepth else { return }
        for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            collect(directory: entry, depth: depth + 1, fileManager: fileManager, into: &found)
        }
    }
}
