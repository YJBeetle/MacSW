import AppKit
import Combine
import MacSWCore
import Sparkle

/// Only replaces MacSW.app. The bottle and documents stay outside Sparkle.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var preparingInstallation = false
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
        if maintenance {
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

    /// Sparkle's replacement waits for application termination. This gate also
    /// covers install-on-quit; postponing relaunch alone does not cover that path.
    func shouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        guard installationPending else { return .terminateNow }
        guard !preparingInstallation else { return .terminateCancel }
        preparingInstallation = true
        Task {
            defer { preparingInstallation = false }
            do {
                let snapshot = try await ProcessInventory.snapshotForUpdate(bottlePath: runtime.paths.bottle.path,
                    wineRuntimePath: WineService.shared.runtimeURL.path)
                if let reason = AppUpdatePolicy.blockingReason(maintenance: maintenance, processes: snapshot) {
                    throw NSError(domain: "MacSW.Update", code: 2, userInfo: [NSLocalizedDescriptionKey: reason])
                }
                // Only known infrastructure remains. The existing shutdown path
                // stops managed licensing and verifies the bottle is empty.
                try await runtime.stopContainerForAppQuit(forUpdate: true)
                app.reply(toApplicationShouldTerminate: true)
            } catch {
                let alert = NSAlert()
                alert.messageText = "暂不能安装 MacSW 更新"
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
