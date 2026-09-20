import AppKit
import MacSWCore
import SwiftUI

struct BootstrapSceneRoot: View {
    @ObservedObject var store: BootstrapStore
    @ObservedObject var runtime: RuntimeStore
    let autoLaunchSolidWorks: Bool

    var body: some View {
        BootstrapView(store: store)
            .onReceive(NotificationCenter.default.publisher(for: .macSWInstallationCompleted)) { _ in
                runtime.refresh()
                if autoLaunchSolidWorks { runtime.launch() }
                AppShell.shared.closeBootstrapWindow()
            }
    }
}
