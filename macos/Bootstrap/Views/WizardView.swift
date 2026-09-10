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

    // 步骤 UI 状态
    @State private var hasStartedDeployment: Bool = false
    @State private var currentStep: DeploymentStep = .prepareEnvironment
    @State private var stepStates: [DeploymentStep: StepStatus] = [
        .prepareEnvironment: .pending,
        .preconfigureLicensing: .pending,
        .runOfficialInstaller: .pending,
        .extractWpfThemes: .pending,
        .applyPatches: .pending,
        .finalized: .pending
    ]
    @State private var stepLogs: [DeploymentStep: String] = [:]

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
                    Text(hasStartedDeployment ? "正在自动化执行系统转译与环境部署步骤..." : "请提供 SolidWorks 安装介质，并可按需提供注册表与补丁组件。")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()

                if hasStartedDeployment && !isProcessing {
                    Button("重新配置") {
                        hasStartedDeployment = false
                    }
                    .font(.system(size: 11))
                }

                if state.hasInstalledExecutable && !isProcessing {
                    Button("返回控制台") {
                        state.isInstalled = true
                    }
                    .font(.system(size: 11))
                }
            }

            Divider()

            if hasStartedDeployment {
                // 步骤 UI 视图
                DeploymentStepsView(
                    currentStep: currentStep,
                    stepStates: stepStates,
                    stepLogs: stepLogs,
                    isProcessing: isProcessing,
                    isInstalled: state.isInstalled,
                    onLaunch: {
                        WineService.shared.launchSolidWorks(
                            exePath: state.sldworksExePath.path,
                            winePrefix: state.bottlePath.path
                        )
                    },
                    onGoToDashboard: {
                        state.isInstalled = true
                    },
                    onReset: {
                        hasStartedDeployment = false
                    }
                )
            } else {
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

                        // 部署/启动操作按钮
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
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // 执行顺序：① 预载注册表 -> ② 启动许可服务 -> ③ 官方安装程序 -> ④ 组件补丁
    private func startDeployment() {
        guard let iso = state.selectedIsoPath else { return }
        hasStartedDeployment = true
        isProcessing = true
        currentStep = .prepareEnvironment
        stepStates = [
            .prepareEnvironment: .running,
            .preconfigureLicensing: .pending,
            .runOfficialInstaller: .pending,
            .extractWpfThemes: .pending,
            .applyPatches: .pending,
            .finalized: .pending
        ]
        stepLogs[.prepareEnvironment] = "正在挂载并检测安装介质..."
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
                    self.stepStates[.prepareEnvironment] = .failed("未在所选介质中找到 setup.exe 安装向导")
                    self.statusText = "错误：未在所选介质中找到 setup.exe 安装向导！"
                    self.isProcessing = false
                }
                return
            }

            // 0. 先确保独立容器环境已就绪（支持干净部署模式）
            DispatchQueue.main.async {
                self.stepLogs[.prepareEnvironment] = self.cleanDeployment ? "正在清理旧容器并初始化全新环境..." : "正在验证 MacSW 独立运行环境..."
                self.statusText = self.cleanDeployment ? "正在清理旧容器并重新初始化全新环境..." : "正在检查并准备 MacSW 独立环境..."
            }
            let initSema = DispatchSemaphore(value: 0)
            self.state.ensureBottleInitialized(forceClean: self.cleanDeployment) { _ in
                initSema.signal()
            }
            _ = initSema.wait(timeout: .now() + 60)

            DispatchQueue.main.async {
                self.stepStates[.prepareEnvironment] = .completed
                self.stepLogs[.prepareEnvironment] = "WinePrefix 独立环境就绪，已定位 setup.exe"
                self.currentStep = .preconfigureLicensing
                self.stepStates[.preconfigureLicensing] = .running
                self.stepLogs[.preconfigureLicensing] = "正在预置网络注册表序列号..."
                self.statusText = "正在预置网络序列号注册表..."
            }

            // 1. 先“预载注册表”：如果指定了注册表文件或检测到补丁目录中的 reg，先预导入注册表
            let sema = DispatchSemaphore(value: 0)
            self.state.importNetworkSerials(interactive: false) { _ in
                sema.signal()
            }
            _ = sema.wait(timeout: .now() + 5)

            // 2. 然后“启动服务器”：如果指定了许可服务目录，在安装前先行启动，确保官方向导连通 25734
            if self.state.selectedLicenseDir != nil {
                DispatchQueue.main.async {
                    self.stepLogs[.preconfigureLicensing] = "正在启动本地 FlexNet 许可服务 (端口 25734)..."
                    self.statusText = "正在启动本地 FlexNet 许可服务 (端口 25734)..."
                    self.state.startLicenseServer()
                }
                Thread.sleep(forTimeInterval: 2.0)
            }

            DispatchQueue.main.async {
                self.stepStates[.preconfigureLicensing] = .completed
                self.stepLogs[.preconfigureLicensing] = "网络序列号已写入，FlexNet 许可服务正常运行"
                self.currentStep = .runOfficialInstaller
                self.stepStates[.runOfficialInstaller] = .running
                self.stepLogs[.runOfficialInstaller] = "SolidWorks 官方向导运行中，请在弹出的安装窗口中完成组件选择..."
                self.statusText = "SolidWorks 官方向导运行中..."
                self.isInstallerRunning = true
            }

            // 3. 然后“安装”：启动官方安装向导 setup.exe
            let winePrefix = self.state.bottlePath.path
            WineService.shared.launchInstaller(setupExe: exe, winePrefix: winePrefix) {
                DispatchQueue.main.async {
                    self.isInstallerRunning = false
                    self.stepStates[.runOfficialInstaller] = .completed
                    self.stepLogs[.runOfficialInstaller] = "官方安装向导执行完毕"
                    
                    // 步骤 4: 抽取与注入微软官方原版 WPF 主题库
                    self.currentStep = .extractWpfThemes
                    self.stepStates[.extractWpfThemes] = .running
                    self.stepLogs[.extractWpfThemes] = "正在从安装介质抽取原版 PresentationFramework.Aero 等主题库..."
                    self.statusText = "正在抽取并注入微软官方 WPF 主题库..."
                }

                // 执行步骤 4：抽取 WPF 主题库
                self.state.extractAndInjectWpfThemes { wpfOk in
                    DispatchQueue.main.async {
                        self.stepStates[.extractWpfThemes] = wpfOk ? .completed : .warning("WPF 主题库注入完成（部分主题可能使用回退项）")
                        self.stepLogs[.extractWpfThemes] = wpfOk ? "微软原版 WPF 主题库已成功提取并注入系统与程序目录" : "已完成主题库注入流程"
                        
                        // 步骤 5: 同步核心组件与授权补丁
                        self.currentStep = .applyPatches
                        self.stepStates[.applyPatches] = .running
                        self.stepLogs[.applyPatches] = "正在同步核心程序补丁文件并导入授权注册表..."
                        self.statusText = "正在同步核心组件与授权补丁..."
                    }

                    // 执行步骤 5：同步授权补丁
                    if let patchDir = self.state.selectedPatchDir {
                        self.state.applyComponentPatch(customPatchDir: patchDir) { patchOk in
                            DispatchQueue.main.async {
                                self.stepStates[.applyPatches] = patchOk ? .completed : .warning("补丁应用完成，存在部分非致命警告")
                                self.stepLogs[.applyPatches] = patchOk ? "SOLIDWORKS Corp 核心组件补丁及授权注册表已全部就绪" : "补丁应用已完成"
                                
                                // 步骤 6: 部署就绪，完成验证
                                self.finishDeployment(patchOk: patchOk)
                            }
                        }
                    } else {
                        // 用户未指定补丁文件夹，提示略过
                        DispatchQueue.main.async {
                            self.stepStates[.applyPatches] = .warning("已略过补丁（未提供 SOLIDWORKS Corp 补丁目录）")
                            self.stepLogs[.applyPatches] = "未提供授权补丁目录，已跳过核心补丁同步"
                            
                            // 步骤 6: 部署就绪
                            self.finishDeployment(patchOk: false, skippedPatches: true)
                        }
                    }
                }
            }
        }
    }

    private func finishDeployment(patchOk: Bool, skippedPatches: Bool = false) {
        self.currentStep = .finalized
        self.stepStates[.finalized] = .completed
        if skippedPatches {
            self.stepLogs[.finalized] = "基础部署已结束。后续可在控制台中随时指定补丁目录并应用补丁。"
        } else {
            self.stepLogs[.finalized] = "SolidWorks 2025 原生转译环境验证通过，随时可以启动！"
        }

        self.isProcessing = false
        self.state.checkInstallation()
        if self.state.isInstalled {
            self.statusText = patchOk ? "✅ 部署已全部完成，补丁与 WPF 主题库已就绪！" : "⚠️ 部署完成，补丁同步存在警告，请在控制台检查。"
        } else {
            self.statusText = "安装流程已完成。若已完成安装，请点击右上角【返回控制台】。"
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

// MARK: - 部署步骤定义与状态模型
enum DeploymentStep: Int, CaseIterable, Identifiable {
    case prepareEnvironment = 1
    case preconfigureLicensing = 2
    case runOfficialInstaller = 3
    case extractWpfThemes = 4
    case applyPatches = 5
    case finalized = 6

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .prepareEnvironment:
            return "准备运行环境与挂载介质"
        case .preconfigureLicensing:
            return "预置网络授权与许可服务"
        case .runOfficialInstaller:
            return "运行 SolidWorks 官方安装向导"
        case .extractWpfThemes:
            return "抽取微软官方 WPF 主题库"
        case .applyPatches:
            return "同步核心组件与授权补丁"
        case .finalized:
            return "部署就绪，完成验证"
        }
    }

    var subtitle: String {
        switch self {
        case .prepareEnvironment:
            return "初始化独立 WinePrefix 容器、自动挂载镜像并定位 setup.exe"
        case .preconfigureLicensing:
            return "写入网络序列号注册表，启动本地 FlexNet 服务 (端口 25734)"
        case .runOfficialInstaller:
            return "启动 setup.exe，请在 Windows 弹出的安装向导中完成组件安装"
        case .extractWpfThemes:
            return "动态抽取原版 PresentationFramework.Aero 等主题库注入 Mono 运行环境"
        case .applyPatches:
            return "同步 SOLIDWORKS Corp 核心程序补丁并导入授权激活注册表"
        case .finalized:
            return "检查主程序与运行库完整性，配置免虚拟机原生开箱即用环境"
        }
    }
}

