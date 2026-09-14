import Combine
import Foundation

public extension Notification.Name {
    static let macSWInstallationCompleted = Notification.Name("MacSWInstallationCompleted")
}

@MainActor
public final class BootstrapStore: ObservableObject {
    @Published public var selectedMedia: URL?
    @Published public var cleanInstall = false
    @Published public var preloadSerialNumbers = false
    @Published public var serialInputMode: SerialInputMode = .text
    @Published public var serialText = ""
    @Published public var selectedSerialFile: SerialInputFile?
    @Published public private(set) var serialCandidates: [SerialInputFile] = []
    @Published public private(set) var state: InstallationState = .idle
    @Published public private(set) var stepStatuses: [InstallationStep: InstallationStepStatus] = [:]
    @Published public private(set) var stepDetails: [InstallationStep: String] = [:]
    @Published public private(set) var statusMessage = "选择官方安装介质后即可开始。"

    public let paths: AppPaths
    private let wine: WineService
    private let prerequisites: PrerequisiteService
    private let registry: RegistryService
    private let iso: IsoService
    private var installationTask: Task<Void, Never>?

    public init(
        paths: AppPaths,
        wine: WineService = .shared,
        prerequisites: PrerequisiteService = .shared,
        registry: RegistryService? = nil,
        iso: IsoService = .shared
    ) {
        self.paths = paths
        self.wine = wine
        self.prerequisites = prerequisites
        self.registry = registry ?? RegistryService(wine: wine)
        self.iso = iso
    }

    public var canStart: Bool {
        guard selectedMedia != nil, !state.isActive else { return false }
        guard preloadSerialNumbers else { return true }
        switch serialInputMode {
        case .text: return !serialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .file: return selectedSerialFile != nil
        }
    }
    public var showsCleanInstall: Bool { paths.bottleExists }
    public var selectedRegistryWillImportRaw: Bool {
        preloadSerialNumbers && serialInputMode == .file && selectedSerialFile?.kind == .registry
    }

    public func selectMedia(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue || url.pathExtension.caseInsensitiveCompare("iso") == .orderedSame else {
            statusMessage = "安装介质仅支持 ISO 文件或目录。"
            return
        }
        selectedMedia = url
        statusMessage = "已选择：\(url.lastPathComponent)"
        scanSerialInputs()
    }

    public func selectSerialFile(_ url: URL) {
        let kind: SerialInputFileKind
        switch url.pathExtension.lowercased() {
        case "txt": kind = .text
        case "reg": kind = .registry
        default:
            statusMessage = "预载序列号文件仅支持 .txt 或 .reg。"
            return
        }
        selectedSerialFile = SerialInputFile(url: url, kind: kind, depth: 0)
        preloadSerialNumbers = true
        serialInputMode = .file
        statusMessage = kind == .registry
            ? "已选择注册表文件；部署前将提示原样导入。"
            : "已选择序列号文本文件。"
    }

    public func scanSerialInputs() {
        guard let selectedMedia else { return }
        Task {
            let candidates = await Task.detached {
                CompanionFileService.findSerialInputs(nextTo: selectedMedia)
            }.value
            guard self.selectedMedia == selectedMedia else { return }
            serialCandidates = candidates
            if let preferred = CompanionFileService.preferredAutomaticSelection(from: candidates) {
                selectedSerialFile = preferred
                preloadSerialNumbers = true
                serialInputMode = .file
                statusMessage = "已自动识别序列号文件：\(preferred.url.lastPathComponent)"
            } else if candidates.count > 1 {
                statusMessage = "发现多个序列号文件，请选择要使用的文件。"
            }
        }
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
        statusMessage = "不完整安装已清理。"
    }

