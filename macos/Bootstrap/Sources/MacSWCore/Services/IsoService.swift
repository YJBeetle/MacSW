import Foundation

/// 介质挂载结果。复用别人（Finder 或上次运行）已经挂好的卷时不属于我们，
/// 安装结束也不能把它卸载，否则会把用户桌面上正挂着的盘踢掉。
public struct MountedMedia: Equatable, Sendable {
    public let mountPoint: URL
    public let isOurs: Bool

    public init(mountPoint: URL, isOurs: Bool) {
        self.mountPoint = mountPoint
        self.isOurs = isOurs
    }
}

public final class IsoService: @unchecked Sendable {
    public static let shared = IsoService()
    private let wine: WineService

    public init(wine: WineService = .shared) {
        self.wine = wine
    }

    public func mount(_ iso: URL) async throws -> MountedMedia {
        if let existing = try existingMountPoint(of: iso) {
            return MountedMedia(mountPoint: existing, isOurs: false)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", iso.path, "-nobrowse", "-plist"]
        let (status, output) = try await wine.captureCancellable(process)
        guard status == 0 else {
            let reason = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            throw error(reason.isEmpty ? "挂载安装介质失败。" : "挂载安装介质失败：\(reason)")
        }
        guard let mountPoint = try mountPoint(in: output) else {
            throw error("安装介质已挂载，但无法取得挂载路径。")
        }
        return MountedMedia(mountPoint: mountPoint, isOurs: true)
    }

    public func unmount(_ mounted: MountedMedia) {
        guard mounted.isOurs else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mounted.mountPoint.path, "-force"]
        try? process.run()
        process.waitUntilExit()
    }

    /// 该镜像是否已经挂在某处；已挂载时再 attach 会得到"资源暂时不可用"。
    func existingMountPoint(of iso: URL, fileManager: FileManager = .default) throws -> URL? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: iso.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        let output = try run(process)
        guard let images = try plist(output)?["images"] as? [[String: Any]] else { return nil }
        for image in images {
            guard let path = image["image-path"] as? String,
                  path.caseInsensitiveCompare(iso.path) == .orderedSame,
                  let entities = image["system-entities"] as? [[String: Any]] else { continue }
            if let mount = entities.lazy.compactMap({ $0["mount-point"] as? String }).first {
                return URL(fileURLWithPath: mount, isDirectory: true)
            }
        }
        return nil
    }

    private func mountPoint(in plistText: String) throws -> URL? {
        guard let root = try plist(plistText),
              let entities = root["system-entities"] as? [[String: Any]] else { return nil }
        guard let path = entities.lazy.compactMap({ $0["mount-point"] as? String }).first else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func plist(_ text: String) throws -> [String: Any]? {
        let data = Data(text.utf8)
        return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private func run(_ process: Process) throws -> String {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let handle = pipe.fileHandleForReading
        let data = handle.readDataToEndOfFile()
        handle.closeFile()
        return String(decoding: data, as: UTF8.self)
    }

    private func error(_ message: String) -> NSError {
        NSError(domain: "MacSW.ISO", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
