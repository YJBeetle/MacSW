import AppKit
import MacSWCore
import SwiftUI
import UniformTypeIdentifiers

struct BootstrapView: View {
    @ObservedObject var store: BootstrapStore
    @State private var showCleanInstallConfirmation = false
    @State private var additionalOptionsExpanded = false
    @State private var showCleanupConfirmation = false
    @State private var heights = WindowHeights()

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
        .frame(minWidth: 620)
        .reportRootHeight()
        .collectWindowHeights { heights = $0 }
        .autoHeightWindow(targetContentHeight: heights.targetContentHeight)
        .alert("全新安装会删除现有容器", isPresented: $showCleanInstallConfirmation) {
            Button("取消", role: .cancel) { }
            Button("删除并安装", role: .destructive) { store.start() }
        } message: {
            Text("容器内的程序、设置和文件将被删除；其中包含的托管 FlexNet 也会被移除。请先移出需要保留的文件。")
        }
        .alert("清理不完整安装", isPresented: $showCleanupConfirmation) {
            Button("取消", role: .cancel) { }
            Button("停止容器并删除", role: .destructive) {
                store.requestCleanupOfIncompleteInstallation()
            }
        } message: {
            Text("将删除当前 Wine 容器内的不完整安装，无法撤销。")
        }
    }

    /// 选择 FlexNet 目录后立刻给出的结构校验结果，不等开装才报错。
    private var flexNetCheckText: (text: String, isError: Bool)? {
        switch store.flexNetCheck {
        case .empty: return nil
        case .checking: return ("正在校验 lmgrd.exe 与 .lic…", false)
        case .ready(let metadata):
            return ("校验通过：端口 \(metadata.port)，许可证 \(metadata.licenseFile)，守护进程 \(metadata.vendorDaemon)。", false)
        case .rejected(let reason): return (reason, true)
        case .archiveNotChecked: return ("压缩包会在安装时解包后再校验结构。", false)
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
                            Text(store.selectedMedia?.path ?? "把官方 ISO、setup.exe 或介质目录拖进来，也可点击选择")
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

                    if store.isInspectingMedia {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("正在挂载介质并扫描序列号、语言与 FlexNet 资源…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.top, 6)
                    }
                }
                .modifier(FileDropArea { store.selectMedia($0) })

                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        additionalOptionsExpanded.toggle()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(additionalOptionsExpanded ? 90 : 0))
                            Text("安装选项").fontWeight(.medium)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    if additionalOptionsExpanded {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("静默安装", isOn: $store.silentInstall)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(store.silentInstall
                                ? "官方安装器全程无人值守，序列号与组件选择直接作为 MSI 属性传入。"
                                : "关闭后显示官方安装向导，由你在窗口内点选组件并填写序列号。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 20)
                        }

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

                        if store.silentInstall {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("安装序列号").fontWeight(.medium)
                                SerialFieldRow(
                                    title: InstallSerialField.solidWorks.title,
                                    text: $store.serialSolidWorks,
                                    isAmbiguous: store.ambiguousSerialFields.contains(.solidWorks)
                                )
                                SerialFieldRow(
                                    title: InstallSerialField.simulation.title,
                                    text: $store.serialSimulation,
                                    isAmbiguous: store.ambiguousSerialFields.contains(.simulation)
                                )
                                SerialFieldRow(
                                    title: InstallSerialField.motion.title,
                                    text: $store.serialMotion,
                                    isAmbiguous: store.ambiguousSerialFields.contains(.motion)
                                )
                                SerialFieldRow(
                                    title: InstallSerialField.mbd.title,
                                    text: $store.serialMBD,
                                    isAmbiguous: store.ambiguousSerialFields.contains(.mbd)
                                )
                                Text("SOLIDWORKS 序列号必填；其余三项只负责给随核心装上的产品授权，不决定安装范围。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("界面语言").fontWeight(.medium)
                            Picker("界面语言", selection: $store.selectedLanguage) {
                                Text("English").tag(Optional<SolidWorksLanguage>.none)
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

                        VStack(alignment: .leading, spacing: 8) {
                            Text("许可服务器").fontWeight(.medium)
                            Picker("许可服务器", selection: $store.licenseMode) {
                                ForEach(BootstrapLicenseMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.radioGroup)
                            .horizontalRadioGroupLayout()
                            .labelsHidden()

                            switch store.licenseMode {
                            case .unconfigured:
                                EmptyView()
                            case .remoteServer:
                                HStack(spacing: 8) {
                                    Text("服务器地址")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .frame(width: 84, alignment: .leading)
                                    TextField("25734@192.168.1.20", text: $store.licenseServerAddress)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(.caption, design: .monospaced))
                                }
                            case .managedFlexNet:
                                HStack(spacing: 8) {
                                    Text("FlexNet 目录")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .frame(width: 84, alignment: .leading)
                                    Text(store.flexNetDirectory?.lastPathComponent ?? "未选择")
                                        .font(.caption)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Button("选择…") {
                                        if let url = OpenPanelService.chooseFlexNetPackage() {
                                            store.chooseFlexNetDirectory(url)
                                        }
                                    }
                                }
                                if let feedback = flexNetCheckText {
                                    Text(feedback.text)
                                        .font(.caption2)
                                        .foregroundStyle(feedback.isError ? Color.orange : Color.secondary)
                                        .padding(.leading, 92)
                                }
                            }

                            Text(store.licenseMode.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if store.licenseMode == .managedFlexNet && store.flexNetCandidates.count > 1 {
                                Text("介质附近发现 \(store.flexNetCandidates.count) 个 FlexNet 目录，请用“选择…”确认要部署的那个。")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
            .reportIdealScrollHeight()
        }
        .frame(height: heights.pinnedScrollHeight)
        .reportViewportHeight()

        HStack {
            Button("查看日志") { LogReveal.open(store.paths.logs) }
            Spacer()
            Button(store.silentInstall ? "开始静默安装" : "开始安装") { requestStart() }
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
                .reportIdealScrollHeight()
            }
            .frame(height: heights.pinnedScrollHeight)
            .reportViewportHeight()
            Text(store.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Button("查看日志") { LogReveal.open(store.paths.logs) }
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
}

/// 可拖入文件URL的区域：拖入时给出描边与底色反馈，禁用状态下不接收。
private struct FileDropArea: ViewModifier {
    let receive: (URL) -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(isTargeted && isEnabled ? Color.accentColor.opacity(0.12) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isTargeted && isEnabled ? Color.accentColor : Color.clear, lineWidth: 2)
                    .allowsHitTesting(false)
            )
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isTargeted) { providers in
                guard isEnabled, let provider = providers.first else { return false }
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    guard error == nil, let url = url(from: item) else { return }
                    // 拖放会话仍在事件跟踪循环里；等它收尾再处理，否则窗口会不吃鼠标事件。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { receive(url) }
                }
                return true
            }
    }

    /// 拖放载荷可能是 URL、其归档数据，也可能是纯字符串。
    private func url(from item: Any?) -> URL? {
        if let value = item as? URL { return value }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let value = item as? String { return URL(string: value) }
        return nil
    }
}

private struct SerialFieldRow: View {
    let title: String
    @Binding var text: String
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
