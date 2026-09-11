import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Official installation owns component, language and destination selection.
struct WizardView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "cube.fill").font(.system(size: 36)).foregroundColor(.purple)
                VStack(alignment: .leading, spacing: 4) {
                    Text("MacSW 部署与配置向导").font(.system(size: 18, weight: .bold))
                    Text(state.showDeploymentProgress ? "官方安装与运行环境配置" : "选择安装介质与可选配置，开始部署")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
            }
            Divider()
            if state.showDeploymentProgress {
                DeploymentProgressView(state: state)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        mediaCard
                        HStack(alignment: .top, spacing: 10) {
                            resourceCard("序列号注册表", path: state.selectedRegPath, kind: .registry, icon: "doc.badge.gearshape",
                                hint: "拖入序列号 .reg 文件") { state.selectedRegPath = nil }
                            resourceCard("许可服务", path: state.selectedLicenseDir, kind: .license, icon: "server.rack",
                                hint: "拖入许可服务目录") { state.selectedLicenseDir = nil }
                            resourceCard("组件补丁", path: state.selectedPatchDir, kind: .patch, icon: "shippingbox",
                                hint: "拖入 SOLIDWORKS Corp 目录") { state.selectedPatchDir = nil }
                        }
                        Text("拖入任意配置后自动识别同级文件，仅补齐空项。序列号注册表在安装前导入；许可服务与组件同步目前仍需在控制台手动执行。")
                            .font(.caption).foregroundColor(.secondary)
                        Text("使用官方安装器并禁止回退；发生错误时保留文件，明确显示未完成步骤。")
                            .font(.caption).foregroundColor(.secondary)
                        Text("RegAsm 兼容模式：跳过托管 COM 组件注册，让后续安装继续；相关插件功能可能不可用，仍需验证。")
                            .font(.caption).foregroundColor(.secondary)
                    }.padding(2)
                }
                .disabled(state.isOperating)
                Text(state.statusMessage).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                HStack {
                    Button("查看日志", action: openLogs)
                    Spacer()
                    if state.hasInstalledExecutable {
                        Button("返回控制台") { state.isInstalled = true }
                    }
                    Button("开始部署") { state.launchSetupExe() }
                        .buttonStyle(.borderedProminent).tint(.purple)
                        .disabled(state.selectedIsoPath == nil || state.isOperating || state.isSolidWorksRunning)
                }
            }
        }
        .padding(20)
    }

    private var mediaCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("SolidWorks 安装介质").font(.system(size: 13, weight: .bold))
                Text("必要").font(.system(size: 9)).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.red.opacity(0.15)).foregroundColor(.red).cornerRadius(4)
                Spacer()
                if state.selectedIsoPath != nil {
                    Label("已选择", systemImage: "checkmark.circle.fill").font(.caption).foregroundColor(.green)
                }
            }
            Group {
                if let url = state.selectedIsoPath {
                    HStack(spacing: 16) {
                        Image(systemName: "opticaldisc.fill").font(.system(size: 42)).foregroundColor(.green)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(url.lastPathComponent).font(.system(size: 13, weight: .semibold))
                            Text(url.path).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Button("更换…") { chooseResource(.media) }
                        Button("清除") {
                            state.selectedIsoPath = nil
                        }
                    }.padding(18)
                } else {
                    VStack(spacing: 9) {
                        Image(systemName: "opticaldisc").font(.system(size: 34)).foregroundColor(.purple)
                        Text("拖拽 SolidWorks 安装介质（.iso 镜像或目录）至此")
                            .font(.system(size: 12, weight: .medium))
                        Text("支持官方 ISO 镜像，或包含官方安装文件的目录")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                        Button("选择文件或目录…") { chooseResource(.media) }.controlSize(.small)
                    }.frame(maxWidth: .infinity).padding(14)
                }
            }
            .frame(height: 128)
            .frame(maxWidth: .infinity)
            .modifier(FileDropArea(selected: state.selectedIsoPath != nil) { select($0, for: .media) })
        }
    }

    private func resourceCard(_ title: String, path: URL?, kind: ResourceKind, icon: String,
                              hint: String, clear: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 2)
                Text("可选").font(.system(size: 9)).foregroundColor(.secondary)
                    .padding(3).background(Color.secondary.opacity(0.12)).cornerRadius(3)
            }
            VStack(spacing: 7) {
                Image(systemName: path == nil ? icon : "checkmark.circle.fill")
                    .font(.system(size: 22)).foregroundColor(path == nil ? .secondary : .green)
                Text(path?.lastPathComponent ?? hint).font(.system(size: 10, weight: .medium))
                    .lineLimit(2).truncationMode(.middle).multilineTextAlignment(.center)
                    .help(path?.path ?? hint)
                if path != nil {
                    Text("已选择").font(.system(size: 9)).foregroundColor(.green)
                }
                HStack(spacing: 6) {
                    Button(path == nil ? "选择…" : "更换…") { chooseResource(kind) }
                    if path != nil { Button("清除", action: clear) }
                }.controlSize(.mini)
            }
            .frame(maxWidth: .infinity).frame(height: 110).padding(6)
            .modifier(FileDropArea(selected: path != nil) { select($0, for: kind) })
        }.frame(maxWidth: .infinity)
    }

    private func chooseResource(_ kind: ResourceKind) {
        choose(files: kind == .media || kind == .registry, directories: kind != .registry) {
            select($0, for: kind)
        }
    }

    private func openLogs() {
        let url = WineService.shared.logDirectory(state.bottlePath.path)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    private enum ResourceKind { case media, registry, license, patch }

    private func select(_ url: URL, for kind: ResourceKind) {
        guard !state.isOperating else { return }
        var isDirectory: ObjCBool = false
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            state.statusMessage = "请选择或拖入本机可访问的文件/目录。"; return
        }
        switch kind {
        case .media:
            guard isDirectory.boolValue || url.pathExtension.lowercased() == "iso" else {
                state.statusMessage = "安装介质仅支持 ISO 或目录。"; return
            }
            state.selectedIsoPath = url
        case .registry:
            guard !isDirectory.boolValue && url.pathExtension.lowercased() == "reg" else {
                state.statusMessage = "序列号注册表区域请拖入 .reg 文件。"; return
            }
            state.selectedRegPath = url
        case .license, .patch:
            guard isDirectory.boolValue else {
                state.statusMessage = "许可服务和组件补丁区域只接受目录。"; return
            }
            if kind == .license { state.selectedLicenseDir = url } else { state.selectedPatchDir = url }
        }
        state.statusMessage = "已选择：\(url.lastPathComponent)"
        if kind != .media {
            let siblings = CompanionFileService.findSiblings(of: url)
            var filled: [String] = []
            if state.selectedRegPath == nil, let registry = siblings.registry {
                state.selectedRegPath = registry
                filled.append("序列号注册表")
            }
            if state.selectedLicenseDir == nil, let license = siblings.license {
                state.selectedLicenseDir = license
                filled.append("许可服务目录")
            }
            if state.selectedPatchDir == nil, let patch = siblings.patch {
                state.selectedPatchDir = patch
                filled.append("组件补丁目录")
            }
            if !filled.isEmpty { state.statusMessage += "；已从同级自动识别：" + filled.joined(separator: "、") }
        }
    }

    private func choose(files: Bool, directories: Bool, completion: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = files
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = false
        if files {
            panel.allowedContentTypes = [UTType(filenameExtension: directories ? "iso" : "reg") ?? .data]
        }
        if panel.runModal() == .OK, let url = panel.url { completion(url) }
    }
}

