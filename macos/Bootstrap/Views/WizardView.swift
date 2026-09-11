import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Official installation owns component, language and destination selection.
struct WizardView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("安装 SOLIDWORKS").font(.title2).bold()
            Text("使用官方安装器。App 负责 Wine 初始化、VC++ 前置安装与 WPF 主题库补齐。")
                .foregroundColor(.secondary)
            GroupBox("安装介质") {
                HStack {
                    Text(state.selectedIsoPath?.path ?? "拖入官方 ISO 或安装介质目录，也可点击选择")
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    Button("选择…") {
                        choose(files: true, directories: true) { url in
                            select(url, for: .media)
                        }
                    }
                }.padding(8)
            }
            .modifier(FileDropArea { select($0, for: .media) })
            GroupBox("可选的安装配置") {
                VStack(alignment: .leading, spacing: 10) {
                    resourceRow("序列号注册表", path: state.selectedRegPath, kind: .registry) {
                        choose(files: true, directories: false) { url in
                            select(url, for: .registry)
                        }
                    } clear: { state.selectedRegPath = nil }
                    resourceRow("许可服务目录", path: state.selectedLicenseDir, kind: .license) {
                        choose(files: false, directories: true) { select($0, for: .license) }
                    } clear: { state.selectedLicenseDir = nil }
                    resourceRow("组件补丁目录", path: state.selectedPatchDir, kind: .patch) {
                        choose(files: false, directories: true) { select($0, for: .patch) }
                    } clear: { state.selectedPatchDir = nil }
                    Text("序列号注册表（.reg）会在每次安装前导入，用于预填安装序列号。许可与组件维护仍由控制台显式操作。")
                        .font(.caption).foregroundColor(.secondary)
                }.padding(8)
            }
            Text("安装采用 DISABLEROLLBACK=1：晚期自定义动作失败时保留文件，但不会把失败标记为完整安装成功。")
                .font(.caption).foregroundColor(.secondary)
            if state.isOperating { ProgressView().controlSize(.small) }
            Text(state.statusMessage).font(.callout).textSelection(.enabled)
            Spacer()
            HStack {
                Button("查看日志") {
                    let url = WineService.shared.logDirectory(state.bottlePath.path)
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(url)
                }
                Spacer()
                if state.hasInstalledExecutable {
                    Button("返回控制台") { state.isInstalled = true }
                }
                Button("启动官方安装器") { state.launchSetupExe() }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.selectedIsoPath == nil || state.isSolidWorksRunning)
            }
            Text("容器：\(state.bottlePath.path)").font(.caption2).foregroundColor(.secondary).textSelection(.enabled)
        }
        .padding(22)
        .disabled(state.isOperating)
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
            UserDefaults.standard.set(url.path, forKey: "installationMedia")
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

    private func resourceRow(_ title: String, path: URL?, kind: ResourceKind, select: @escaping () -> Void, clear: @escaping () -> Void) -> some View {
        HStack {
            Text(title).frame(width: 100, alignment: .leading)
            Text(path?.lastPathComponent ?? (kind == .registry ? "拖入序列号 .reg 文件…" : "拖入目录或选择…")).lineLimit(1).foregroundColor(.secondary)
            Spacer()
            Button("选择…", action: select)
            if path != nil { Button("清除", action: clear) }
        }
        .padding(6)
        .modifier(FileDropArea { self.select($0, for: kind) })
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
    @Environment(\.isEnabled) private var isEnabled
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(isTargeted && isEnabled ? Color.accentColor.opacity(0.12) : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(isTargeted && isEnabled ? Color.accentColor : Color.clear, lineWidth: 2)
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
