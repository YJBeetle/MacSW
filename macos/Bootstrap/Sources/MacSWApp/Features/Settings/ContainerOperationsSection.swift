import AppKit
import MacSWCore
import SwiftUI

struct ContainerOperationsSection: View {
    @ObservedObject var runtime: RuntimeStore
    @Binding var runtimeAction: String?

    var body: some View {
        Section("容器操作") {
            HStack {
                Text(runtime.wineRuntimeState.message)
                    .font(.caption).foregroundStyle(.secondary)
                if runtime.isMigratingWine { ProgressView().controlSize(.small) }
            }
            HStack(spacing: 8) {
                switch runtime.wineRuntimeState {
                case .baseline:
                    Button("记录当前可用版本…") { runtimeAction = "baseline" }
                case .upgrade:
                    Button("升级容器") { runtimeAction = "upgrade" }
                case .recovery:
                    Button("重试升级…") { runtimeAction = "recover" }
                default:
                    EmptyView()
                }
                Button("重启容器") { runtime.restartContainer() }
                    .disabled(!runtime.wineRuntimeState.allowsLaunch || !runtime.paths.bottleExists)
                Button(role: .destructive) { runtime.forceStop() } label: {
                    Text("强制停止全部进程").foregroundStyle(.red)
                }
                .disabled(runtime.processes.isEmpty)
            }
            .disabled(runtime.isMigratingWine)
            HStack {
                Button("安装或重新安装 SOLIDWORKS…") { AppShell.shared.showBootstrapWindow() }
                    .disabled(runtime.isMigratingWine)
                Spacer()
                Button("查看记录与日志") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath:
                        WineRuntimeService.root(prefix: runtime.paths.bottle).path)
                }
            }
            if !runtime.statusMessage.isEmpty && !runtime.statusMessage.hasPrefix(runtime.wineRuntimeState.message) {
                Text(runtime.statusMessage)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}
