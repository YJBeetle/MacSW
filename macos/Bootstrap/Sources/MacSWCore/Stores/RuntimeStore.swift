import Combine
import Foundation

@MainActor
public final class RuntimeStore: ObservableObject {
    @Published public private(set) var state: SolidWorksRuntimeState
    @Published public private(set) var statusMessage = ""
    @Published public private(set) var processes: [WineProcess] = []
    @Published public private(set) var isOpeningDocument = false
    private var launchTask: Task<Void, Never>?

    /// 正在拉起但还没出现在容器进程里的 Wine 工具名；UI 用它把按钮变灰并转菊花。
    @Published public private(set) var pendingWineTool: String?
    @Published public private(set) var wineRuntimeState: WineRuntimeService.State = .unmanaged
    @Published public private(set) var isMigratingWine = false
    private var wineMigrationTask: Task<Void, Never>?

    public func refreshWineRuntime() {
        wineRuntimeState = WineRuntimeService.status(prefix: paths.bottle)
    }

    /// Called only after a UI confirmation that explicitly permits stopping SW.
    public func maintainWineRuntime(_ command: String) {
        guard !isOpeningDocument, !isMigratingWine, !licenseServer.isOperating, !swcliDaemon.isOperating,
              state != .starting, state != .stopping, !wine.isInstalling(prefix: paths.bottle),
              pendingWineTool == nil, ["baseline", "upgrade", "recover"].contains(command) else { return }
        isMigratingWine = true
        licenseServer.runtimeMaintenanceSuspended = true
        fontPreparationSuspended = true
        statusMessage = "正在维护容器，请勿退出 MacSW…"
        wineMigrationTask = Task {
            defer {
                isMigratingWine = false
                licenseServer.runtimeMaintenanceSuspended = false
                fontPreparationSuspended = false
                wineMigrationTask = nil
                refreshWineRuntime()
            }
            if let task = fontPreparation { _ = try? await task.value }
            if let task = swcliTask { _ = try? await task.value }
            fontPreparation = nil
            fontPreparationID = nil
            swcliTask = nil
            swcliTaskID = nil
            do { statusMessage = try await WineRuntimeService.perform(command, prefix: paths.bottle) }
            catch { statusMessage = error.localizedDescription }
            AppPaths.invalidateInstallationState()
            await refreshState()
        }
    }

    public let paths: AppPaths
    private let wine: WineService
    private let licenseServer: LicenseServerStore
    private let fontLinkRepair: @Sendable (URL) async throws -> Void
    private let swcliPreparation: @Sendable (URL) async throws -> Void
    private let processSnapshot: @Sendable (String, String) async -> [WineProcess]
    private let documentOpener: @Sendable (URL, URL) async throws -> Void
    private var swcliTask: Task<Void, Error>?
    private var swcliTaskID: UUID?
    private var fontPreparation: Task<Void, Error>?
    private var fontPreparationID: UUID?
    private var fontPreparationSuspended = false
    private var didRunStartup = false
    public let swcliDaemon: SWCLIDaemonStore

    public init(
        paths: AppPaths,
        licenseServer: LicenseServerStore,
        wine: WineService = .shared,
        fontLinkRepair: (@Sendable (URL) async throws -> Void)? = nil,
        swcliPreparation: (@Sendable (URL) async throws -> Void)? = nil,
        swcliDaemon: SWCLIDaemonStore? = nil,
        processSnapshot: (@Sendable (String, String) async -> [WineProcess])? = nil,
        documentOpener: (@Sendable (URL, URL) async throws -> Void)? = nil
    ) {
        self.paths = paths
        self.licenseServer = licenseServer
        self.wine = wine
        self.processSnapshot = processSnapshot ?? { bottle, runtime in
            await ProcessInventory.snapshot(bottlePath: bottle, wineRuntimePath: runtime)
        }
        self.documentOpener = documentOpener ?? { file, prefix in
            try await DocumentOpeningService(wine: wine).open(file, prefix: prefix)
        }
        self.swcliDaemon = swcliDaemon ?? SWCLIDaemonStore(service: SWCLIDaemonService(bundleURL: Bundle.main.bundleURL, paths: paths))
        self.fontLinkRepair = fontLinkRepair ?? { prefix in
            _ = try await RegistryService(wine: wine).repairTahomaFontLinkIfNeeded(prefix: prefix)
        }
        self.swcliPreparation = swcliPreparation ?? { prefix in
            try await Task.detached {
                try PrerequisiteService.prepareSWCLI(bundleURL: Bundle.main.bundleURL, prefix: prefix)
            }.value
        }
        self.state = paths.solidWorksInstalled ? .unknown : .unavailable
    }

