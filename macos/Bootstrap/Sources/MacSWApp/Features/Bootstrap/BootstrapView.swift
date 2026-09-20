import AppKit
import MacSWCore
import SwiftUI
import UniformTypeIdentifiers

struct BootstrapView: View {
    @ObservedObject var store: BootstrapStore
    @State private var showCleanInstallConfirmation = false
    @State private var additionalOptionsExpanded = false
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
            Button("删除并安装", role: .destructive) { store.start() }
        } message: {
            Text("容器内的程序、设置和文件将被删除；其中包含的托管 FlexNet 也会被移除。请先移出需要保留的文件。")
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
                Text("静默完成官方介质部署，无需在安装窗口内操作")
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
                        Button {
                            store.rescanSerials()
                        } label: {
                            if store.isInspectingMedia {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(store.selectedMedia == nil)
                        .help("重新扫描介质与随附序列号文件")
                        Button(store.selectedMedia == nil ? "选择…" : "更换…") {
                            if let url = OpenPanelService.chooseInstallationMedia() { store.selectMedia(url) }
                        }
                    }
                    .padding(.vertical, 6)
                }

                DisclosureGroup("安装选项", isExpanded: $additionalOptionsExpanded) {
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

                        VStack(alignment: .leading, spacing: 8) {
                            Text("安装序列号").fontWeight(.medium)
                            SerialFieldRow(
                                title: InstallSerialField.solidWorks.title,
                                text: $store.serialSolidWorks,
                                source: store.serialSources[.solidWorks],
                                isAmbiguous: store.ambiguousSerialFields.contains(.solidWorks)
                            )
                            SerialFieldRow(
                                title: InstallSerialField.simulation.title,
                                text: $store.serialSimulation,
                                source: store.serialSources[.simulation],
                                isAmbiguous: store.ambiguousSerialFields.contains(.simulation)
                            )
                            SerialFieldRow(
                                title: InstallSerialField.motion.title,
                                text: $store.serialMotion,
                                source: store.serialSources[.motion],
                                isAmbiguous: store.ambiguousSerialFields.contains(.motion)
                            )
                            SerialFieldRow(
                                title: InstallSerialField.mbd.title,
                                text: $store.serialMBD,
                                source: store.serialSources[.mbd],
                                isAmbiguous: store.ambiguousSerialFields.contains(.mbd)
                            )
                            Text("SOLIDWORKS 序列号必填，其余三项留空即不安装对应组件。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("界面语言").fontWeight(.medium)
                            Picker("界面语言", selection: $store.selectedLanguage) {
                                Text("保留官方默认语言").tag(Optional<SolidWorksLanguage>.none)
                                ForEach(store.availableLanguages) { language in
                                    Text(language.displayName).tag(Optional(language))
                                }
                            }
                            .labelsHidden()
                            .disabled(store.availableLanguages.isEmpty)
                            Text("语言资源取自介质 swwi/lang，在主体安装完成后静默追加。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: store.serialSources) { sources in
                    if !sources.isEmpty { additionalOptionsExpanded = true }
                }

                if let hint = store.startHint {
                    Label(hint, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Text(store.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }

        HStack {
            Button("查看日志") { openLogs() }
            Spacer()
            Button("开始静默安装") { requestStart() }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canStart)
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
        else { store.start() }
    }

    private func openLogs() {
        try? FileManager.default.createDirectory(at: store.paths.logs, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.paths.logs)
    }
}

private struct SerialFieldRow: View {
    let title: String
    @Binding var text: String
    let source: URL?
    let isAmbiguous: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .leading)
                TextField("XXXX XXXX XXXX XXXX XXXX XXXX", text: $text)
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
            }
            if isAmbiguous {
                Text("随附文件中存在多个不同取值，请确认后手工填写")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if let source {
                Text("已匹配：\(source.lastPathComponent)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
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
