import AppKit
import MacSWCore
import SwiftUI

struct CommandLineToolsSection: View {
    private let service = CommandLineToolService()
    @State private var state: CommandLineToolService.State = .notInstalled
    @State private var isOperating = false
    @State private var problem: String?

    var body: some View {
        Section("命令行工具") {
            HStack {
                Text("swcli").font(.body.monospaced())
                Spacer()
                if isOperating { ProgressView().controlSize(.small) }
                Button(state == .installed ? "卸载命令行工具…" : state == .legacyInstalled ? "更新命令行工具…" : "安装到 PATH…") {
                    perform(state == .installed ? .uninstall : .install)
                }
                .disabled(isOperating || hasConflict)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        .alert("未完成命令行工具操作", isPresented: Binding(
            get: { problem != nil }, set: { if !$0 { problem = nil } }
        )) {
            Button("好", role: .cancel) { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    private var hasConflict: Bool {
        if case .conflict = state { return true }
        return false
    }

    private var detail: String {
        switch state {
        case .notInstalled:
            return "安装后可在终端直接使用 swcli。命令安装到 /usr/local/bin；需要时系统会请求授权。"
        case .installed:
            return "已安装至 /usr/local/bin/swcli。App 更新后命令同步更新；卸载仅移除命令入口。"
        case .legacyInstalled:
            return "检测到本 App 的旧版本命令入口，请更新命令行工具。"
        case let .conflict(detail):
            return detail
        }
    }

    private func refresh() { state = service.status() }

    private func perform(_ operation: CommandLineToolService.Operation) {
        isOperating = true
        Task { @MainActor in
            defer { isOperating = false; refresh() }
            do { try await service.perform(operation) }
            catch { problem = error.localizedDescription }
        }
    }
}
