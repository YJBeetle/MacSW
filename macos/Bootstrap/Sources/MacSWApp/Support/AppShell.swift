import AppKit
import MacSWCore
import SwiftUI

/// 应用外壳状态：启动时是「引导安装」还是「菜单栏常驻」的唯一判定处。
/// 引导窗口由 AppKit 托管，不参与 SwiftUI 的窗口恢复，因此不会出现
/// 「已安装却每次启动闪出安装窗口」的情况。
final class AppShell: ObservableObject {
    static let shared = AppShell()

    private let paths: AppPaths
    private var rootViewFactory: (() -> AnyView)?
    private var presenter: BootstrapWindowPresenter?

    /// 有可见窗口时才要 Dock 图标；两个都关掉就回到纯菜单栏。
    @MainActor var bootstrapWindowVisible = false {
        didSet { refreshActivationPolicy() }
    }
    @MainActor var settingsWindowVisible = false {
        didSet { refreshActivationPolicy() }
    }

    private init(paths: AppPaths = .live()) {
        self.paths = paths
    }

    /// 装没装读实时状态（结果由 AppPaths 缓存，不是每次扫盘）：
    /// 首次安装完成之后要能从"引导中"的 .regular 切回纯菜单栏，启动快照做不到。
    var solidWorksInstalled: Bool { paths.solidWorksInstalled }

    var activationPolicyAtLaunch: NSApplication.ActivationPolicy {
        solidWorksInstalled ? .accessory : .regular
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

    @MainActor func refreshActivationPolicy() {
        guard NSApp.isRunning else { return }
        let wantsDockTile = bootstrapWindowVisible || settingsWindowVisible
        NSApp.setActivationPolicy(wantsDockTile || !solidWorksInstalled ? .regular : .accessory)
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
            AppShell.shared.bootstrapWindowVisible = true
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
        // 由本控制器持有；关闭只隐藏，避免 AppKit 释放后再次访问导致过度释放。
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: makeRootView())
        window.delegate = self
        window.setFrameAutosaveName("MacSW.BootstrapWindow")
        window.center()
        AppShell.shared.bootstrapWindowVisible = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    /// 只隐藏不销毁：窗口与内容视图在进程存活期内复用。
    func close() {
        window?.orderOut(nil)
        AppShell.shared.bootstrapWindowVisible = false
    }

    func windowWillClose(_ notification: Notification) {
        AppShell.shared.bootstrapWindowVisible = false
    }
}
