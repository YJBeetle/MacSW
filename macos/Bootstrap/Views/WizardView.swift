import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct WizardView: View {
    @ObservedObject var state: AppState
    @State private var isProcessing: Bool = false
    @State private var isInstallerRunning: Bool = false
    @State private var cleanDeployment: Bool = false
    @State private var showCleanTips: Bool = false
    @State private var statusText: String = "请提供 SolidWorks 安装介质以开始部署"

    var body: some View {
        VStack(spacing: 14) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "cube.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 38, height: 38)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MacSW 部署与配置向导")
                        .font(.system(size: 17, weight: .bold))
                    Text("请提供 SolidWorks 安装介质，并可按需提供注册表与补丁组件。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()

                if state.hasInstalledExecutable {
                    Button("返回控制台") {
                        state.isInstalled = true
                    }
                    .font(.system(size: 11))
                }
            }

            Divider()

            // 1. 顶部最大、居中突出的必要安装介质卡片 (Hero Card)
            HeroMediaCard(
                selectedUrl: state.selectedIsoPath,
                onSelectUrl: { url in
                    state.selectedIsoPath = url
                    state.autoDetectCompanionFiles(from: url)
                },
                onClear: {
                    state.selectedIsoPath = nil
                }
            )

            // 2. 下方横向排列的三个可选卡片
            HStack(spacing: 10) {
                // 可选 1: 预载网络注册表
                CompactDropCard(
                    title: "网络注册表",
                    badge: "可选",
                    placeholder: "拖拽 .reg 文件\n(如 serials_licensing.reg)",
                    icon: "doc.badge.gearshape",
                    selectedUrl: state.selectedRegPath,
                    isFileOnly: true,
                    isFolderOnly: false,
                    allowedExtensions: ["reg"],
                    onSelectUrl: { url in
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                            return
                        }
                        if url.pathExtension.lowercased() == "reg" {
                            state.selectedRegPath = url
                            state.autoDetectCompanionFiles(from: url)
                        }
                    },
                    onClear: {
                        state.selectedRegPath = nil
                    }
                )

                // 可选 2: FlexNet 许可服务
                CompactDropCard(
                    title: "许可服务",
                    badge: "可选",
                    placeholder: "拖拽 FlexNet Server\n服务根目录至此",
                    icon: "server.rack",
                    selectedUrl: state.selectedLicenseDir,
                    isFileOnly: false,
                    isFolderOnly: true,
                    allowedExtensions: nil,
                    onSelectUrl: { url in
                        state.selectedLicenseDir = url
                        state.autoDetectCompanionFiles(from: url)
                    },
                    onClear: {
                        state.selectedLicenseDir = nil
                    }
                )

                // 可选 3: 组件补丁
                CompactDropCard(
                    title: "组件补丁",
                    badge: "可选",
                    placeholder: "拖拽 SOLIDWORKS Corp\n补丁文件夹至此",
                    icon: "shippingbox.fill",
                    selectedUrl: state.selectedPatchDir,
                    isFileOnly: false,
                    isFolderOnly: true,
                    allowedExtensions: nil,
                    onSelectUrl: { url in
                        state.selectedPatchDir = url
                        state.autoDetectCompanionFiles(from: url)
                    },
                    onClear: {
                        state.selectedPatchDir = nil
                    }
                )
            }

            Spacer()

            // 3. 底部部署动作栏与状态显示
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    if isProcessing {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()

                HStack(spacing: 12) {
                    // 干净部署选项
                    HStack(spacing: 4) {
                        Toggle(isOn: $cleanDeployment) {
                            Text("干净部署")
                                .font(.system(size: 11))
                        }
                        .toggleStyle(.checkbox)
                        .disabled(isProcessing)

                        Button(action: { showCleanTips.toggle() }) {
                            Image(systemName: "questionmark.circle")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("查看干净部署说明")
                        .popover(isPresented: $showCleanTips, arrowEdge: .top) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 6) {
                                    Image(systemName: "sparkles")
                                        .foregroundColor(.accentColor)
                                    Text("什么是干净部署？")
                                        .font(.system(size: 12, weight: .bold))
                                }
                                Divider()
                                Text("勾选后，在点击「开始部署」时将：")
                                    .font(.system(size: 11, weight: .medium))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("• 终止所有挂起的 Wine 与安装后台进程")
                                    Text("• 彻底清理旧容器（清空 drive_c、虚拟注册表及残留配置）")
                                    Text("• 重新执行 wineboot 生成纯净的原生 Wine 运行环境")
                                }
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)

                                Text("提示：适用于安装出错需要推倒重来，或需要全新配置时。")
                                    .font(.system(size: 10))
                                    .foregroundColor(.orange)
                                    .padding(.top, 2)
                            }
                            .padding(14)
                            .frame(width: 280)
                        }
                    }

                    // 部署/启动操作按钮（固定尺寸与文字长度，绝不跑位）
                    if state.isInstalled && !cleanDeployment {
                        Button(action: {
                            WineService.shared.launchSolidWorks(
                                exePath: state.sldworksExePath.path,
                                winePrefix: state.bottlePath.path
                            )
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill")
                                Text("启动 SolidWorks")
                                    .fontWeight(.bold)
                            }
                            .frame(minWidth: 95)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .controlSize(.regular)
                    } else {
                        Button(action: startDeployment) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.right.circle.fill")
                                Text("开始部署")
                                    .fontWeight(.bold)
                            }
                            .frame(minWidth: 95)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(isProcessing || state.selectedIsoPath == nil)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // 执行顺序：① 预载注册表 -> ② 启动许可服务 -> ③ 官方安装程序 -> ④ 组件补丁
    private func startDeployment() {
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
                    self.statusText = "错误：未在所选介质中找到 setup.exe 安装向导！"
                    self.isProcessing = false
                }
                return
            }

            // 0. 先确保独立容器环境已就绪（支持干净部署模式）
            DispatchQueue.main.async {
                self.statusText = self.cleanDeployment ? "正在清理旧容器并重新初始化全新环境..." : "正在检查并准备 MacSW 独立环境..."
            }
            let initSema = DispatchSemaphore(value: 0)
            self.state.ensureBottleInitialized(forceClean: self.cleanDeployment) { _ in
                initSema.signal()
            }
            _ = initSema.wait(timeout: .now() + 60)

            // 1. 先“预载注册表”：如果指定了注册表文件或检测到补丁目录中的 reg，先预导入注册表
            DispatchQueue.main.async {
                self.statusText = "正在预置网络序列号注册表..."
            }
            let sema = DispatchSemaphore(value: 0)
            self.state.importNetworkSerials(interactive: false) { _ in
                sema.signal()
            }
            _ = sema.wait(timeout: .now() + 5)

            // 2. 然后“启动服务器”：如果指定了许可服务目录，在安装前先行启动，确保官方向导连通 25734
            if self.state.selectedLicenseDir != nil {
                DispatchQueue.main.async {
                    self.statusText = "正在启动本地 FlexNet 许可服务 (端口 25734)..."
                    self.state.startLicenseServer()
                }
                Thread.sleep(forTimeInterval: 2.0)
            }

            // 3. 然后“安装”：启动官方安装向导 setup.exe
            DispatchQueue.main.async {
                self.statusText = "SolidWorks 官方向导运行中..."
                self.isInstallerRunning = true
            }
            let winePrefix = self.state.bottlePath.path
            WineService.shared.launchInstaller(setupExe: exe, winePrefix: winePrefix) {
                DispatchQueue.main.async {
                    self.isInstallerRunning = false
                }
                // 4. 然后“补丁与运行库”：安装向导退出后，自动同步组件补丁并从安装介质抽取 WPF 主题库
                DispatchQueue.main.async {
                    self.statusText = "正在从介质提取 WPF 官方主题库并同步组件补丁..."
                }

                if let patchDir = self.state.selectedPatchDir {
                    self.state.applyComponentPatch(customPatchDir: patchDir) { ok in
                        DispatchQueue.main.async {
                            self.isProcessing = false
                            self.state.checkInstallation()
                            if self.state.isInstalled {
                                self.statusText = ok ? "✅ 部署已全部完成，补丁与 WPF 主题库已就绪！" : "⚠️ 部署完成，但补丁同步存在警告，请在控制台检查。"
                            } else {
                                self.statusText = "安装向导已退出。若已完成安装，请点击右上角【进入控制台】。"
                            }
                        }
                    }
                } else {
                    // 若用户未指定补丁文件夹，仍然抽取 WPF 主题库，但给出明确未破解警告
                    self.state.extractAndInjectWpfThemes { _ in
                        DispatchQueue.main.async {
                            self.isProcessing = false
                            self.state.checkInstallation()
                            self.statusText = "⚠️ 安装向导已退出。注意：因未指定补丁文件夹，已略过补丁！请在控制台手动指定并应用补丁。"
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 顶部突出显示的必要安装介质卡片 (Hero Card)
struct HeroMediaCard: View {
    let selectedUrl: URL?
    let onSelectUrl: (URL) -> Void
    var onClear: (() -> Void)? = nil

    @State private var isTargeted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SolidWorks 安装介质")
                    .font(.system(size: 13, weight: .bold))
                Text("必要")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.15))
                    .foregroundColor(.red)
                    .cornerRadius(4)

                Spacer()

                if selectedUrl != nil {
                    Label("已就绪", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.green)
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isTargeted ? Color.accentColor : (selectedUrl != nil ? Color.green.opacity(0.5) : Color.accentColor.opacity(0.35)),
                        style: StrokeStyle(lineWidth: isTargeted ? 2.5 : (selectedUrl != nil ? 1.5 : 1.2), dash: [6, 4])
                    )
                    .background(isTargeted ? Color.accentColor.opacity(0.08) : (selectedUrl != nil ? Color.green.opacity(0.03) : Color.secondary.opacity(0.03)))

                if let url = selectedUrl {
                    HStack(spacing: 16) {
                        Image(systemName: "opticaldisc.fill")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 44, height: 44)
                            .foregroundColor(.green)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(url.lastPathComponent)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            Text(url.path)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }

                        Spacer()

                        HStack(spacing: 8) {
                            Button("更换...") {
                                chooseMedia()
                            }
                            .controlSize(.small)
                            .font(.system(size: 11))

                            if let onClear = onClear {
                                Button("清除") {
                                    onClear()
                                }
                                .controlSize(.small)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "opticaldisc")
                            .font(.system(size: 34))
                            .foregroundColor(.accentColor.opacity(0.85))

                        Text("拖拽 SolidWorks 安装介质 (.iso 镜像或解压目录) 至此")
                            .font(.system(size: 12, weight: .medium))

                        Text("支持官方原版 ISO 镜像，或已提取 setup.exe 的安装文件夹")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)

                        Button("选择文件或目录...") {
                            chooseMedia()
                        }
                        .controlSize(.small)
                        .font(.system(size: 11))
                        .padding(.top, 2)
                    }
                    .padding(.vertical, 14)
                }
            }
            .frame(height: 128)
            .onDrop(of: ["public.file-url"], isTargeted: $isTargeted) { providers in
                if let item = providers.first {
                    item.loadItem(forTypeIdentifier: "public.file-url", options: nil) { (urlData, error) in
                        if let data = urlData as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                            DispatchQueue.main.async {
                                onSelectUrl(url)
                            }
                        }
                    }
                    return true
                }
                return false
            }
        }
    }

    private func chooseMedia() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "请选择 SolidWorks 安装 ISO 镜像或解压目录"
        if panel.runModal() == .OK, let url = panel.url {
            onSelectUrl(url)
        }
    }
}

