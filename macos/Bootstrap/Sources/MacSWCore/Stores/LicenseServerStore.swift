import Combine
import Foundation

@MainActor
public final class LicenseServerStore: ObservableObject {
    @Published public private(set) var state: FlexNetRuntimeState = .notInstalled
    @Published public private(set) var installation: ManagedFlexNetInstallation?
    @Published public var addressInput = ""
    @Published public private(set) var addressNotice = ""
    @Published public private(set) var addressHasError = false
    @Published public private(set) var statusMessage = ""
    @Published public private(set) var isOperating = false
    /// 上一次真正写进注册表的内容，用来判断输入框是否需要再写一次。
    @Published public private(set) var appliedAddress: String?
    /// 安装 FlexNet 失败的原因，界面用它弹窗；非空即表示要弹。
    @Published public private(set) var installProblem: String?

    public let paths: AppPaths
    private let registry: RegistryService
    private let service: FlexNetService
    private let wine: WineService
    private var didSyncFromContainer = false

    public init(paths: AppPaths, wine: WineService = .shared) {
        self.paths = paths
        self.wine = wine
        self.registry = RegistryService(wine: wine)
        self.service = FlexNetService(paths: paths, wine: wine, registry: registry)
    }

    public var isInstalled: Bool { installation != nil }
    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// 只读文件系统清单，不启动 Wine；用于打开 App 时的轻量刷新。
    public func refreshInstallation() async {
        let service = self.service
        installation = await Task.detached(priority: .utility) { service.installed }.value
        guard installation == nil else { return }
        switch state {
        case .starting, .stopping, .failed: break
        default: state = .notInstalled
        }
    }

    /// 只探测许可端口（不读注册表、不启动 Wine），供菜单栏面板高频刷新使用。
    public func refreshRunningState() async {
        await refreshInstallation()
        await updateObservedState()
    }

    /// 完整刷新：读容器注册表里的许可服务器列表并探测端口。要起一个 wine 进程，
    /// 所以只在用户显式要求"重新读取"时调用，不进启动路径。
    public func refresh() async {
        await refreshInstallation()
        let servers = await registry.readLicenseServers(prefix: paths.bottle)
        addressInput = servers.canonical
        appliedAddress = servers.canonical
        await updateObservedState()
    }

    private func updateObservedState() async {
        guard let installation else { return }
        // 启动中/停止中/报错都是用户点出来的意图，端口探测一次就把状态冲掉会让按钮闪、错误消失。
        switch state {
        case .starting, .stopping, .failed: return
        default: break
        }
        state = await isPortOpen(installation.port) ? .running(installation.port) : .stopped
    }

    /// 读一次容器里的真实配置，让单选框显示的是注册表而不是"我们上次点了什么"。
    /// 一次 `reg query` 要起一个 wine 进程（约 6 秒），所以每次运行默认只自动读一次，
    /// 之后由用户显式要求再读；期间沿用写入的锁，免得读取结果盖掉刚选的东西。
    public func syncFromContainer(force: Bool = false) async {
        guard force || !didSyncFromContainer else { return }
        guard !isOperating else { return }
        isOperating = true
        defer { isOperating = false }
        await refresh()
        didSyncFromContainer = true
    }

