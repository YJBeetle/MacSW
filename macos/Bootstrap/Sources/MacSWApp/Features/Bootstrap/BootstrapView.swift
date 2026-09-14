import AppKit
import MacSWCore
import SwiftUI
import UniformTypeIdentifiers

struct BootstrapView: View {
    @ObservedObject var store: BootstrapStore
    @State private var showCleanInstallConfirmation = false
    @State private var showRegistryWarning = false
    @State private var showCleanupConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            if store.state.isActive || isTerminalState {
                progressContent
            } else {
                configurationContent
            }
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 560)
        .alert("全新安装会删除现有容器", isPresented: $showCleanInstallConfirmation) {
            Button("取消", role: .cancel) { }
            Button("删除并安装", role: .destructive) { beginAfterWarnings() }
        } message: {
            Text("容器内的程序、设置和文件将被删除；其中包含的托管 FlexNet 也会被移除。请先移出需要保留的文件。")
        }
        .alert("将原样导入注册表文件", isPresented: $showRegistryWarning) {
            Button("取消", role: .cancel) { }
            Button("继续导入") { store.start() }
        } message: {
            Text("MacSW 不会过滤或改写此文件。它可能修改 Wine 容器中的任意注册表项：\n\n\(store.selectedSerialFile?.url.path ?? "")")
        }
        .alert("清理不完整安装", isPresented: $showCleanupConfirmation) {
            Button("取消", role: .cancel) { }
            Button("停止容器并删除", role: .destructive) {
                Task {
                    do { try await store.cleanIncompleteInstallation() }
                    catch { /* Store retains the user-facing state from the failed operation. */ }
                }
            }
        } message: {
            Text("将删除当前 Wine 容器内的不完整安装，无法撤销。")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 36))
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 3) {
                Text("安装 SOLIDWORKS").font(.title2.bold())
                Text("Bootstrap 只负责准备官方安装介质与 Wine 运行环境")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var configurationContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("SOLIDWORKS 安装介质") {
                    HStack(spacing: 14) {
                        Image(systemName: store.selectedMedia == nil ? "opticaldisc" : "checkmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(store.selectedMedia == nil ? Color.secondary : Color.green)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.selectedMedia?.lastPathComponent ?? "尚未选择")
                                .fontWeight(.semibold)
                            Text(store.selectedMedia?.path ?? "支持官方 ISO 或包含 swwi/data/solidworks.msi 的目录")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button(store.selectedMedia == nil ? "选择…" : "更换…") {
                            if let url = OpenPanelService.chooseInstallationMedia() { store.selectMedia(url) }
                        }
                    }
                    .padding(.vertical, 6)
                }

                DisclosureGroup("附加选项") {
                    VStack(alignment: .leading, spacing: 14) {
                        if store.showsCleanInstall {
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle("全新安装", isOn: $store.cleanInstall)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if store.cleanInstall {
                                    Text("删除整个 Wine 容器后重新部署；不会创建备份。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.leading, 20)
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("预载序列号", isOn: $store.preloadSerialNumbers)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if store.preloadSerialNumbers {
                                VStack(alignment: .leading, spacing: 12) {
                                    Picker("输入方式", selection: $store.serialInputMode) {
                                        ForEach(SerialInputMode.allCases) { Text($0.rawValue).tag($0) }
                                    }
                                    .pickerStyle(.segmented)

                                    if store.serialInputMode == .text {
                                        SerialTextEditor(text: $store.serialText)
                                    } else {
                                        serialFilePicker
                                    }
                                }
                                .padding(.leading, 20)
                            }
                        }
                    }
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

                Text(store.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }

        HStack {
            Button("查看日志") { openLogs() }
            Spacer()
            Button("开始安装") { requestStart() }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canStart)
        }
    }

    private var serialFilePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.selectedSerialFile?.url.lastPathComponent ?? "尚未选择文件")
                    Text(store.selectedSerialFile?.url.path ?? "支持 .txt 与 .reg")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("选择…") {
                    if let url = OpenPanelService.chooseSerialInput() { store.selectSerialFile(url) }
                }
            }
            if store.serialCandidates.count > 1 {
                Picker("检测到多个文件", selection: $store.selectedSerialFile) {
                    Text("请选择").tag(Optional<SerialInputFile>.none)
                    ForEach(store.serialCandidates) { candidate in
                        Text(candidate.url.lastPathComponent).tag(Optional(candidate))
                    }
                }
            }
            if store.selectedSerialFile?.kind == .registry {
                Label("该文件将在确认后原样导入", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var progressContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProgressView(value: progressValue, total: Double(InstallationStep.allCases.count))
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(InstallationStep.allCases) { step in
                        InstallationStepRow(
                            step: step,
                            status: store.stepStatuses[step] ?? .pending,
                            detail: store.stepDetails[step]
                        )
                    }
                }
            }
            Text(store.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Button("查看日志") { openLogs() }
                Spacer()
                if store.state.isActive {
                    Button("停止安装", role: .destructive) { store.cancel() }
                        .disabled(store.state == .cancelling)
                } else {
                    Button("清理不完整安装…", role: .destructive) { showCleanupConfirmation = true }
                    Button("调整选项并重试") { store.resetAfterFailure() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var isTerminalState: Bool {
        switch store.state {
        case .cancelled, .failed: return true
        default: return false
        }
    }

    private var progressValue: Double {
        Double(store.stepStatuses.values.filter { [.completed, .warning, .skipped].contains($0) }.count)
    }

    private func requestStart() {
        if store.cleanInstall { showCleanInstallConfirmation = true }
        else { beginAfterWarnings() }
    }

    private func beginAfterWarnings() {
        if store.selectedRegistryWillImportRaw { showRegistryWarning = true }
        else { store.start() }
    }

    private func openLogs() {
        try? FileManager.default.createDirectory(at: store.paths.logs, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.paths.logs)
    }
}

private struct SerialTextEditor: View {
    @Binding var text: String

    private static let placeholder = """
    SolidWorks           XXXX XXXX XXXX XXXX XXXX XXXX
    COSMOSWorks          XXXX XXXX XXXX XXXX XXXX XXXX
    COSMOSMotion         XXXX XXXX XXXX XXXX XXXX XXXX
    COSMOSFloWorks       XXXX XXXX XXXX XXXX XXXX XXXX
    Composer             XXXX XXXX XXXX XXXX XXXX XXXX
    ComposerPlayer       XXXX XXXX XXXX XXXX XXXX XXXX
    Inspection           XXXX XXXX XXXX XXXX XXXX XXXX
    MBD                  XXXX XXXX XXXX XXXX XXXX XXXX
    Plastics             XXXX XXXX XXXX XXXX XXXX XXXX
    Electrical 2D        XXXX XXXX XXXX XXXX XXXX XXXX
    Electrical 3D        XXXX XXXX XXXX XXXX XXXX XXXX
    PCB                  XXXX XXXX XXXX XXXX XXXX XXXX
    Visualize            XXXX XXXX XXXX XXXX XXXX XXXX
    Visualize Boost      XXXX XXXX XXXX XXXX XXXX XXXX
    CAM                  XXXX XXXX XXXX XXXX XXXX XXXX
    SolidNetWork License XXXX XXXX XXXX XXXX XXXX XXXX
    """

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 190)
            if text.isEmpty {
                Text(Self.placeholder)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
    }
}

private struct InstallationStepRow: View {
    let step: InstallationStep
    let status: InstallationStepStatus
    let detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(step.title).fontWeight(.medium)
                    Spacer()
                    Text(status.rawValue).font(.caption).foregroundStyle(color)
                }
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 7)
        if step != InstallationStep.allCases.last { Divider() }
    }

    private var symbol: String {
        switch status {
        case .running: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .pending, .skipped: return "circle"
        }
    }

    private var color: Color {
        switch status {
        case .running: return .purple
        case .completed: return .green
        case .failed: return .red
        case .warning: return .orange
        case .cancelled: return .secondary
        case .pending, .skipped: return .secondary
        }
    }
}
