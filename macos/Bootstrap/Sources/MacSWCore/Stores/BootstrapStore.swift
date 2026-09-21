import Combine
import Foundation

public extension Notification.Name {
    static let macSWInstallationCompleted = Notification.Name("MacSWInstallationCompleted")
}

@MainActor
public final class BootstrapStore: ObservableObject {
    @Published public private(set) var selectedMedia: URL?
    @Published public private(set) var resolvedMedia: ResolvedMedia?
    @Published public var cleanInstall = false
    @Published public var silentInstall = true
    @Published public var serialSolidWorks = ""
    @Published public var serialSimulation = ""
    @Published public var serialMotion = ""
    @Published public var serialMBD = ""
    @Published public var selectedLanguage: SolidWorksLanguage?
    @Published public var licenseMode: BootstrapLicenseMode = .unconfigured
    @Published public var licenseServerAddress = ""
    @Published public var flexNetDirectory: URL?
    @Published public private(set) var flexNetCandidates: [URL] = []
    @Published public private(set) var flexNetCheck: FlexNetPackageCheck = .empty
    @Published public private(set) var availableLanguages: [SolidWorksLanguage] = []
    @Published public private(set) var serialSources: [InstallSerialField: URL] = [:]
    @Published public private(set) var ambiguousSerialFields: [InstallSerialField] = []
    @Published public private(set) var isInspectingMedia = false
    @Published public private(set) var state: InstallationState = .idle
    @Published public private(set) var stepStatuses: [InstallationStep: InstallationStepStatus] = [:]
    @Published public private(set) var stepDetails: [InstallationStep: String] = [:]
    @Published public private(set) var statusMessage = "选择官方安装介质后即可开始。"

    public let paths: AppPaths
    private let wine: WineService
    private let prerequisites: PrerequisiteService
    private let registry: RegistryService
    private let iso: IsoService
    private let licensing: LicenseServerStore
    private var installationTask: Task<Void, Never>?
    private var inspectionTask: Task<Void, Never>?
    private var flexNetCheckTask: Task<Void, Never>?

    public init(
        paths: AppPaths,
        wine: WineService = .shared,
        prerequisites: PrerequisiteService = .shared,
        registry: RegistryService? = nil,
        iso: IsoService = .shared,
        licensing: LicenseServerStore? = nil
    ) {
        self.paths = paths
        self.wine = wine
        self.prerequisites = prerequisites
        self.registry = registry ?? RegistryService(wine: wine)
        self.iso = iso
        self.licensing = licensing ?? LicenseServerStore(paths: paths)
    }

    public var serials: InstallSerials {
        get {
            InstallSerials(values: [
                .solidWorks: serialSolidWorks,
                .simulation: serialSimulation,
                .motion: serialMotion,
                .mbd: serialMBD
            ])
        }
        set {
            serialSolidWorks = newValue[.solidWorks]
            serialSimulation = newValue[.simulation]
            serialMotion = newValue[.motion]
            serialMBD = newValue[.mbd]
        }
    }

    public var canStart: Bool {
        resolvedMedia != nil
            && !state.isActive
            && !isInspectingMedia
            && serialsReady
            && licenseRequest != nil
    }

    public var startHint: String? {
        let invalid = serials.invalidFields()
        if silentInstall, !invalid.isEmpty { return "\(invalid.map(\.title).joined(separator: "、")) 需要六组四字符。" }
        if silentInstall, !serials.isComplete { return "静默安装必须至少提供 SOLIDWORKS 序列号。" }
        return licenseMissingInput
    }

    /// 交互安装的序列号由官方向导询问，这里不参与校验。
    private var serialsReady: Bool {
        !silentInstall || (serials.isComplete && serials.invalidFields().isEmpty)
    }

    private var licenseMissingInput: String? {
        if let message = licenseMode.missingInputMessage(
            address: licenseServerAddress, flexNetSource: flexNetDirectory
        ) { return message }
        guard licenseMode == .managedFlexNet else { return nil }
        switch flexNetCheck {
        case .checking: return "正在校验 FlexNet 目录…"
        case .rejected(let reason): return reason
        default: return nil
        }
    }

    /// 选定 FlexNet 目录（自动识别或用户手选）后立即校验结构，不等开装才报错。
    public func chooseFlexNetDirectory(_ url: URL?) {
        flexNetDirectory = url
        validateFlexNetPackage()
    }

