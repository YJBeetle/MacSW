import Combine
import Foundation

@MainActor
public final class RuntimeStore: ObservableObject {
    @Published public private(set) var state: SolidWorksRuntimeState
    @Published public private(set) var statusMessage = ""
    @Published public private(set) var processes: [WineProcess] = []

    /// 正在拉起但还没出现在容器进程里的 Wine 工具名；UI 用它把按钮变灰并转菊花。
    @Published public private(set) var pendingWineTool: String?

    public let paths: AppPaths
    private let wine: WineService
    private let licenseServer: LicenseServerStore
    private var didRunStartup = false

    public init(paths: AppPaths, licenseServer: LicenseServerStore, wine: WineService = .shared) {
        self.paths = paths
        self.licenseServer = licenseServer
        self.wine = wine
        self.state = paths.solidWorksInstalled ? .unknown : .unavailable
    }

    public var isInstalled: Bool { paths.solidWorksInstalled }
    public var isRunning: Bool { if case .running = state { return true }; return false }

    /// 打开 App 不探测进程状态：需要自动启动时才探测，其余情况等用户查看菜单或启动时再说。
    public func startup(autoLaunch: Bool) {
        guard !didRunStartup else { return }
        didRunStartup = true
        guard autoLaunch else { return }
        Task {
            await refreshState()
            if isInstalled, !isRunning { launch() }
        }
    }

    /// 供面板等待的刷新入口。
    public func refreshNow() async {
        await refreshState()
    }

    public func launch() {
        guard isInstalled else {
            state = .unavailable
            statusMessage = "尚未完成 SOLIDWORKS 安装。"
            return
        }
        switch state {
        case .starting, .running, .stopping: return
        case .unavailable, .unknown, .stopped, .failed: break
        }
        // 状态未知时先确认没有第二份在跑，再决定是否启动。
        let needsRunningProbe = state == .unknown
        state = .starting
        statusMessage = "正在准备启动 SOLIDWORKS…"
        Task {
            do {
                if needsRunningProbe { await refreshState() }
                if isRunning {
                    statusMessage = "SOLIDWORKS 已在运行。"
                    return
                }
                // 许可服务器起不来只降级为提示，不阻断 SOLIDWORKS 启动。
                let licensingWarning: String?
                do {
                    try await licenseServer.ensureRunningIfNeeded()
                    licensingWarning = nil
                } catch {
                    licensingWarning = error.localizedDescription
                }
                guard FileManager.default.isExecutableFile(atPath: wine.wineBinary.path),
                      FileManager.default.fileExists(atPath: wine.uiDaemonExecutable.path) else {
                    throw runtimeError("App 内置 Wine 运行时或 UI 守护程序缺失，请重新打包。")
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

    public func requestQuit() {
        guard isRunning else { return }
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
        Task {
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

    /// 托盘退出时只收尾当前容器；先停托管许可证进程，再结束 wineserver 和其余 Wine 客户进程。
    /// 未能确认进程全部退出时由调用方留在 App 中显示错误，避免假装已经清理完毕。
    public func stopContainerForAppQuit() async throws {
        let snapshot = await ProcessInventory.snapshot(
            bottlePath: paths.bottle.path,
            wineRuntimePath: wine.runtimeURL.path
        )
        guard !snapshot.isEmpty else { return }
        await licenseServer.refreshInstallation()
        try await licenseServer.stopIfRunning()
        guard try await wine.stopWineServerForCleanup(prefix: paths.bottle) else {
            throw runtimeError("未能停止 Wine 容器，MacSW 将继续运行。")
        }
        for attempt in 0..<5 {
            let remaining = await ProcessInventory.snapshot(
                bottlePath: paths.bottle.path,
                wineRuntimePath: wine.runtimeURL.path
            )
            if remaining.isEmpty { return }
            if attempt < 4 { try await Task.sleep(nanoseconds: 500_000_000) }
        }
        throw runtimeError("Wine 容器仍有进程，MacSW 将继续运行；请在维护页检查。")
    }

    /// 重启容器：终止全部 Windows 进程并结束 wineserver；原本在跑 SOLIDWORKS 的话再拉起来。
    public func restartContainer() {
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
        guard pendingWineTool == nil else { return }
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
        let snapshot = await ProcessInventory.snapshot(
            bottlePath: paths.bottle.path,
            wineRuntimePath: wine.runtimeURL.path
        )
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