/// Same file-URL drag type as the previous cards, shared across all four inputs.
private struct FileDropArea: ViewModifier {
    let receive: (URL) -> Void
    var selected: Bool
    init(selected: Bool = false, receive: @escaping (URL) -> Void) {
        self.selected = selected
        self.receive = receive
    }
    @Environment(\.isEnabled) private var isEnabled
    @State private var isTargeted = false

    private var borderColor: Color {
        if isTargeted && isEnabled { return .purple }
        return selected ? Color.green.opacity(0.5) : Color.purple.opacity(0.35)
    }
    private var fillColor: Color {
        if isTargeted && isEnabled { return Color.purple.opacity(0.12) }
        return selected ? Color.green.opacity(0.03) : Color.secondary.opacity(0.03)
    }

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(fillColor)
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor, style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [6, 4]))
                .allowsHitTesting(false))
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isTargeted) { providers in
                guard isEnabled, providers.count == 1, let provider = providers.first else { return false }
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    guard error == nil else { return }
                    let url: URL?
                    if let value = item as? URL { url = value }
                    else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else if let value = item as? String { url = URL(string: value) }
                    else { url = nil }
                    guard let file = url, file.isFileURL else { return }
                    DispatchQueue.main.async { receive(file) }
                }
                return true
            }
    }
}

