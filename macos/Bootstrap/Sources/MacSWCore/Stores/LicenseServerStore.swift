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

    public func saveAddress() {
        guard normalizeAddressInput() else { return }
        Task {
            isOperating = true
            defer { isOperating = false }
            do {
                if addressInput.isEmpty {
                    try await registry.clearLicenseServers(prefix: paths.bottle)
                    statusMessage = "许可服务器地址已清除。"
                } else {
                    let servers = try LicenseServerAddressService.parse(addressInput)
                    try await registry.writeLicenseServers(servers, prefix: paths.bottle)
                    statusMessage = "许可服务器地址已写入注册表。"
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
                let existing = await registry.readLicenseServers(prefix: paths.bottle)
                let metadata = try await service.install(from: source, existingServers: existing)
                installation = metadata
                addressInput = existing.addingManagedLocal(port: metadata.port).canonical
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
                let existing = await registry.readLicenseServers(prefix: paths.bottle)
                let remaining = try await service.uninstall(existingServers: existing)
                addressInput = remaining.canonical
                installation = nil
                state = .notInstalled
                statusMessage = "托管 FlexNet 已卸载，其他服务器地址已保留。"
            } catch {
                state = .failed(error.localizedDescription)
                statusMessage = error.localizedDescription
            }
        }
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
