import AppKit
import Foundation

/// "查看日志"在各处都是同一件事：目录可能还没建，先建再交给访达。
enum LogReveal {
    static func open(_ directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }
}