    private func validateFlexNetPackage() {
        flexNetCheckTask?.cancel()
        guard let url = flexNetDirectory else {
            flexNetCheck = .empty
            return
        }
        flexNetCheck = .checking
        let licensing = self.licensing
        flexNetCheckTask = Task { [weak self] in
            let check = await licensing.checkedPackage(at: url)
            guard let self, !Task.isCancelled, self.flexNetDirectory?.path == url.path else { return }
            self.flexNetCheck = check
        }
    }

    /// 单选解析出的唯一许可动作；nil 表示当前模式的输入还不可用。
    private var licenseRequest: LicenseRequest? {
        guard licenseMissingInput == nil else { return nil }
        switch licenseMode {
        case .unconfigured: return .skip
        case .remoteServer:
            return .address(licenseServerAddress.trimmingCharacters(in: .whitespacesAndNewlines))
        case .managedFlexNet:
            guard let flexNetDirectory else { return nil }
            return .managedFlexNet(flexNetDirectory)
        }
    }

    private enum LicenseRequest {
        case skip
        case address(String)
        case managedFlexNet(URL)
    }

    public var showsCleanInstall: Bool { paths.bottleExists }

    /// 只做纯目录判断与附属文件扫描：不挂载 ISO，也不起任何子进程。
    public func selectMedia(_ url: URL) {
        guard url.isFileURL else {
            statusMessage = "只能选择本机上的 ISO 文件、setup.exe 或目录。"
            return
        }
        guard let resolved = InstallationMediaResolver.resolve(url) else {
            resolvedMedia = nil
            selectedMedia = nil
            availableLanguages = []
            selectedLanguage = nil
            flexNetCandidates = []
            statusMessage = "找不到安装介质：请在其中提供 setup.exe 或 .iso（可在所选目录的一级子目录内）。"
            return
        }
        resolvedMedia = resolved
        selectedMedia = resolved.displayURL
        serialSources = [:]
        ambiguousSerialFields = []
        flexNetCandidates = []
        chooseFlexNetDirectory(nil)
        availableLanguages = LanguageCatalog.official
        if selectedLanguage == nil {
            selectedLanguage = LanguageCatalog.autoSelection(from: LanguageCatalog.official)
        }
        statusMessage = resolved.isIso
            ? "已识别 ISO 介质：\(resolved.displayURL.lastPathComponent)"
            : "已识别介质目录：\(resolved.displayURL.lastPathComponent)"
        inspectAttachments(in: resolved)
    }

    private func inspectAttachments(in media: ResolvedMedia) {
        inspectionTask?.cancel()
        isInspectingMedia = true
        let root = media.attachmentDirectory
        inspectionTask = Task { [weak self] in
            guard let self else { return }
            let result = await Task.detached {
                (
                    SerialDiscoveryService.discover(in: [root]),
                    FlexNetLocator.discover(in: root)
                )
            }.value
            guard !Task.isCancelled, self.resolvedMedia == media else { return }
            self.isInspectingMedia = false
            self.apply(discovery: result.0, flexNet: result.1)
        }
    }

    private func apply(discovery: SerialDiscoveryResult, flexNet: [URL]) {
        serials = serials.merging(discovery.serials)
        serialSources = discovery.sources
        ambiguousSerialFields = discovery.ambiguousFields

        var notes: [String] = []
        let sources = Set(discovery.sources.values.map(\.lastPathComponent)).sorted()
        let matched = InstallSerialField.allCases.filter { !discovery.serials[$0].isEmpty }
        if matched.isEmpty {
            notes.append("未在介质同级或子级文本中找到序列号，请手工填写")
        } else {
            notes.append("已通过 \(sources.joined(separator: "、")) 匹配序列号")
        }
        flexNetCandidates = flexNet
        let knownPackage = flexNetDirectory
        if knownPackage == nil, flexNet.count == 1 { flexNetDirectory = flexNet[0] }
        if knownPackage != flexNetDirectory { validateFlexNetPackage() }
        switch flexNet.count {
        case 0: break
        case 1:
            // 既然识别出来了就直接选中，用户之后手工改过别的模式则不再抢。
            if licenseMode == .unconfigured { licenseMode = .managedFlexNet }
            notes.append("已自动识别 FlexNet 目录并选中托管")
        default: notes.append("发现 \(flexNet.count) 个 FlexNet 目录，请在许可服务器里确认要托管的那个")
        }
        statusMessage = notes.joined(separator: "；") + "。"
    }

