import AppKit
import MacSWCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let installed = AppPaths.live().solidWorksInstalled
        NSApp.setActivationPolicy(installed ? .accessory : .regular)
        if installed {
            DispatchQueue.main.async {
                NSApp.windows
                    .filter { $0.title == "MacSW 安装" }
                    .forEach { $0.close() }
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct MacSWApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("MacSW.autoLaunchSolidWorks") private var autoLaunchSolidWorks = true
    @StateObject private var bootstrap: BootstrapStore
    @StateObject private var licenseServer: LicenseServerStore
    @StateObject private var runtime: RuntimeStore

    init() {
        let paths = AppPaths.live()
        let licenseServer = LicenseServerStore(paths: paths)
        let runtime = RuntimeStore(paths: paths, licenseServer: licenseServer)
        _bootstrap = StateObject(wrappedValue: BootstrapStore(paths: paths))
        _licenseServer = StateObject(wrappedValue: licenseServer)
        _runtime = StateObject(wrappedValue: runtime)
        let defaults = UserDefaults.standard
        let key = "MacSW.autoLaunchSolidWorks"
        let shouldAutoLaunch = defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
        Task { @MainActor in runtime.startup(autoLaunch: shouldAutoLaunch) }
    }

    var body: some Scene {
        Window("MacSW 安装", id: "bootstrap") {
            BootstrapSceneRoot(
                store: bootstrap,
                runtime: runtime,
                autoLaunchSolidWorks: autoLaunchSolidWorks
            )
        }
        .defaultSize(width: 680, height: 640)

        MenuBarExtra("MacSW", systemImage: "cube.fill") {
            MenuBarView(runtime: runtime, licenseServer: licenseServer)
        }

        Settings {
            SettingsView(runtime: runtime, licenseServer: licenseServer)
        }
    }
}
