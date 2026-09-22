import AppKit
import MacSWCore
import SwiftUI
import UniformTypeIdentifiers

private let bootstrapWindowIdentifier = NSUserInterfaceItemIdentifier(BootstrapWindowIdentity.identifier)

@MainActor
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

@MainActor
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

/// 设置窗口打开期间把 App 提回常规模式（出现 Dock 图标），关掉后回到纯菜单栏。
/// 没有 Dock 图标时设置窗口很难被找到和置顶，尤其是从菜单栏面板点齿轮进来的时候。
struct SettingsWindowLifecycle: NSViewRepresentable {
    final class Coordinator {
        var observed: NSWindow?
        var closeObserver: NSObjectProtocol?

        deinit {
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { attach(to: view, coordinator: context.coordinator) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { self.attach(to: view, coordinator: context.coordinator) }
    }

    private func attach(to view: NSView, coordinator: Coordinator) {
        guard let window = view.window, coordinator.observed !== window else { return }
        // 换窗口（关闭后重开）之前必须摘掉上一个观察者，否则每次重开都留一个永久的监听。
        if let closeObserver = coordinator.closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        coordinator.observed = window
        AppShell.shared.settingsWindowVisible = true
        coordinator.closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            Task { @MainActor in AppShell.shared.settingsWindowVisible = false }
        }
    }
}