    public var isInstalled: Bool { paths.solidWorksInstalled }
    public var isRunning: Bool { if case .running = state { return true }; return false }

    public func startSWCLIDaemon() {
        refreshWineRuntime()
        guard isInstalled, !isOpeningDocument, !isMigratingWine, !fontPreparationSuspended,
              wineRuntimeState.allowsLaunch, state != .starting, state != .stopping else { return }
        swcliDaemon.start { [self] observed in
            // Deploying over a disconnected but still listening backend is
            // unsafe. Existing startup preparation already deployed its files;
            // the lifecycle wrapper checks/synchronizes again before starting.
            try await ensureFontLinkPrepared()
            if observed == .stopped { try await ensureSWCLIPrepared() }
            try await licenseServer.ensureRunningIfNeeded()
            await refreshState()
            return ProcessInventory.isSolidWorksRunning(processes)
        }
    }

    /// App 启动时建立唯一的字体准备任务，自动和手动启动都等待它完成。
    public func prepareFontLinkAtAppLaunch() {
        refreshWineRuntime()
        guard wineRuntimeState.allowsLaunch else {
            statusMessage = wineRuntimeState.message + " 请打开设置 → 维护。"
            return
        }
        guard !fontPreparationSuspended, fontPreparation == nil,
              paths.bottleExists, paths.solidWorksInstalled else { return }
        let repair = fontLinkRepair
        let bottle = paths.bottle
        fontPreparationID = UUID()
        fontPreparation = Task { try await repair(bottle) }
    }

    func ensureFontLinkPrepared() async throws {
        refreshWineRuntime()
        guard wineRuntimeState.allowsLaunch else { throw runtimeError(wineRuntimeState.message) }
        guard !fontPreparationSuspended else {
            throw runtimeError("容器正在清理或重新安装，稍后再启动 SOLIDWORKS。")
        }
        prepareFontLinkAtAppLaunch()
        guard let task = fontPreparation, let id = fontPreparationID else { return }
        do {
            try await task.value
        } catch {
            // 失败的任务不能留给下一次手动启动复用；其他等待者可能仍在等同一个任务。
            if fontPreparationID == id {
                fontPreparation = nil
                fontPreparationID = nil
            }
            throw error
        }
    }

    /// 删除容器前先阻止新的字体检查，并等正在读写注册表的 Wine 进程退出。
    public func suspendFontPreparationForBottleDeletion() async {
        if let task = wineMigrationTask { await task.value }
        fontPreparationSuspended = true
        await swcliDaemon.waitForOperation()
        // The filesystem deployment must finish before the installer removes
        // the bottle; cancellation alone cannot stop a synchronous copy safely.
        if let task = swcliTask {
            _ = try? await task.value
            swcliTask = nil
            swcliTaskID = nil
        }
        guard let task = fontPreparation else { return }
        task.cancel()
        _ = try? await task.value
        fontPreparation = nil
        fontPreparationID = nil
    }

    public func resumeFontPreparationAfterBottleDeletion() {
        fontPreparationSuspended = false
    }