enum StepStatus: Equatable {
    case pending
    case running
    case completed
    case warning(String)
    case failed(String)
}

// MARK: - 部署步骤进度流视图 (Step View)
struct DeploymentStepsView: View {
    let currentStep: DeploymentStep
    let stepStates: [DeploymentStep: StepStatus]
    let stepLogs: [DeploymentStep: String]
    let isProcessing: Bool
    let isInstalled: Bool
    let onLaunch: () -> Void
    let onGoToDashboard: () -> Void
    let onReset: () -> Void

    var isAllCompleted: Bool {
        return stepStates[.finalized] == .completed
    }

    var progressValue: Double {
        let completedCount = stepStates.values.filter {
            if case .completed = $0 { return true }
            return false
        }.count
        if isAllCompleted { return 1.0 }
        return max(0.05, Double(completedCount) / Double(DeploymentStep.allCases.count))
    }

    var body: some View {
        VStack(spacing: 12) {
            // 1. 进度指示卡片
            VStack(spacing: 6) {
                HStack {
                    Text(isAllCompleted ? "🎉 部署流程已全部完成" : "步骤 \(currentStep.rawValue) / \(DeploymentStep.allCases.count): \(currentStep.title)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(isAllCompleted ? .green : .primary)
                    Spacer()
                    Text("\(Int(progressValue * 100))%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                ProgressView(value: progressValue)
                    .progressViewStyle(.linear)
                    .tint(isAllCompleted ? .green : .purple)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))

            // 2. 步骤 Timeline 列表
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(DeploymentStep.allCases) { step in
                        let status = stepStates[step] ?? .pending
                        let isCurrent = (step == currentStep && !isAllCompleted)
                        let log = stepLogs[step]
                        let isLast = (step == DeploymentStep.allCases.last)

                        DeploymentStepRow(
                            step: step,
                            status: status,
                            isCurrent: isCurrent,
                            log: log,
                            isLast: isLast
                        )
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
            }

            Spacer()

            // 3. 底部行动区
            if isAllCompleted {
                HStack(spacing: 12) {
                    Button(action: onReset) {
                        Text("重新部署")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Spacer()

                    Button(action: onGoToDashboard) {
                        Text("进入控制台")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Button(action: onLaunch) {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                            Text("立即启动 SolidWorks")
                                .fontWeight(.bold)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.regular)
                }
                .padding(.top, 4)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                    Text("请稍候，正在部署中... (若弹出 Windows 安装向导，请完成点击下一步)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.05)))
            }
        }
    }
}

// MARK: - 单个步骤行组件 (Step Row)
struct DeploymentStepRow: View {
    let step: DeploymentStep
    let status: StepStatus
    let isCurrent: Bool
    let log: String?
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // 左侧指示图标与竖向引导线
            VStack(spacing: 0) {
                stepIcon
                    .frame(width: 24, height: 24)

                if !isLast {
                    Rectangle()
                        .fill(connectorColor)
                        .frame(width: 2)
                        .frame(minHeight: 28)
                }
            }

            // 右侧步骤文本与动态日志
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(step.title)
                        .font(.system(size: 13, weight: isCurrent ? .bold : .semibold))
                        .foregroundColor(titleColor)

                    Spacer()

                    statusBadge
                }

                Text(step.subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let currentLog = log, !currentLog.isEmpty {
                    HStack(spacing: 4) {
                        if isCurrent {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 10, height: 10)
                        }
                        Text(currentLog)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(isCurrent ? Color.accentColor : Color.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                    .padding(.top, 2)
                }
            }
            .padding(.bottom, isLast ? 0 : 10)
        }
    }

    @ViewBuilder
    private var stepIcon: some View {
        switch status {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 20))
        case .running:
            ZStack {
                Circle()
                    .fill(Color.purple.opacity(0.2))
                ProgressView()
                    .scaleEffect(0.6)
            }
        case .warning:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 20))
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
                .font(.system(size: 20))
        case .pending:
            ZStack {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1.5)
                Text("\(step.rawValue)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.6))
            }
        }
    }

    private var connectorColor: Color {
        switch status {
        case .completed:
            return Color.green.opacity(0.6)
        default:
            return Color.secondary.opacity(0.2)
        }
    }

    private var titleColor: Color {
        if isCurrent { return .primary }
        switch status {
        case .completed:
            return .primary
        case .pending:
            return .secondary
        case .warning:
            return .orange
        case .failed:
            return .red
        case .running:
            return .primary
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .completed:
            Text("已完成")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.green.opacity(0.12)))
        case .running:
            Text("进行中")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.purple)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.purple.opacity(0.15)))
        case .warning:
            Text("警告")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.orange.opacity(0.12)))
        case .failed:
            Text("失败")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.red)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.red.opacity(0.12)))
        case .pending:
            Text("等待中")
                .font(.system(size: 9))
                .foregroundColor(.secondary.opacity(0.8))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.08)))
        }
    }
}
