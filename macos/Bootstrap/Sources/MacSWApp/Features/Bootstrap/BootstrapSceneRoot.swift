import AppKit
import MacSWCore
import SwiftUI

struct BootstrapSceneRoot: View {
    @ObservedObject var store: BootstrapStore
    @ObservedObject var runtime: RuntimeStore

    var body: some View {
        BootstrapView(store: store)
            .onReceive(NotificationCenter.default.publisher(for: .macSWInstallationCompleted)) { _ in
                // launch() 自己会在状态未知时先探测，这里不再并发触发一次刷新造成竞态。
                // 偏好按当前值读：窗口开着的那半小时里用户可能改过"自动启动"。
                if AppPreferences.autoLaunchSolidWorks() { runtime.launch() }
                AppShell.shared.closeBootstrapWindow()
            }
    }
}