    public func start() {
        guard canStart else { return }
        installationTask = Task { await runInstallation() }
    }

    public func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        statusMessage = "正在停止本次安装…"
        installationTask?.cancel()
    }

    public func resetAfterFailure() {
        guard !state.isActive else { return }
        state = .idle
        stepStatuses = [:]
        stepDetails = [:]
        statusMessage = "可以调整选项后重新开始。"
    }

    public func cleanIncompleteInstallation() async throws {
        guard paths.bottle.standardizedFileURL == paths.appSupportDirectory.appendingPathComponent("bottle").standardizedFileURL else {
            throw bootstrapError("容器路径异常，拒绝清理。")
        }
        guard !state.isActive else { throw bootstrapError("安装仍在运行。") }
        guard try await wine.stopWineServerForCleanup(prefix: paths.bottle) else {
            throw bootstrapError("未能停止容器进程，已取消清理。")
        }
        if FileManager.default.fileExists(atPath: paths.bottle.path) {
            try FileManager.default.removeItem(at: paths.bottle)
        }
        try? FileManager.default.removeItem(at: installationReceipt)
        AppPaths.invalidateInstallationState()
        statusMessage = "不完整安装已清理。"
    }

    private func runInstallation() async {
        guard let selectedMedia, let resolved = resolvedMedia else { return }
        guard let license = licenseRequest else { return }
        let request = InstallRequest(
            serials: serials,
            language: selectedLanguage,
            silent: silentInstall,
            license: license
        )
        state = .preparing
        stepStatuses = [:]
        stepDetails = [:]
        report(.media, .running, "正在校验官方安装介质…")
        statusMessage = "正在校验安装介质…"
        var mountedByApp: MountedMedia?
        var desktopRedirections: [PrerequisiteService.DesktopRedirection] = []
        defer {
            if !desktopRedirections.isEmpty {
                try? prerequisites.restoreDesktopFolders(prefix: paths.bottle, to: desktopRedirections)
            }
            if let mountedByApp {
                let code = iso.unmount(mountedByApp)
                if code != 0 {
                    statusMessage += " 安装镜像未能自动弹出（\(code)），请在访达中推出“\(mountedByApp.mountPoint.lastPathComponent)”。"
                }
            }
            installationTask = nil
        }

        do {
            let media: URL
            switch resolved {
            case .iso(let url):
                let mounted = try await iso.mount(url)
                mountedByApp = mounted
                media = mounted.mountPoint
            case .directory(let url, _):
                media = url
            }
            try Task.checkCancellation()

            let missing = InstallationMedia.missingComponents(in: media, language: request.language)
            guard missing.isEmpty else {
                throw bootstrapError("介质缺少必需组件：\(missing.map(\.label).joined(separator: "、"))。")
            }
            report(.media, .completed, "官方 MSI、前置库与 Toolbox 齐备")
            let installerMSI = media.appendingPathComponent(SilentInstallerPlan.coreMSIRelativePath)

            if cleanInstall, paths.bottleExists {
                try validateInputsOutsideBottle([selectedMedia, media])
                guard try await wine.stopWineServerForCleanup(prefix: paths.bottle) else {
                    throw bootstrapError("未能停止容器进程，已取消全新安装。")
                }
                try FileManager.default.removeItem(at: paths.bottle)
                try? FileManager.default.removeItem(at: installationReceipt)
                AppPaths.invalidateInstallationState()
            }
            try Task.checkCancellation()

            state = .installing(.environment)
            report(.environment, .running, "正在准备 Wine 容器与托管 COM 运行时…")
            let wineboot = wine.makeProcess(arguments: ["wineboot", "-u"], prefix: paths.bottle)
            let bootCode = try await wine.runCancellable(
                wineboot,
                log: paths.logs.appendingPathComponent("wineboot.log")
            )
            guard bootCode == 0 else { throw bootstrapError("Wine 初始化失败（\(bootCode)）。") }
            try prerequisites.prepareShortNameAliases(prefix: paths.bottle)
            desktopRedirections = try prerequisites.redirectDesktopFolders(prefix: paths.bottle)
            try await prerequisites.configureMono(prefix: paths.bottle)
            try prerequisites.prepareManagedCOMRegistration(prefix: paths.bottle)
            try prerequisites.prepareManagedCOMDependencies(prefix: paths.bottle)
            try await wine.configureSolidWorksCompatibility(prefix: paths.bottle)
            report(.environment, .completed, "Mono、RegAsm、stdole 与输入兼容设置已就绪；桌面已临时改到容器内")

            state = .installing(.vcRuntime)
            report(.vcRuntime, .running, "正在静默安装官方 VC++ x64 运行库…")
            try await prerequisites.installVC(media: media, prefix: paths.bottle)
            report(.vcRuntime, .completed, "VC++ 运行库已校验")

            state = .installing(.loginManager)
            report(.loginManager, .running, "正在静默安装 SOLIDWORKS Login Manager…")
            try await prerequisites.installLoginManager(media: media, prefix: paths.bottle)
            let missingLoginManager = await registry.missingCOMRegistrations(
                at: "HKCR\\CLSID\\\(InstallerDiagnostics.loginManagerCLSID)\\InprocServer32",
                requires: InstallerDiagnostics.loginManagerRequirements,
                prefix: paths.bottle
            )
            guard missingLoginManager.isEmpty else {
                throw bootstrapError("Login Manager 托管 COM 注册缺少 \(missingLoginManager.joined(separator: "、"))。")
            }
            report(.loginManager, .completed, "托管 COM 注册已校验")

            state = .installing(.installer)
            let msiLog = paths.logs.appendingPathComponent("install_msi.log")
            let installerArguments: [String]
            if request.silent {
                report(.installer, .running, "正在静默部署 SOLIDWORKS 主体，请勿关闭本窗口…")
                installerArguments = SilentInstallerPlan.coreInstallArguments(
                    msi: installerMSI, log: msiLog, serials: request.serials
                )
            } else {
                // 组件选择与序列号都由官方向导接管，这里不预写任何注册表。
                report(.installer, .running, "官方安装窗口已打开，请在其中完成选择…")
                installerArguments = SilentInstallerPlan.interactiveInstallArguments(
                    msi: installerMSI, log: msiLog
                )
            }
            let installerCode = try await wine.runMSIExec(
                arguments: installerArguments,
                prefix: paths.bottle,
                log: paths.logs.appendingPathComponent("installer-wine.log")
            )
            if WineService.isCancelledInstallerStatus(installerCode) { throw CancellationError() }
            guard WineService.isSuccessfulInstallerStatus(installerCode) else {
                throw bootstrapError("SOLIDWORKS 静默安装失败（\(installerCode)）。\(msiFailureDetail(msiLog))")
            }
            if await wine.waitWineserver(prefix: paths.bottle, seconds: 30) {
                report(.installer, .completed, request.silent
                    ? "官方 MSI 已静默完成（退出码 \(installerCode)）"
                    : "官方安装向导已完成（退出码 \(installerCode)）")
            } else {
                guard try await wine.stopWineServerForCleanup(prefix: paths.bottle) else {
                    throw bootstrapError("安装器遗留进程未能停止，容器仍处于锁定状态。")
                }
                report(.installer, .completed, "官方 MSI 已完成，已收敛遗留的 Wine 辅助进程")
            }
            try Task.checkCancellation()

            AppPaths.invalidateInstallationState()
            guard paths.solidWorksInstalled else {
                throw bootstrapError("安装器已退出，但未找到 SOLIDWORKS 主程序。")
            }

            state = .installing(.language)
            if let language = request.language {
                report(.language, .running, "正在安装 \(language.displayName) 语言资源…")
                try await prerequisites.installLanguage(media: media, language: language, prefix: paths.bottle)
                report(.language, .completed, "\(language.displayName) 语言资源已就位")
            } else {
                report(.language, .skipped, "未选择语言资源，使用介质默认英文界面")
            }

            state = .installing(.wpfThemes)
            report(.wpfThemes, .running, "正在从微软安装包提取五个主题库…")
            try await prerequisites.installThemes(
                media: media,
                prefix: paths.bottle,
                target: paths.solidWorksExecutable.deletingLastPathComponent()
            )
            report(.wpfThemes, .completed, "五个 WPF 主题库已补齐")

            state = .installing(.licensing)
            switch request.license {
            case .skip:
                report(.licensing, .skipped, "按许可方式选择跳过")
            case .address(let address):
                report(.licensing, .running, "正在写入许可服务器地址…")
                try await licensing.configureDuringInstallation(address: address, flexNetSource: nil)
                report(.licensing, .completed, "许可服务器地址已写入容器")
            case .managedFlexNet(let source):
                report(.licensing, .running, "正在把 FlexNet 服务器装进容器…")
                try await licensing.configureDuringInstallation(address: "", flexNetSource: source)
                report(.licensing, .completed, "托管 FlexNet 已部署到 C:\\opt\\FlexNet 并启动")
            }

            state = .installing(.validation)
            report(.validation, .running, "正在验证主程序、COM 注册与主题库…")
            try await validateInstalledRuntime()
            try writeInstallationReceipt()
            report(.validation, .completed, "主程序、SldWorks.Application COM 注册与主题库校验通过")
            state = .completed
            statusMessage = "安装完成，MacSW 将切换到菜单栏并启动 SOLIDWORKS。"
            NotificationCenter.default.post(name: .macSWInstallationCompleted, object: nil)
        } catch is CancellationError {
            if let running = stepStatuses.first(where: { $0.value == .running })?.key {
                report(running, .cancelled, "用户终止了本次安装")
            }
            state = .cancelled
            statusMessage = "安装已中断；未写入完成标记。可以重新开始或清理不完整安装。"
        } catch {
            if let running = stepStatuses.first(where: { $0.value == .running })?.key {
                report(running, .failed, error.localizedDescription)
            }
            state = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    private struct InstallRequest {
        let serials: InstallSerials
        let language: SolidWorksLanguage?
        let silent: Bool
        let license: LicenseRequest
    }

    private func msiFailureDetail(_ log: URL) -> String {
        guard let data = try? Data(contentsOf: log), let text = PlainTextDecoder.decode(data) else {
            return " 请查看 \(log.path)。"
        }
        let summary = InstallerDiagnostics.msiErrorSummary(text)
        guard !summary.isEmpty else { return " 请查看 \(log.path)。" }
        let errors = paths.logs.appendingPathComponent("install_msi_errors.log")
        try? summary.joined(separator: "\n").data(using: .utf8)?.write(to: errors)
        return " 关键错误：\n\(summary.suffix(6).joined(separator: "\n"))\n完整摘要见 \(errors.path)。"
    }

    private func report(_ step: InstallationStep, _ status: InstallationStepStatus, _ detail: String) {
        stepStatuses[step] = status
        stepDetails[step] = detail
    }

    private func validateInstalledRuntime() async throws {
        guard paths.solidWorksInstalled else { throw bootstrapError("未找到 SOLIDWORKS 主程序。") }
        let target = paths.solidWorksExecutable.deletingLastPathComponent()
        for theme in PrerequisiteService.themes {
            guard FileManager.default.fileExists(atPath: target.appendingPathComponent("PresentationFramework.\(theme).dll").path) else {
                throw bootstrapError("缺少 WPF 主题库 PresentationFramework.\(theme).dll。")
            }
        }
        guard let clsid = await registry.solidWorksApplicationCLSID(prefix: paths.bottle) else {
            throw bootstrapError("官方 MSI 未注册 SldWorks.Application ProgID。")
        }
        let missing = await registry.missingCOMRegistrations(
            at: "HKCR\\CLSID\\\(clsid)",
            requires: InstallerDiagnostics.solidWorksRequirements,
            prefix: paths.bottle
        )
        guard missing.isEmpty else {
            throw bootstrapError("SOLIDWORKS COM 注册缺少 \(missing.joined(separator: "、"))。")
        }
    }

    private var installationReceipt: URL {
        paths.appSupportDirectory.appendingPathComponent("installation-complete.json")
    }

    private func writeInstallationReceipt() throws {
        let object: [String: String] = [
            "completedAt": ISO8601DateFormatter().string(from: Date()),
            "solidWorksExecutable": paths.solidWorksExecutable.path,
            "wineVersion": BuildInfo.wineVersion
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: installationReceipt, options: .atomic)
    }

    private func validateInputsOutsideBottle(_ inputs: [URL]) throws {
        let bottle = paths.bottle.resolvingSymlinksInPath().path
        for input in inputs {
            let path = input.resolvingSymlinksInPath().path
            guard path != bottle, !path.hasPrefix(bottle + "/") else {
                throw bootstrapError("安装输入位于待删除的容器内，请先移到容器外。")
            }
        }
    }

    private func bootstrapError(_ message: String) -> NSError {
        NSError(domain: "MacSW.Bootstrap", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
