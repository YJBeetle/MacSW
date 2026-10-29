import AppKit
import MacSWCore
import SwiftUI

/// AppKit owns the external open event; the shared runtime owns SW startup.
/// This is not a DocumentGroup: the actual documents belong to SOLIDWORKS.
@MainActor
final class FileOpenController: ObservableObject {
    private let queue: DocumentOpenQueue

    init(runtime: RuntimeStore, bootstrap: BootstrapStore, updater: AppUpdater) {
        queue = DocumentOpenQueue(open: { url in
            guard !bootstrap.state.isActive, !bootstrap.isInspectingMedia, !updater.preparingTermination else {
                throw NSError(domain: "MacSW.DocumentOpen", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "安装或更新正在执行，请完成后重新打开文件。"])
            }
            if !runtime.isInstalled { AppShell.shared.showBootstrapWindow() }
            try await runtime.openDocument(url)
            // Activate only the verified host in this bottle, not another
            // MacSW instance or a Wine process selected by its display name.
            if let host = runtime.processes.first(where: {
                $0.name.caseInsensitiveCompare(ProcessInventory.primaryProcess) == .orderedSame
            }) {
                NSRunningApplication(processIdentifier: host.pid)?.activate(options: [.activateIgnoringOtherApps])
            }
        }, report: { url, error in
            let alert = NSAlert()
            alert.messageText = "无法打开 \(url.lastPathComponent)"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        })
    }

    func open(_ urls: [URL]) { queue.enqueue(urls) }
    func start() { queue.start() }
}
