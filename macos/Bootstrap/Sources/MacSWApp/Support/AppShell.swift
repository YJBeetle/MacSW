import AppKit
import MacSWCore
import SwiftUI

/// 应用外壳状态：启动时是「引导安装」还是「菜单栏常驻」的唯一判定处。
/// 引导窗口由 AppKit 托管，不参与 SwiftUI 的窗口恢复，因此不会出现
/// 「已安装却每次启动闪出安装窗口」的情况。
final class AppShell: ObservableObject {
    static let shared = AppShell()

    let installedAtLaunch: Bool
    private var rootViewFactory: (() -> AnyView)?
    private var presenter: BootstrapWindowPresenter?

    private init(paths: AppPaths = .live()) {
        installedAtLaunch = paths.solidWorksInstalled
    }

    var activationPolicyAtLaunch: NSApplication.ActivationPolicy {
        installedAtLaunch ? .accessory : .regular
    }

    /// 在 App.init 里登记内容；窗口本身只在主线程真正需要时才创建。
    func configure(bootstrapRootView: @escaping () -> AnyView) {
        rootViewFactory = bootstrapRootView
    }

    @MainActor func showBootstrapWindow() {
        if presenter == nil, let rootViewFactory {
            presenter = BootstrapWindowPresenter(makeRootView: rootViewFactory)
        }
        presenter?.show()
    }

    @MainActor func closeBootstrapWindow() {
        presenter?.close()
    }
}

@MainActor
final class BootstrapWindowPresenter: NSObject, NSWindowDelegate {
    private let makeRootView: () -> AnyView
    private var window: NSWindow?

    init(makeRootView: @escaping () -> AnyView) {
        self.makeRootView = makeRootView
    }

    func show() {
        if let window {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 640),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacSW 安装"
        window.identifier = NSUserInterfaceItemIdentifier(BootstrapWindowIdentity.identifier)
        window.isRestorable = false
        window.contentView = NSHostingView(rootView: makeRootView())
        window.delegate = self
        window.setFrameAutosaveName("MacSW.BootstrapWindow")
        window.center()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func close() {
        guard let window else { return }
        self.window = nil
        window.close()
        NSApp.setActivationPolicy(AppShell.shared.installedAtLaunch ? .accessory : .regular)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow, closed === window else { return }
        window = nil
        NSApp.setActivationPolicy(AppShell.shared.installedAtLaunch ? .accessory : .regular)
    }
}