    @discardableResult
    public func normalizeAddressInput() -> Bool {
        if addressInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            addressInput = ""
            addressNotice = ""
            addressHasError = false
            return true
        }
        do {
            let parsed = try LicenseServerAddressService.parse(addressInput)
            let canonical = parsed.canonical
            let changed = canonical != addressInput.trimmingCharacters(in: .whitespacesAndNewlines)
            addressInput = canonical
            addressNotice = changed ? "已转换为 SOLIDWORKS 使用的 port@host 格式。" : ""
            addressHasError = false
            return true
        } catch {
            addressNotice = error.localizedDescription
            addressHasError = true
            return false
        }
    }

    /// 选完就检查文件是否齐备：`lmgrd.exe`、唯一 `.lic` 里的端口、`VENDOR` 引用的守护进程。
    /// 安装界面与设置页共用这一份判定，压缩包只能等解包后再验。
    public func checkedPackage(at url: URL) async -> FlexNetPackageCheck {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .rejected("所选 FlexNet 来源不存在。")
        }
        guard isDirectory.boolValue else { return .archiveNotChecked }
        let checker = service
        return await Task.detached(priority: .utility) {
            switch Result(catching: { try checker.inspect(directory: url) }) {
            case .success(let metadata): return .ready(metadata)
            case .failure(let error): return .rejected(error.localizedDescription)
            }
        }.value
    }

    /// 单选即生效：把选中的模式写进容器注册表。
    /// 写入期间 isOperating 为真，界面上整块随之锁住并转菊花，
    /// 因此不会出现用户连着切、旧写入盖掉新选择的情况。
    public func apply(mode: BootstrapLicenseMode) {
        guard !isOperating else { return }
        Task {
            isOperating = true
            defer { isOperating = false }
            do {
                switch mode {
                case .unconfigured:
                    guard !addressInput.isEmpty else { return }
                    try await registry.clearLicenseServers(prefix: paths.bottle, includingServiceMarker: true)
                    addressInput = ""
                    appliedAddress = ""
                    statusMessage = "已清空许可服务器地址。"
                case .remoteServer:
                    guard normalizeAddressInput(), !addressInput.isEmpty else {
                        statusMessage = "还没有填写服务器地址。"
                        return
                    }
                    try await registry.writeLicenseServers(
                        try LicenseServerAddressService.parse(addressInput), prefix: paths.bottle
                    )
                    appliedAddress = addressInput
                    statusMessage = "许可服务器地址已写入注册表。"
                case .managedFlexNet:
                    guard let metadata = installation else {
                        statusMessage = "尚未安装托管 FlexNet 服务器。"
                        return
                    }
                    try await registry.writeLicenseServers(
                        .managed(port: metadata.port),
                        prefix: paths.bottle,
                        serviceName: FlexNetService.serviceName
                    )
                    addressInput = metadata.managedAddress
                    appliedAddress = metadata.managedAddress
                    statusMessage = "已写入托管服务器地址 \(metadata.managedAddress)。"
                }
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    public func dismissInstallProblem() { installProblem = nil }

    public func install(from source: URL) {
        guard !isOperating else { return }
        Task {
            isOperating = true
            statusMessage = "正在验证并安装 FlexNet…"
            defer { isOperating = false }
            if case .rejected(let reason) = await checkedPackage(at: source) {
                installProblem = reason
                statusMessage = reason
                return
            }
            do {
                let metadata = try await service.install(from: source)
                installation = metadata
                addressInput = metadata.managedAddress
                appliedAddress = metadata.managedAddress
                statusMessage = "FlexNet 已安装到 \(AppPaths.managedFlexNetWindowsPath)。"
                state = .stopped
                try await startAndWait()
            } catch is CancellationError {
                statusMessage = "FlexNet 安装已取消，原有版本保持不变。"
            } catch {
                state = .failed(error.localizedDescription)
                statusMessage = error.localizedDescription
                installProblem = error.localizedDescription
            }
        }
    }

    public func uninstall() {
        guard !isOperating, installation != nil else { return }
        Task {
            isOperating = true
            statusMessage = "正在卸载托管 FlexNet…"
            defer { isOperating = false }
            do {
                try await stopAndWait()
                try await service.uninstall()
                addressInput = ""
                appliedAddress = ""
                installation = nil
                state = .notInstalled
                statusMessage = "托管 FlexNet 已卸载，许可服务器列表已清空。"
            } catch {
                state = .failed(error.localizedDescription)
                statusMessage = error.localizedDescription
            }
        }
    }

    /// 安装链路内联使用：许可单选只会给出其中一个输入。
    public func configureDuringInstallation(address: String, flexNetSource: URL?) async throws {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let servers = try LicenseServerAddressService.parse(trimmed)
            try await registry.writeLicenseServers(servers, prefix: paths.bottle)
            addressInput = servers.canonical
        }
        guard let flexNetSource else { return }
        let metadata = try await service.install(from: flexNetSource)
        installation = metadata
        addressInput = metadata.managedAddress
        appliedAddress = metadata.managedAddress
        state = .stopped
        try await startAndWait()
    }

    /// 覆盖安装前用：托管服务器还在跑就会占着要被覆盖的目录，FlexNet 那一步会在移动时失败。
    /// 探端口而不是看 state：安装窗口这条路径上没人保证状态刚刷新过。
    public func stopIfRunning() async throws {
        guard let installation, await isPortOpen(installation.port) else { return }
        try await stopAndWait()
    }

    public func start() {
        guard !isOperating else { return }
        Task {
            isOperating = true
            defer { isOperating = false }
            do { try await startAndWait() }
            catch {
                state = .failed(error.localizedDescription)
                statusMessage = error.localizedDescription
            }
        }
    }

    public func stop() {
        guard !isOperating else { return }
        Task {
            isOperating = true
            defer { isOperating = false }
            do { try await stopAndWait() }
            catch {
                state = .failed(error.localizedDescription)
                statusMessage = error.localizedDescription
            }
        }
    }

    public func ensureRunningIfNeeded() async throws {
        guard let installation else { return }
        let servers = await registry.readLicenseServers(prefix: paths.bottle)
        addressInput = servers.canonical
        guard servers.endpoints.contains(where: { $0.port == installation.port && $0.isLoopback }) else { return }
        if await isPortOpen(installation.port) {
            state = .running(installation.port)
            return
        }
        try await startAndWait()
    }

    private func startAndWait() async throws {
        guard let installation else { throw storeError("尚未安装托管 FlexNet。") }
        if await isPortOpen(installation.port) {
            state = .running(installation.port)
            return
        }
        state = .starting
        statusMessage = "正在启动 FlexNet…"
        let executable = paths.managedFlexNet.appendingPathComponent("lmgrd.exe")
        let license = paths.managedFlexNet.appendingPathComponent(installation.licenseFile)
        let process = wine.makeProcess(arguments: [
            executable.path, "-c", license.path, "-l", paths.logs.appendingPathComponent("flexnet.log").path
        ], prefix: paths.bottle)
        process.currentDirectoryURL = paths.managedFlexNet
        let handle = try wine.logHandle(for: paths.logs.appendingPathComponent("flexnet-launch.log"))
        process.standardOutput = handle ?? FileHandle.nullDevice
        process.standardError = handle ?? FileHandle.nullDevice
        process.terminationHandler = { _ in try? handle?.close() }
        do { try process.run() }
        catch {
            // 没跑起来的进程不会有 terminationHandler，句柄得自己关掉。
            try? handle?.close()
            throw error
        }

        for _ in 0..<30 {
            try Task.checkCancellation()
            if await isPortOpen(installation.port) {
                state = .running(installation.port)
                statusMessage = "FlexNet 正在运行（端口 \(installation.port)）。"
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw storeError("FlexNet 在 15 秒内未监听端口 \(installation.port)，请查看 flexnet.log。")
    }

    private func stopAndWait() async throws {
        state = .stopping
        guard let installation else {
            state = .notInstalled
            return
        }
        // 守护进程名来自 .lic 的 VENDOR 行；写死 SW_D.exe 会放过别的发行版的守护进程。
        let process = wine.makeProcess(arguments: [
            "taskkill", "/f", "/im", "lmgrd.exe", "/im", installation.vendorDaemon
        ], prefix: paths.bottle)
        _ = try await wine.runCancellable(process, log: paths.logs.appendingPathComponent("flexnet-stop.log"))
        for _ in 0..<10 {
            if !(await isPortOpen(installation.port)) { break }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        state = .stopped
        statusMessage = "FlexNet 已停止。"
    }

    private func isPortOpen(_ port: UInt16) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-z", "-w", "1", "127.0.0.1", String(port)]
        return ((try? await wine.runCancellable(process)) ?? -1) == 0
    }

    private func storeError(_ message: String) -> NSError {
        MacSWError.make(message, domain: "MacSW.LicenseServerStore")
    }
}