enum DeploymentStep: Int, CaseIterable, Identifiable {
    case environment = 1, vc, registry, installer, wpf, validation
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .environment: return "准备运行环境与挂载介质"
        case .vc: return "安装微软 VC++ 运行库"
        case .registry: return "预置安装序列号"
        case .installer: return "运行 SOLIDWORKS 官方安装器"
        case .wpf: return "抽取微软官方 WPF 主题库"
        case .validation: return "检查部署结果"
        }
    }
    var subtitle: String {
        switch self {
        case .environment: return "定位官方安装包，初始化唯一 Wine 容器"
        case .vc: return "运行介质中的 VC++ x64 安装包"
        case .registry: return "导入所选 .reg 文件；未选择时由安装器填写"
        case .installer: return "在官方窗口完成安装，禁用失败回退"
        case .wpf: return "补齐 Luna、Aero 等五个 WPF 主题库"
        case .validation: return "检查文件与依赖，保留错误供后续排查"
        }
    }
}
enum DeploymentStatus: String {
    case pending = "等待中", running = "进行中", completed = "已完成"
    case warning = "有警告", failed = "失败", skipped = "已跳过"
    var color: Color {
        switch self {
        case .running: return .purple
        case .completed: return .green
        case .warning: return .orange
        case .failed: return .red
        default: return .secondary
        }
    }
}
private struct DeploymentProgressView: View {
    @ObservedObject var state: AppState
    private var finished: Int {
        state.deploymentStates.values.filter { $0 == .completed || $0 == .warning || $0 == .skipped }.count
    }
    private var current: DeploymentStep {
        DeploymentStep.allCases.first { state.deploymentStates[$0] == .running }
            ?? DeploymentStep.allCases.last { state.deploymentStates[$0] != nil } ?? .environment
    }
    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 8) {
                HStack {
                    Text(state.isOperating ? "步骤 \(current.rawValue) / 6：\(current.title)" : "部署流程已结束，请检查各步骤结果")
                        .font(.system(size: 12, weight: .bold))
                    Spacer()
                    Text("\(finished) / 6").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                }
                ProgressView(value: Double(finished), total: 6).tint(.purple)
                Text("步骤进度，不代表官方安装器内部百分比").font(.system(size: 9)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.padding(12).background(Color.secondary.opacity(0.08)).cornerRadius(8)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(DeploymentStep.allCases) { step in
                        let status = state.deploymentStates[step] ?? .pending
                        HStack(alignment: .top, spacing: 12) {
                            VStack(spacing: 0) {
                                ZStack {
                                    Circle().stroke(status.color.opacity(0.5), lineWidth: 2)
                                    if status == .running { ProgressView().controlSize(.small) }
                                    else if status == .completed { Image(systemName: "checkmark").foregroundColor(.green) }
                                    else { Text("\(step.rawValue)").font(.caption).foregroundColor(status.color) }
                                }.frame(width: 26, height: 26)
                                if step != .validation { Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 2, height: 44) }
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(step.title).font(.system(size: 12, weight: .semibold))
                                    Spacer()
                                    Text(status.rawValue).font(.system(size: 9)).padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(status.color.opacity(0.14)).foregroundColor(status.color).cornerRadius(5)
                                }
                                Text(step.subtitle).font(.system(size: 10)).foregroundColor(.secondary)
                                if let detail = state.deploymentDetails[step] {
                                    Text(detail).font(.system(size: 10)).foregroundColor(status.color).textSelection(.enabled)
                                }
                            }.padding(.bottom, 12)
                        }
                    }
                }.padding(4)
            }
            Text(state.statusMessage).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button("查看日志") {
                    NSWorkspace.shared.open(WineService.shared.logDirectory(state.bottlePath.path))
                }
                Spacer()
                if !state.isOperating {
                    Button("返回配置") { state.showDeploymentProgress = false; state.isInstalled = false }
                    if state.hasInstalledExecutable {
                        Button("进入控制台") { state.showDeploymentProgress = false; state.isInstalled = true }
                            .buttonStyle(.borderedProminent).tint(.purple)
                    }
                }
            }
        }
    }
}
