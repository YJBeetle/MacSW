import Foundation

public final class IsoService: @unchecked Sendable {
    public static let shared = IsoService()
    private let wine: WineService

    public init(wine: WineService = .shared) {
        self.wine = wine
    }

    public func mount(_ iso: URL) async throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", iso.path, "-nobrowse", "-plist"]
        let (status, output) = try await wine.captureCancellable(process)
        guard status == 0 else { throw error("挂载安装介质失败。") }
        let data = Data(output.utf8)
        guard let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = propertyList["system-entities"] as? [[String: Any]],
              let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw error("安装介质已挂载，但无法取得挂载路径。")
        }
        return URL(fileURLWithPath: mountPoint, isDirectory: true)
    }

    public func unmount(_ mountPoint: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint.path, "-force"]
        try? process.run()
        process.waitUntilExit()
    }

    private func error(_ message: String) -> NSError {
        NSError(domain: "MacSW.ISO", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
