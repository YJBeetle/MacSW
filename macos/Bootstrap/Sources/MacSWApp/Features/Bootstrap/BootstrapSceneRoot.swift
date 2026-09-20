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
                // launch() 自己会在状态未知时先探测，这里不再并发触发一次刷新造成竞态。
                if autoLaunchSolidWorks { runtime.launch() }
                AppShell.shared.closeBootstrapWindow()
            }
    }
}
