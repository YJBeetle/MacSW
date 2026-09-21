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
    @Published public private(set) var appliedMode: BootstrapLicenseMode?
    /// 上一次真正写进注册表的内容，用来判断输入框是否需要再写一次。
    @Published public private(set) var appliedAddress: String?

    public let paths: AppPaths
    private let registry: RegistryService
    private let service: FlexNetService
    private let wine: WineService
    private var launchedProcess: Process?

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
        if installation == nil { state = .notInstalled }
    }

    /// 只探测许可端口（不读注册表、不启动 Wine），供菜单栏面板高频刷新使用。
    public func refreshRunningState() async {
        await refreshInstallation()
        guard let installation else { return }
        state = await isPortOpen(installation.port) ? .running(installation.port) : .stopped
    }

    /// 完整刷新：会读取容器注册表并探测许可端口，只在用户查看状态或需要启动时调用。
    public func refresh() async {
        await refreshInstallation()
        let servers = await registry.readLicenseServers(prefix: paths.bottle)
        addressInput = servers.canonical
        guard let installation else {
            state = .notInstalled
            return
        }
        state = await isPortOpen(installation.port) ? .running(installation.port) : .stopped
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

    /// 单选即生效：把选中的模式写进容器注册表。
    /// 写入期间 isOperating 为真，界面上整块随之锁住并转菊花，
    /// 因此不会出现用户连着切、旧写入盖掉新选择的情况。
    public func apply(mode: BootstrapLicenseMode) {
        guard !isOperating else { return }
        appliedMode = mode
        Task {
            isOperating = true
            defer { isOperating = false }
            do {
                switch mode {
                case .unconfigured:
                    guard !addressInput.isEmpty else { return }
                    try await registry.clearLicenseServers(prefix: paths.bottle)
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

    public func install(from source: URL) {
        guard !isOperating else { return }
        Task {
            isOperating = true
            statusMessage = "正在验证并安装 FlexNet…"
            defer { isOperating = false }
            do {
                let metadata = try await service.install(from: source)
                installation = metadata
                addressInput = metadata.managedAddress
                appliedAddress = metadata.managedAddress
                statusMessage = "FlexNet 已安装到 C:\\opt\\FlexNet。"
                state = .stopped
                try await startAndWait()
            } catch is CancellationError {
                statusMessage = "FlexNet 安装已取消，原有版本保持不变。"
            } catch {
                state = .failed(error.localizedDescription)
                statusMessage = error.localizedDescription
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
        let log = paths.logs.appendingPathComponent("flexnet-launch.log")
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        process.standardOutput = handle
        process.standardError = handle
        process.terminationHandler = { _ in try? handle.close() }
        try process.run()
        launchedProcess = process

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
        let process = wine.makeProcess(arguments: ["taskkill", "/f", "/im", "lmgrd.exe", "/im", "SW_D.exe"], prefix: paths.bottle)
        _ = try await wine.runCancellable(process, log: paths.logs.appendingPathComponent("flexnet-stop.log"))
        launchedProcess = nil
        if let port = installation?.port {
            for _ in 0..<10 {
                if !(await isPortOpen(port)) { break }
                try await Task.sleep(nanoseconds: 300_000_000)
            }
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
        NSError(domain: "MacSW.LicenseServerStore", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
