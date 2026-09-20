import AppKit
import MacSWCore
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var runtime: RuntimeStore
    @ObservedObject var licenseServer: LicenseServerStore
    var body: some View {
        Label(solidWorksStatus, systemImage: runtime.isRunning ? "circle.fill" : "circle")
        if licenseServer.isInstalled {
            Label(flexNetStatus, systemImage: flexNetRunning ? "circle.fill" : "circle")
        }
        Divider()
        if runtime.isRunning {
            Button("退出 SOLIDWORKS…") { runtime.requestQuit() }
        } else {
            Button("启动 SOLIDWORKS") { runtime.launch() }
                .disabled(!runtime.isInstalled)
        }
        Button("安装或重新部署 SOLIDWORKS…") { AppShell.shared.showBootstrapWindow() }
        Divider()
        if #available(macOS 14.0, *) {
            SettingsMenuButton()
        } else {
            Button { AppLifecycleBridge.openLegacySettings() } label: {
                Label("设置…", systemImage: "gearshape")
            }
            .keyboardShortcut(",")
        }
        Button("退出 MacSW") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var solidWorksStatus: String {
        switch runtime.state {
        case .unavailable: return "SOLIDWORKS：未安装"
        case .stopped: return "SOLIDWORKS：已停止"
        case .starting: return "SOLIDWORKS：启动中"
        case .running: return "SOLIDWORKS：运行中"
        case .stopping: return "SOLIDWORKS：退出中"
        case .failed: return "SOLIDWORKS：异常"
        }
    }

    private var flexNetStatus: String {
        switch licenseServer.state {
        case .running(let port): return "FlexNet：运行中（\(port)）"
        case .starting: return "FlexNet：启动中"
        case .stopping: return "FlexNet：停止中"
        case .failed: return "FlexNet：异常"
        case .notInstalled, .stopped: return "FlexNet：已停止"
        }
    }

    private var flexNetRunning: Bool {
        if case .running = licenseServer.state { return true }
        return false
    }
}

@available(macOS 14.0, *)
private struct SettingsMenuButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            openSettings()
            AppLifecycleBridge.bringSettingsToFront()
        } label: {
            Label("设置…", systemImage: "gearshape")
        }
        .keyboardShortcut(",")
    }
}