    /// 打开 App 不探测进程状态：需要自动启动时才探测，其余情况等用户查看菜单或启动时再说。
    public func startup(autoLaunch: Bool) async {
        guard !didRunStartup else { return }
        didRunStartup = true
        refreshWineRuntime()
        guard wineRuntimeState.allowsLaunch else {
            statusMessage = wineRuntimeState.message + " 请打开设置 → 维护。"
            return
        }
        do {
            try await ensureFontLinkPrepared()
        } catch {
            statusMessage = "检查苹方字体链接失败：\(error.localizedDescription)"
            return
        }
        do {
            try await ensureSWCLIPrepared()
        } catch {
            statusMessage = error.localizedDescription
            return
        }
        guard autoLaunch else { return }
        await refreshState()
        if isInstalled, !isRunning { launch() }
    }

    /// 供面板等待的刷新入口。
    public func refreshNow() async {
        await refreshState()
    }

    public func launch() {
        guard launchTask == nil, !swcliDaemon.isOperating else { return }
        guard isInstalled else {
            state = .unavailable
            statusMessage = "尚未完成 SOLIDWORKS 安装。"
            return
        }
        switch state {
        case .starting, .running, .stopping: return
        case .unavailable, .unknown, .stopped, .failed: break
        }
        state = .starting
        statusMessage = "正在准备启动 SOLIDWORKS…"
        launchTask = Task {
            defer { launchTask = nil }
            do {
                // stopped 也可能只是旧观测：daemon 可在两次菜单刷新之间启动隐藏实例。
                await refreshState()
                if isRunning {
                    statusMessage = "SOLIDWORKS 已在运行。"
                    return
                }
                try await ensureFontLinkPrepared()
                try await ensureSWCLIPrepared()
                // 许可服务器起不来只降级为提示，不阻断 SOLIDWORKS 启动。
                let licensingWarning: String?
                do {
                    try await licenseServer.ensureRunningIfNeeded()
                    licensingWarning = nil
                } catch {
                    licensingWarning = error.localizedDescription
                }
                // 准备和许可检查需要等待，真正启动前再确认一次，不能沿用旧的 stopped。
                await refreshState()
                if isRunning {
                    statusMessage = "SOLIDWORKS 已在运行。"
                    return
                }
                guard FileManager.default.isExecutableFile(atPath: wine.wineBinary.path) else {
                    throw runtimeError("App 内置 Wine 运行时缺失，请重新打包。")
                }
                statusMessage = "正在启动 SOLIDWORKS（Wine \(BuildInfo.wineVersion)）…"
                wine.launchSolidWorks(
                    executable: paths.solidWorksExecutable,
                    prefix: paths.bottle,
                    onStarted: { [weak self] in
                        guard let self else { return }
                        self.state = .running
                        self.statusMessage = [
                            "SOLIDWORKS 正在运行。",
                            licensingWarning.map { "许可服务器未就绪：\($0)" }
                        ].compactMap { $0 }.joined(separator: " ")
                    },
                    completion: { [weak self] success, message in
                        guard let self else { return }
                        self.state = success
                            ? (self.paths.solidWorksInstalled ? .stopped : .unavailable)
                            : .failed(message)
                        self.statusMessage = message
                    }
                )
            } catch {
                state = .failed(error.localizedDescription)
                statusMessage = error.localizedDescription
            }
        }
    }

    /// Explicit Finder requests may start SW, but never initialize a missing
    /// bottle or fall back to creating another COM host on an attach failure.
    public func openDocument(_ url: URL) async throws {
        let file = try SolidWorksDocument.validatedURL(url)
        try checkDocumentOpenAllowed()
        isOpeningDocument = true
        defer { isOpeningDocument = false }
        do {
            if let launchTask { await launchTask.value }
            try await ensureFontLinkPrepared()
            try await ensureSWCLIPrepared()
            // Finder can beat App.init's asynchronous licensing refresh on a
            // cold launch. Discover the managed service before deciding no
            // licensing preparation is needed.
            await licenseServer.refreshInstallation()
            try await licenseServer.ensureRunningIfNeeded()
            try checkDocumentOpenAllowed(allowCurrentRequest: true)
            await refreshState()
            if !isRunning, state != .starting {
                launch()
                if let launchTask { await launchTask.value }
            }
            if case .failed(let reason) = state { throw runtimeError(reason) }
            statusMessage = "正在打开 \(file.lastPathComponent)…"
            try await documentOpener(file, paths.bottle)
            await refreshState()
            statusMessage = "已在 SOLIDWORKS 中打开 \(file.lastPathComponent)。"
        } catch {
            statusMessage = "打开文件失败：\(error.localizedDescription)"
            throw error
        }
    }