// MARK: - 底部并排紧凑卡片 (Compact Drop Card)
struct CompactDropCard: View {
    let title: String
    let badge: String
    let placeholder: String
    let icon: String
    let selectedUrl: URL?
    let isFileOnly: Bool
    let isFolderOnly: Bool
    let allowedExtensions: [String]?
    let onSelectUrl: (URL) -> Void
    var onClear: (() -> Void)? = nil

    @State private var isTargeted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(badge)
                    .font(.system(size: 9))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12))
                    .foregroundColor(.secondary)
                    .cornerRadius(3)
            }

            // Body Area
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isTargeted ? Color.accentColor : (selectedUrl != nil ? Color.green.opacity(0.4) : Color.secondary.opacity(0.2)),
                        style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [4, 3])
                    )
                    .background(isTargeted ? Color.accentColor.opacity(0.06) : (selectedUrl != nil ? Color.green.opacity(0.02) : Color.secondary.opacity(0.02)))

                VStack(spacing: 5) {
                    Image(systemName: selectedUrl != nil ? "checkmark.circle.fill" : icon)
                        .font(.system(size: 20))
                        .foregroundColor(selectedUrl != nil ? .green : .secondary)

                    if let url = selectedUrl {
                        Text(url.lastPathComponent)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("已就绪")
                            .font(.system(size: 9))
                            .foregroundColor(.green)

                        HStack(spacing: 6) {
                            Button("更换...") {
                                chooseFileOrFolder()
                            }
                            .controlSize(.mini)
                            .font(.system(size: 10))

                            if let onClear = onClear {
                                Button("清除") {
                                    onClear()
                                }
                                .controlSize(.mini)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            }
                        }
                    } else {
                        Text(placeholder)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)

                        Button("选择...") {
                            chooseFileOrFolder()
                        }
                        .controlSize(.mini)
                        .font(.system(size: 10))
                    }
                }
                .padding(8)
            }
            .frame(height: 104)
            .onDrop(of: ["public.file-url"], isTargeted: $isTargeted) { providers in
                if let item = providers.first {
                    item.loadItem(forTypeIdentifier: "public.file-url", options: nil) { (urlData, error) in
                        if let data = urlData as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                            if isFileOnly {
                                var isDir: ObjCBool = false
                                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                                    return
                                }
                            }
                            if isFolderOnly {
                                var isDir: ObjCBool = false
                                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                                    return
                                }
                            }
                            DispatchQueue.main.async {
                                onSelectUrl(url)
                            }
                        }
                    }
                    return true
                }
                return false
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func chooseFileOrFolder() {
        let panel = NSOpenPanel()
        if isFolderOnly {
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
        } else if isFileOnly {
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            if let exts = allowedExtensions, !exts.isEmpty {
                panel.allowedContentTypes = exts.compactMap { UTType(filenameExtension: $0) }
            }
        } else {
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
        }
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            onSelectUrl(url)
        }
    }
}
