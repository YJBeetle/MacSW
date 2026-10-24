import Foundation

/// Interactive file opens are independent of automation sessions. A short-lived
/// Python COM client attaches to the existing host in this exact Wine prefix.
public struct DocumentOpeningService: Sendable {
    let bundleURL: URL
    let wine: WineService

    public init(bundleURL: URL = Bundle.main.bundleURL, wine: WineService = .shared) {
        self.bundleURL = bundleURL
        self.wine = wine
    }

    public func open(_ file: URL, prefix: URL) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await openUsingBridge(file, prefix: prefix) }
            group.addTask {
                try await Task.sleep(nanoseconds: 600_000_000_000)
                throw SolidWorksDocument.failure("打开文件超时。未终止 SOLIDWORKS，也未自动重试；请先在 SW 中确认文档和对话框状态。")
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func openUsingBridge(_ file: URL, prefix: URL) async throws {
        let resource = bundleURL.appendingPathComponent("Contents/Resources/SWCLI/bin/open_document.py")
        let script = try String(contentsOf: resource, encoding: .utf8)
        // Keep the result inside the existing C: mapping, even with no Z: drive.
        let result = prefix.appendingPathComponent("drive_c/MacSW/.document-open-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: result.path, contents: Data(),
                                            attributes: [.posixPermissions: 0o600]) else {
            throw SolidWorksDocument.failure("无法创建文件打开结果记录。")
        }
        defer { try? FileManager.default.removeItem(at: result) }
        let path = try await wine.windowsPath(for: file, prefix: prefix)
        let output = try await wine.windowsPath(for: result, prefix: prefix)
        let process = wine.makeProcess(arguments: [#"C:\MacSW\Python311\pythonw.exe"#,
            "-B", "-c", script, path, output], prefix: prefix, solidWorks: true)
        let captured = try await wine.capturePairCancellable(process)
        guard let response = try? JSONDecoder().decode(Response.self, from: Data(contentsOf: result)) else {
            throw SolidWorksDocument.failure("文件打开助手未返回有效结果（退出码 \(captured.status)），请检查 SW 启动和许可状态。")
        }
        guard captured.status == 0, response.success else {
            throw SolidWorksDocument.failure(response.message ?? "SOLIDWORKS 未确认文件已打开。")
        }
    }

    private struct Response: Decodable {
        let success: Bool
        let message: String?
    }
}