    private func checkDocumentOpenAllowed(allowCurrentRequest: Bool = false) throws {
        guard isInstalled else { throw runtimeError("请先完成 SOLIDWORKS 安装，再重新打开文件。") }
        guard (allowCurrentRequest || !isOpeningDocument), !isMigratingWine,
              !fontPreparationSuspended, !wine.isInstalling(prefix: paths.bottle),
              !swcliDaemon.isOperating, !licenseServer.isOperating, state != .stopping else {
            throw runtimeError("安装、启动或容器维护正在执行，请完成后重新打开文件。")
        }
        refreshWineRuntime()
        guard wineRuntimeState.allowsLaunch else { throw runtimeError(wineRuntimeState.message) }
    }

    func ensureSWCLIPrepared() async throws {
        guard !fontPreparationSuspended else {
            throw runtimeError("容器正在清理或重新安装，稍后再同步 SWCLI。")
        }
        guard paths.bottleExists, paths.solidWorksInstalled else { return }
        if swcliTask == nil {
            let prepare = swcliPreparation
            let bottle = paths.bottle
            swcliTaskID = UUID()
            swcliTask = Task { try await prepare(bottle) }
        }
        guard let task = swcliTask, let id = swcliTaskID else { return }
        do {
            try await task.value
        } catch {
            if swcliTaskID == id {
                swcliTask = nil
                swcliTaskID = nil
            }
            throw error
        }
    }

    public func requestQuit() {
        guard isRunning, !isOpeningDocument, !swcliDaemon.isOperating else { return }
        state = .stopping
        Task {
            let code = (try? await wine.requestSolidWorksQuit(prefix: paths.bottle)) ?? -1
            if code == 0 {
                statusMessage = "已请求 SOLIDWORKS 正常退出。"
            } else {
                state = .failed("SOLIDWORKS 未响应退出请求。")
                statusMessage = "未能正常退出，可在设置中强制终止。"
            }
        }
    }

    public func forceStop() {
        guard !isOpeningDocument, !isMigratingWine, !swcliDaemon.isOperating else { return }
        Task {
            refreshWineRuntime()
            if !wineRuntimeState.allowsLaunch {
                do {
                    _ = try await WineRuntimeService.perform("stop", prefix: paths.bottle)
                    statusMessage = "已停止当前容器。"
                    await refreshState()
                } catch { statusMessage = error.localizedDescription }
                return
            }
            let code = (try? await wine.forceStopSolidWorks(prefix: paths.bottle)) ?? -1
            // wineserver 不是 Windows 进程，taskkill 打不掉它，需要单独收尾。
            if await wine.waitWineserver(prefix: paths.bottle, seconds: 10) {
                statusMessage = code == 0 ? "已强制终止全部容器进程。" : "容器进程已收尾（taskkill 返回 \(code)）。"
            } else if (try? await wine.stopWineServerForCleanup(prefix: paths.bottle)) == true {
                statusMessage = "已强制终止全部容器进程。"
            } else {
                statusMessage = "部分进程未能停止，请查看 solidworks-stop.log。"
            }
            state = paths.solidWorksInstalled ? .stopped : .unavailable
            await refreshState()
        }
    }

