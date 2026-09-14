import AppKit
import MacSWCore
import SwiftUI

struct BootstrapSceneRoot: View {
    @ObservedObject var store: BootstrapStore
    @ObservedObject var runtime: RuntimeStore
    let autoLaunchSolidWorks: Bool
    @State private var closeAfterCompletion = false

    var body: some View {
        BootstrapView(store: store)
            .background(BootstrapWindowBridge(shouldClose: closeAfterCompletion))
            .onReceive(NotificationCenter.default.publisher(for: .macSWInstallationCompleted)) { _ in
                closeAfterCompletion = true
                runtime.refresh()
                if autoLaunchSolidWorks { runtime.launch() }
            }
            .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}
