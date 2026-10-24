import AppKit
import MacSWCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var updater: AppUpdater?
    static weak var fileOpener: FileOpenController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.updater?.start()
        let shell = AppShell.shared
        NSApp.setActivationPolicy(shell.activationPolicyAtLaunch)
        // 未安装时引导安装是唯一入口；已安装时只保留菜单栏，需要时由菜单或设置打开。
        if !shell.solidWorksInstalled {
            shell.showBootstrapWindow()
        }
        Self.fileOpener?.start()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Self.fileOpener?.open(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.updater?.shouldTerminate(sender) ?? .terminateNow
    }
}

@main
struct MacSWApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var bootstrap: BootstrapStore
    @StateObject private var licenseServer: LicenseServerStore
    @StateObject private var resourceMonitor: SolidWorksResourceMonitorStore
    @StateObject private var keyboardShortcuts: WineKeyboardShortcutStore
    @StateObject private var runtime: RuntimeStore
    @StateObject private var updater: AppUpdater
    @StateObject private var fileOpener: FileOpenController

    init() {
        let paths = AppPaths.live()
        let licenseServer = LicenseServerStore(paths: paths)
        let runtime = RuntimeStore(paths: paths, licenseServer: licenseServer)
        let bootstrap = BootstrapStore(paths: paths, licensing: licenseServer, runtime: runtime)
        let resourceMonitor = SolidWorksResourceMonitorStore(paths: paths)
        let keyboardShortcuts = WineKeyboardShortcutStore(paths: paths)
        _bootstrap = StateObject(wrappedValue: bootstrap)
        _licenseServer = StateObject(wrappedValue: licenseServer)
        _resourceMonitor = StateObject(wrappedValue: resourceMonitor)
        _keyboardShortcuts = StateObject(wrappedValue: keyboardShortcuts)
        _runtime = StateObject(wrappedValue: runtime)
        let updater = AppUpdater(runtime: runtime, bootstrap: bootstrap, licensing: licenseServer)
        _updater = StateObject(wrappedValue: updater)
        AppDelegate.updater = updater
        let fileOpener = FileOpenController(runtime: runtime, bootstrap: bootstrap, updater: updater)
        _fileOpener = StateObject(wrappedValue: fileOpener)
        AppDelegate.fileOpener = fileOpener
        AppShell.shared.configure {
            AnyView(UpdateGuardedBootstrap(store: bootstrap, runtime: runtime, updater: updater))
        }
        let autoLaunch = AppPreferences.autoLaunchSolidWorks()
        runtime.prepareFontLinkAtAppLaunch()
        Task { @MainActor in
            await licenseServer.refreshInstallation()
            await runtime.startup(autoLaunch: autoLaunch)
        }
    }

    var body: some Scene {
        MenuBarExtra("MacSW", systemImage: "cube.fill") {
            MenuBarPanelView(runtime: runtime, licenseServer: licenseServer, updater: updater)
                .disabled(updater.preparingInstallation || runtime.isOpeningDocument)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(
                runtime: runtime,
                licenseServer: licenseServer,
                resourceMonitor: resourceMonitor,
                keyboardShortcuts: keyboardShortcuts
            )
            .environmentObject(updater)
            .disabled(updater.preparingInstallation || runtime.isOpeningDocument)
        }
    }
}

private struct UpdateGuardedBootstrap: View {
    @ObservedObject var store: BootstrapStore
    @ObservedObject var runtime: RuntimeStore
    @ObservedObject var updater: AppUpdater

    var body: some View {
        BootstrapSceneRoot(store: store, runtime: runtime)
            .disabled(updater.preparingInstallation || runtime.isOpeningDocument)
    }
}
