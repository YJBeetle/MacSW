import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum AppLifecycleBridge {
    static func showBootstrap(openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "bootstrap")
        NSApp.activate(ignoringOtherApps: true)
    }

    static func openLegacySettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        bringSettingsToFront()
    }

    static func bringSettingsToFront() {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            settingsWindow()?.makeKeyAndOrderFront(nil)
        }
    }

    private static func settingsWindow() -> NSWindow? {
        NSApp.windows.first {
            $0.isVisible
                && $0.canBecomeKey
                && $0.title != "MacSW 安装"
                && !($0 is NSPanel)
        }
    }

    static func switchToMenuBar(window: NSWindow?) {
        window?.close()
        NSApp.setActivationPolicy(.accessory)
    }
}

struct BootstrapWindowBridge: NSViewRepresentable {
    let shouldClose: Bool

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard shouldClose else { return }
        DispatchQueue.main.async {
            AppLifecycleBridge.switchToMenuBar(window: view.window)
        }
    }
}

enum OpenPanelService {
    static func chooseInstallationMedia() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage]
        panel.message = "选择 SOLIDWORKS 官方 ISO 或安装介质目录"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFlexNetPackage() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType.archive,
            UTType.zip,
            UTType(filenameExtension: "7z") ?? .archive
        ]
        panel.message = "选择 FlexNet 目录或压缩包"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
