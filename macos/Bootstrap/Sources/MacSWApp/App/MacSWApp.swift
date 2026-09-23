import AppKit
import MacSWCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let shell = AppShell.shared
        NSApp.setActivationPolicy(shell.activationPolicyAtLaunch)
        // 未安装时引导安装是唯一入口；已安装时只保留菜单栏，需要时由菜单或设置打开。
        if !shell.solidWorksInstalled {
            shell.showBootstrapWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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

    init() {
        let paths = AppPaths.live()
        let licenseServer = LicenseServerStore(paths: paths)
        let bootstrap = BootstrapStore(paths: paths, licensing: licenseServer)
        let resourceMonitor = SolidWorksResourceMonitorStore(paths: paths)
        let keyboardShortcuts = WineKeyboardShortcutStore(paths: paths)
        let runtime = RuntimeStore(paths: paths, licenseServer: licenseServer)
        _bootstrap = StateObject(wrappedValue: bootstrap)
        _licenseServer = StateObject(wrappedValue: licenseServer)
        _resourceMonitor = StateObject(wrappedValue: resourceMonitor)
        _keyboardShortcuts = StateObject(wrappedValue: keyboardShortcuts)
        _runtime = StateObject(wrappedValue: runtime)
        AppShell.shared.configure {
            AnyView(BootstrapSceneRoot(store: bootstrap, runtime: runtime))
        }
        let autoLaunch = AppPreferences.autoLaunchSolidWorks()
        Task { @MainActor in
            await licenseServer.refreshInstallation()
            runtime.startup(autoLaunch: autoLaunch)
        }
    }

    var body: some Scene {
        MenuBarExtra("MacSW", systemImage: "cube.fill") {
            MenuBarPanelView(runtime: runtime, licenseServer: licenseServer)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(
                runtime: runtime,
                licenseServer: licenseServer,
                resourceMonitor: resourceMonitor,
                keyboardShortcuts: keyboardShortcuts
            )
        }
    }
}
