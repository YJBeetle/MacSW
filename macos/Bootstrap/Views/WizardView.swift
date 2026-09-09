import SwiftUI
import AppKit

struct WizardView: View {
    @ObservedObject var state: AppState
    @State private var isTargeted: Bool = false
    @State private var isProcessing: Bool = false
    @State private var statusText: String = "请提供 SolidWorks 安装介质以开始部署"

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "cube.transparent.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 56, height: 56)
                    .foregroundColor(.accentColor)
                Text("欢迎使用 MacSW 部署向导")
                    .font(.system(size: 20, weight: .bold))
                Text("遵循开源版权规范，本软件不包含任何专有二进制。请在下方提供你的安装介质。")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            Divider()

            // Step 1: ISO Selection
            VStack(alignment: .leading, spacing: 8) {
                Text("步骤 1：SolidWorks 安装介质 (ISO 或解压目录)")
                    .font(.system(size: 13, weight: .semibold))

                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isTargeted ? Color.accentColor : Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .background(isTargeted ? Color.accentColor.opacity(0.05) : Color.clear)

                    HStack {
                        Image(systemName: state.selectedIsoPath == nil ? "opticaldisc" : "checkmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(state.selectedIsoPath == nil ? .secondary : .green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.selectedIsoPath?.lastPathComponent ?? "拖拽 .iso 镜像文件至此，或点击选择")
                                .font(.system(size: 13, weight: .medium))
                            if let path = state.selectedIsoPath?.path {
                                Text(path)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Button("浏览...") {
                            chooseIso()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .frame(height: 72)
                .onDrop(of: ["public.file-url"], isTargeted: $isTargeted) { providers in
                    if let item = providers.first {
                        item.loadItem(forTypeIdentifier: "public.file-url", options: nil) { (urlData, error) in
                            if let data = urlData as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                                DispatchQueue.main.async {
                                    self.state.selectedIsoPath = url
                                }
                            }
                        }
                        return true
                    }
                    return false
                }
            }

            // Step 2: License Server Folder
            VStack(alignment: .leading, spacing: 8) {
                Text("步骤 2：许可服务 (可选，指定本地 SolidWorks_Flexnet_Server 目录)")
                    .font(.system(size: 13, weight: .semibold))

                HStack {
                    Image(systemName: state.selectedLicenseDir == nil ? "folder" : "folder.fill.badge.gearshape")
                        .font(.system(size: 20))
                        .foregroundColor(state.selectedLicenseDir == nil ? .secondary : .accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.selectedLicenseDir?.lastPathComponent ?? "未选择（将默认使用网络 127.0.0.1 许可）")
                            .font(.system(size: 12))
                        if let path = state.selectedLicenseDir?.path {
                            Text(path)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Button("选择文件夹...") {
                        chooseLicenseDir()
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
            }

            Spacer()

            // Status & Start Button
            HStack {
                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: startInstallation) {
                    if isProcessing {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Text("一键开始部署")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.selectedIsoPath == nil || isProcessing)
            }
        }
        .padding(24)
        .frame(width: 520, height: 460)
    }

    private func chooseIso() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.diskImage]
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            self.state.selectedIsoPath = panel.url
        }
    }

    private func chooseLicenseDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            self.state.selectedLicenseDir = panel.url
        }
    }

    private func startInstallation() {
        guard let iso = state.selectedIsoPath else { return }
        isProcessing = true
        statusText = "正在挂载并检测安装介质..."

        DispatchQueue.global(qos: .userInitiated).async {
            var setupExe: String? = nil
            if iso.pathExtension.lowercased() == "iso" {
                if let mountPoint = IsoService.shared.mountIso(at: iso) {
                    self.state.mountedVolumePath = mountPoint
                    setupExe = IsoService.shared.findSetupExe(in: mountPoint)
                }
            } else {
                setupExe = IsoService.shared.findSetupExe(in: iso.path)
            }

            guard let exe = setupExe else {
                DispatchQueue.main.async {
                    self.statusText = "错误：在所选介质中未找到 setup.exe 安装程序！"
                    self.isProcessing = false
                }
                return
            }

            DispatchQueue.main.async {
                self.statusText = "已找到安装程序，正在唤起 Wine 环境..."
            }

            let winePrefix = self.state.bottlePath.path
            WineService.shared.launchInstaller(setupExe: exe, winePrefix: winePrefix) {
                self.isProcessing = false
                self.state.checkInstallation()
                self.statusText = "安装向导已退出。"
            }
        }
    }
}
