import AppKit
import Combine
import MacSWCore
import Sparkle

/// Only replaces MacSW.app. The bottle and documents stay outside Sparkle.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var preparingTermination = false
    @Published private(set) var automaticChecks = false
    private var controller: SPUStandardUpdaterController?
    private var observation: AnyCancellable?
    private let runtime: RuntimeStore
    private let bootstrap: BootstrapStore
    private let licensing: LicenseServerStore
    private var installationPending = false

    init(runtime: RuntimeStore, bootstrap: BootstrapStore, licensing: LicenseServerStore) {
        self.runtime = runtime
        self.bootstrap = bootstrap
        self.licensing = licensing
        super.init()
    }

    func start() {
        guard controller == nil,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              AppUpdatePolicy.validPublicKey(key) else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.publisher(for: \.canCheckForUpdates).sink { [weak self] value in
            self?.canCheck = value
        }
        controller.startUpdater()
        automaticChecks = controller.updater.automaticallyChecksForUpdates
    }

    func check() { controller?.checkForUpdates(nil) }

    func setAutomaticChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
        automaticChecks = controller?.updater.automaticallyChecksForUpdates ?? false
    }

    private var maintenance: Bool {
        bootstrap.state.isActive || bootstrap.isInspectingMedia || runtime.isMigratingWine ||
        licensing.isOperating || runtime.swcliDaemon.isOperating || runtime.isOpeningDocument ||
        runtime.state == .starting || runtime.state == .stopping || runtime.pendingWineTool != nil
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if maintenance || preparingTermination {
            throw NSError(domain: "MacSW.Update", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "安装或容器维护中，请稍后检查更新。"])
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        installationPending = true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installationPending = true
        return false
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        installationPending = false
    }

    /// Normal quit, Command-Q and Sparkle all enter the same termination gate.
    func shouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        guard !preparingTermination else { return .terminateCancel }
        let forUpdate = installationPending
        preparingTermination = true
        Task {
            defer { preparingTermination = false }
            do {
                let snapshot = try await ProcessInventory.snapshotForUpdate(bottlePath: runtime.paths.bottle.path,
                    wineRuntimePath: WineService.shared.runtimeURL.path)
                if let reason = AppUpdatePolicy.blockingReason(maintenance: maintenance,
                                                               processes: forUpdate ? snapshot : []) {
                    throw NSError(domain: "MacSW.Update", code: 2, userInfo: [NSLocalizedDescriptionKey: reason])
                }
                let mainIsRunning = ProcessInventory.isSolidWorksRunning(snapshot)
                if !forUpdate && mainIsRunning {
                    let alert = NSAlert()
                    alert.messageText = "结束 SOLIDWORKS 并退出 MacSW？"
                    alert.informativeText = "未保存的 SOLIDWORKS 内容会丢失。此容器中的其他程序也会一并结束。"
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "结束程序并退出")
                    alert.addButton(withTitle: "取消")
                    guard alert.runModal() == .alertFirstButtonReturn else {
                        app.reply(toApplicationShouldTerminate: false)
                        return
                    }
                }
                try await runtime.stopContainerForAppQuit(forUpdate: forUpdate,
                                                         allowMainTermination: !forUpdate && mainIsRunning)
                app.reply(toApplicationShouldTerminate: true)
            } catch {
                let alert = NSAlert()
                alert.messageText = forUpdate ? "暂不能安装 MacSW 更新" : "未能退出 MacSW"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "好")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
                app.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}