    /// All exit paths share bounded cleanup. Only an explicit normal-quit
    /// confirmation may allow stopping the main CAD session; updates never do.
    public func stopContainerForAppQuit(forUpdate: Bool = false, allowMainTermination: Bool = false) async throws {
        guard !isOpeningDocument else { throw runtimeError("正在打开文件，请完成后再退出。") }
        guard !swcliDaemon.isOperating else { throw runtimeError("SWCLI 正在启动，请完成后再退出。") }
        guard !isMigratingWine else { throw runtimeError("Wine 迁移正在执行，请完成后再退出。") }
        let prefix = paths.bottle
        let runtimePath = wine.runtimeURL.path
        let cleanup = ContainerShutdownService(
            snapshot: { try await ProcessInventory.snapshotForUpdate(bottlePath: prefix.path, wineRuntimePath: runtimePath) },
            stopServer: { _ = try await WineRuntimeService.perform("stop", prefix: prefix) },
            signal: { process, signal in
                try await ProcessInventory.signalAuxiliary(process, signal: signal,
                                                          bottlePath: prefix.path, wineRuntimePath: runtimePath)
            }
        )
        try await cleanup.stop(protectMain: forUpdate || !allowMainTermination)
    }

    /// 重启容器：终止全部 Windows 进程并结束 wineserver；原本在跑 SOLIDWORKS 的话再拉起来。
    public func restartContainer() {
        guard !isOpeningDocument, !isMigratingWine, !swcliDaemon.isOperating else { return }
        refreshWineRuntime()
        guard wineRuntimeState.allowsLaunch else {
            statusMessage = wineRuntimeState.message + " 请打开设置 → 维护。"
            return
        }
        let wasRunning = isRunning
        if wasRunning { state = .stopping }
        Task {
            _ = try? await wine.forceStopSolidWorks(prefix: paths.bottle)
            let settled = await wine.waitWineserver(prefix: paths.bottle, seconds: 15)
            if !settled {
                _ = try? await wine.stopWineServerForCleanup(prefix: paths.bottle)
            }
            await refreshState()
            if wasRunning {
                statusMessage = "容器已重启，正在重新拉起 SOLIDWORKS。"
                launch()
            } else {
                statusMessage = "容器已完全停止，下次启动等于冷启动。"
            }
        }
    }

    /// Wine 的窗口不是瞬间弹出的：点下去立刻变灰转菊花，撑过这段空窗就收回，
    /// 不去猜进程有没有起来（猜错会一直转）。真实证据是下面 1 秒刷新的容器进程表。
    public func openWineTool(_ name: String) {
        guard !isOpeningDocument, !isMigratingWine, pendingWineTool == nil else { return }
        pendingWineTool = name
        if name == "cmd" {
            statusMessage = "正在打开 macOS 终端并启动 CMD…"
            Task {
                do {
                    try await wine.launchCommandPromptInTerminal(prefix: paths.bottle)
                    statusMessage = "已在 macOS 终端打开 CMD。"
                } catch {
                    statusMessage = error.localizedDescription
                }
                pendingWineTool = nil
            }
            return
        }
        statusMessage = "正在启动 \(name)…Wine 冷启动需要几秒。"
        do {
            try wine.launchTool(name, prefix: paths.bottle)
        } catch {
            pendingWineTool = nil
            statusMessage = error.localizedDescription
            return
        }
        let tool = name
        Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard pendingWineTool == tool else { return }
            pendingWineTool = nil
            statusMessage = "\(tool) 已交给 Wine 启动；窗口还没出现的话，稍等一两秒看下面的容器进程表。"
        }
    }

    private func refreshState() async {
        let snapshot = await processSnapshot(paths.bottle.path, wine.runtimeURL.path)
        if snapshot != processes { processes = snapshot }
        apply(observingRunning: ProcessInventory.isSolidWorksRunning(snapshot))
    }

    /// 进程表是唯一证据，但 `starting/stopping/failed` 是用户刚点出来的意图，
    /// 合并规则在 `SolidWorksRuntimeState.applying` 里。
    private func apply(observingRunning running: Bool) {
        let next = state.applying(observedRunning: running, installed: paths.solidWorksInstalled)
        if next != state { state = next }
    }

    private func runtimeError(_ message: String) -> NSError {
        MacSWError.make(message, domain: "MacSW.RuntimeStore")
    }
}
