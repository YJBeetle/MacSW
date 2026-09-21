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

    public func refresh() {
        Task { await refreshState() }
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
                      FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/sw_ui_daemon.exe").path) else {
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

    /// 重启容器：终止全部 Windows 进程并结束 wineserver；原本在跑 SOLIDWORKS 的话再拉起来。
    public func restartContainer() {
        let wasRunning = isRunning
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

    /// Wine 冷启动要几秒，工具窗口不会立刻出现；这里负责把"点下去了"这件事反馈出来，
    /// 并在容器进程里真的看到该工具（或超时）之后收尾。
    public func openWineTool(_ name: String) {
        guard pendingWineTool == nil else { return }
        pendingWineTool = name
        statusMessage = "正在启动 \(name)…Wine 冷启动需要几秒。"
        do {
            try wine.launchTool(name, prefix: paths.bottle)
        } catch {
            pendingWineTool = nil
            statusMessage = error.localizedDescription
            return
        }
        let toolProcess = "\(name).exe"
        Task {
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await refreshState()
                if processes.contains(where: { $0.name.caseInsensitiveCompare(toolProcess) == .orderedSame }) {
                    statusMessage = "\(name) 已启动。"
                    break
                }
            }
            if pendingWineTool == name {
                pendingWineTool = nil
                if !processes.contains(where: { $0.name.caseInsensitiveCompare(toolProcess) == .orderedSame }) {
                    statusMessage = "\(name) 没有出现在容器进程里，可能被 Wine 拒绝或已立即退出。"
                }
            }
        }
    }

    private func refreshState() async {
        let snapshot = await ProcessInventory.snapshot(
            bottlePath: paths.bottle.path,
            wineRuntimePath: wine.runtimeURL.path
        )
        if snapshot != processes { processes = snapshot }
        state = ProcessInventory.isSolidWorksRunning(snapshot)
            ? .running
            : (paths.solidWorksInstalled ? .stopped : .unavailable)
    }

    private func runtimeError(_ message: String) -> NSError {
        NSError(domain: "MacSW.RuntimeStore", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
