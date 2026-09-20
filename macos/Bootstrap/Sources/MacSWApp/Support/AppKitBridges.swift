import AppKit
import MacSWCore
import SwiftUI
import UniformTypeIdentifiers

private let bootstrapWindowIdentifier = NSUserInterfaceItemIdentifier(BootstrapWindowIdentity.identifier)

enum AppLifecycleBridge {
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
                && !($0 is NSPanel)
                && $0.identifier != bootstrapWindowIdentifier
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
