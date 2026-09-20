import AppKit
import MacSWCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let shell = AppShell.shared
        NSApp.setActivationPolicy(shell.activationPolicyAtLaunch)
        // 未安装时引导安装是唯一入口；已安装时只保留菜单栏，需要时由菜单或设置打开。
        if !shell.installedAtLaunch {
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
    @AppStorage(AppPreferences.autoLaunchSolidWorksKey) private var autoLaunchSolidWorks = AppPreferences.autoLaunchSolidWorksDefault
    @StateObject private var bootstrap: BootstrapStore
    @StateObject private var licenseServer: LicenseServerStore
    @StateObject private var runtime: RuntimeStore

    init() {
        let paths = AppPaths.live()
        let bootstrap = BootstrapStore(paths: paths)
        let licenseServer = LicenseServerStore(paths: paths)
        let runtime = RuntimeStore(paths: paths, licenseServer: licenseServer)
        _bootstrap = StateObject(wrappedValue: bootstrap)
        _licenseServer = StateObject(wrappedValue: licenseServer)
        _runtime = StateObject(wrappedValue: runtime)
        AppShell.shared.configure {
            AnyView(BootstrapSceneRoot(
                store: bootstrap,
                runtime: runtime,
                autoLaunchSolidWorks: AppPreferences.autoLaunchSolidWorks()
            ))
        }
        let autoLaunch = AppPreferences.autoLaunchSolidWorks()
        Task { @MainActor in
            await licenseServer.refreshInstallation()
            runtime.startup(autoLaunch: autoLaunch)
        }
    }

    var body: some Scene {
        MenuBarExtra("MacSW", systemImage: "cube.fill") {
            MenuBarView(runtime: runtime, licenseServer: licenseServer)
        }

        Settings {
            SettingsView(runtime: runtime, licenseServer: licenseServer)
        }
    }
}
