import Combine
import Foundation

@MainActor
public final class RuntimeStore: ObservableObject {
    @Published public private(set) var state: SolidWorksRuntimeState
    @Published public private(set) var statusMessage = ""

    public let paths: AppPaths
    private let wine: WineService
    private let licenseServer: LicenseServerStore
    private var didRunStartup = false

    public init(paths: AppPaths, licenseServer: LicenseServerStore, wine: WineService = .shared) {
        self.paths = paths
        self.licenseServer = licenseServer
        self.wine = wine
        self.state = paths.solidWorksInstalled ? .stopped : .unavailable
    }

    public var isInstalled: Bool { paths.solidWorksInstalled }
    public var isRunning: Bool { if case .running = state { return true }; return false }

    public func startup(autoLaunch: Bool) {
        guard !didRunStartup else { return }
        didRunStartup = true
        Task {
            await refreshState()
            if autoLaunch, isInstalled, !isRunning { launch() }
        }
    }

    public func refresh() {
        Task { await refreshState() }
    }

    public func launch() {
        guard isInstalled else {
            state = .unavailable
            statusMessage = "尚未完成 SOLIDWORKS 安装。"
            return
        }
        switch state {
        case .starting, .running, .stopping: return
        case .unavailable, .stopped, .failed: break
        }
        state = .starting
        statusMessage = "正在准备启动 SOLIDWORKS…"
        Task {
            do {
                try await licenseServer.ensureRunningIfNeeded()
                guard FileManager.default.isExecutableFile(atPath: wine.wineBinary.path),
                      FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/sw_ui_daemon.exe").path) else {
                    throw runtimeError("App 内置 Wine 运行时或 UI 守护程序缺失，请重新打包。")
                }
                state = .running
                statusMessage = "正在启动 SOLIDWORKS（Wine \(BuildInfo.wineVersion)）…"
                wine.launchSolidWorks(executable: paths.solidWorksExecutable, prefix: paths.bottle) { [weak self] _, message in
                    guard let self else { return }
                    self.state = self.paths.solidWorksInstalled ? .stopped : .unavailable
                    self.statusMessage = message
                }
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
            state = paths.solidWorksInstalled ? .stopped : .unavailable
            statusMessage = code == 0 ? "已强制终止 SOLIDWORKS。" : "强制终止失败（\(code)）。"
        }
    }

    public func openWineTool(_ name: String) {
        do { try wine.launchTool(name, prefix: paths.bottle) }
        catch { statusMessage = error.localizedDescription }
    }

    private func refreshState() async {
        if await wine.isSolidWorksProcessRunning(prefix: paths.bottle) {
            state = .running
        } else {
            state = paths.solidWorksInstalled ? .stopped : .unavailable
        }
    }

    private func runtimeError(_ message: String) -> NSError {
        NSError(domain: "MacSW.RuntimeStore", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
