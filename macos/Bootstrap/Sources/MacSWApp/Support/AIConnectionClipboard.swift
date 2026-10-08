import AppKit
import MacSWCore

/// AppKit 只承担资源预检和剪贴板边界，不调用 Wine 或 SWCLI。
@MainActor
enum AIConnectionClipboard {
    enum CopyError: LocalizedError {
        case missingResource(URL)
        case pasteboardWriteFailed

        var errorDescription: String? {
            switch self {
            case .missingResource(let path):
                return "未找到可用的随包资源：\(path.path)。请使用完整的 MacSW.app。"
            case .pasteboardWriteFailed:
                return "无法写入系统剪贴板，请重试。"
            }
        }
    }

    static func copy(paths: AppPaths) throws {
        let information = AIConnectionInfo(
            bundleURL: Bundle.main.bundleURL,
            paths: paths,
            environment: ProcessInfo.processInfo.environment
        )
        let files = FileManager.default
        for executable in [information.cli, information.pathHelper] {
            guard files.isExecutableFile(atPath: executable.path) else {
                throw CopyError.missingResource(executable)
            }
        }
        for document in [information.skillEntry, information.usageGuide] {
            guard files.isReadableFile(atPath: document.path) else {
                throw CopyError.missingResource(document)
            }
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(information.text, forType: .string) else {
            throw CopyError.pasteboardWriteFailed
        }
    }
}