    private func runInstallation() async {
        guard let selectedMedia else { return }
        state = .preparing
        stepStatuses = [:]
        stepDetails = [:]
        report(.environment, .running, "正在准备安装介质与唯一 Wine 容器…")
        statusMessage = "正在准备官方安装程序…"
        var mountedByApp: URL?
        defer {
            if let mountedByApp { iso.unmount(mountedByApp) }
            installationTask = nil
        }

        do {
            let preparedSerialInput = try prepareSerialInput()
            let media: URL
            if selectedMedia.pathExtension.caseInsensitiveCompare("iso") == .orderedSame {
                media = try await iso.mount(selectedMedia)
                mountedByApp = media
            } else {
                media = selectedMedia
            }
            try Task.checkCancellation()
            let installer = media.appendingPathComponent("swwi/data/solidworks.msi")
            guard FileManager.default.fileExists(atPath: installer.path) else {
                throw bootstrapError("介质中未找到 swwi/data/solidworks.msi。")
            }

            if cleanInstall, paths.bottleExists {
                try validateInputsOutsideBottle([selectedMedia, selectedSerialFile?.url, media].compactMap { $0 })
                guard try await wine.stopWineServerForCleanup(prefix: paths.bottle) else {
                    throw bootstrapError("未能停止容器进程，已取消全新安装。")
                }
                try FileManager.default.removeItem(at: paths.bottle)
                try? FileManager.default.removeItem(at: installationReceipt)
            }
            try Task.checkCancellation()

            let wineboot = wine.makeProcess(arguments: ["wineboot", "-u"], prefix: paths.bottle)
            let bootCode = try await wine.runCancellable(
                wineboot,
                log: paths.logs.appendingPathComponent("wineboot.log")
            )
            guard bootCode == 0 else { throw bootstrapError("Wine 初始化失败（\(bootCode)）。") }
            try await prerequisites.configureMono(prefix: paths.bottle)
            try prerequisites.prepareManagedCOMRegistration(prefix: paths.bottle)
            try prerequisites.prepareManagedCOMDependencies(prefix: paths.bottle)
            try await wine.configureSolidWorksCompatibility(prefix: paths.bottle)
            report(.environment, .completed, "Mono、RegAsm、stdole 与输入兼容设置已就绪")

            state = .installing(.vcRuntime)
            report(.vcRuntime, .running, "正在运行官方 VC++ x64 安装包…")
            try await prerequisites.installVC(media: media, prefix: paths.bottle)
            report(.vcRuntime, .completed, "VC++ 运行库已检查")

            state = .installing(.loginManager)
            report(.loginManager, .running, "正在后台安装 SOLIDWORKS Login Manager…")
            try await prerequisites.installLoginManager(media: media, prefix: paths.bottle)
            report(.loginManager, .completed, "Login Manager 与托管 COM 注册已完成")

            state = .installing(.serialNumbers)
            report(.serialNumbers, .running, "正在准备安装序列号…")
            try await preloadSerials(preparedSerialInput)

            state = .installing(.installer)
            report(.installer, .running, "请在官方安装窗口继续操作；可随时停止本次安装")
            let installerCode = try await wine.runInstaller(msi: installer, prefix: paths.bottle)
            if WineService.isCancelledInstallerStatus(installerCode) { throw CancellationError() }
            let installerSucceeded = WineService.isSuccessfulInstallerStatus(installerCode)
            report(.installer, installerSucceeded ? .completed : .warning, "安装器退出码 \(installerCode)")
            try Task.checkCancellation()

            guard paths.solidWorksInstalled else {
                throw bootstrapError("安装器已退出，但未找到 SOLIDWORKS 主程序。")
            }

            state = .installing(.wpfThemes)
            report(.wpfThemes, .running, "正在从微软安装包提取五个主题库…")
            try await prerequisites.installThemes(
                media: media,
                prefix: paths.bottle,
                target: paths.solidWorksExecutable.deletingLastPathComponent()
            )
            report(.wpfThemes, .completed, "五个 WPF 主题库已补齐")

            state = .installing(.validation)
            report(.validation, .running, "正在验证安装结果…")
            try validateInstalledRuntime()
            try writeInstallationReceipt()
            report(.validation, installerSucceeded ? .completed : .warning,
                   installerSucceeded ? "基础文件检查通过" : "文件检查通过，但安装器返回了警告状态")
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

    private enum PreparedSerialInput {
        case none
        case assignments([RegistryAssignment], String)
        case registry(URL)
    }

    private func prepareSerialInput() throws -> PreparedSerialInput {
        guard preloadSerialNumbers else { return .none }
        switch serialInputMode {
        case .text:
            let parsed = try SerialNumberService.parse(serialText)
            return .assignments(
                SerialNumberService.registryAssignments(for: parsed),
                "已写入 \(parsed.values.count) 个产品序列号"
            )
        case .file:
            guard let selectedSerialFile else { throw bootstrapError("请选择序列号文本或注册表文件。") }
            guard FileManager.default.fileExists(atPath: selectedSerialFile.url.path) else {
                throw bootstrapError("序列号文件不存在：\(selectedSerialFile.url.path)")
            }
            switch selectedSerialFile.kind {
            case .text:
                let text = try String(contentsOf: selectedSerialFile.url, encoding: .utf8)
                let parsed = try SerialNumberService.parse(text)
                return .assignments(
                    SerialNumberService.registryAssignments(for: parsed),
                    "已解析并写入 \(selectedSerialFile.url.lastPathComponent)"
                )
            case .registry:
                return .registry(selectedSerialFile.url)
            }
        }
    }

    private func preloadSerials(_ prepared: PreparedSerialInput) async throws {
        switch prepared {
        case .none:
            report(.serialNumbers, .skipped, "未启用预载序列号")
        case .assignments(let assignments, let detail):
            try await registry.write(assignments, prefix: paths.bottle)
            report(.serialNumbers, .completed, detail)
        case .registry(let url):
            try await registry.importRegistryFile(url, prefix: paths.bottle)
            report(.serialNumbers, .completed, "已原样导入 \(url.lastPathComponent)")
        }
    }

    private func report(_ step: InstallationStep, _ status: InstallationStepStatus, _ detail: String) {
        stepStatuses[step] = status
        stepDetails[step] = detail
    }

    private func validateInstalledRuntime() throws {
        guard paths.solidWorksInstalled else { throw bootstrapError("未找到 SOLIDWORKS 主程序。") }
        let target = paths.solidWorksExecutable.deletingLastPathComponent()
        for theme in PrerequisiteService.themes {
            guard FileManager.default.fileExists(atPath: target.appendingPathComponent("PresentationFramework.\(theme).dll").path) else {
                throw bootstrapError("缺少 WPF 主题库 PresentationFramework.\(theme).dll。")
            }
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
