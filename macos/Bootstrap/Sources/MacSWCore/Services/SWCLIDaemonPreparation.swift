import Foundation

/// The explicit CLI lifecycle entry shares the GUI's existing license preparation.
/// It does not construct RuntimeStore, initialize SwiftUI, install components or start SW.
@MainActor
public enum SWCLIDaemonPreparation {
    public static let argument = "--prepare-swcli-daemon"

    public static func run(
        arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws {
        guard arguments == [argument] else {
            throw MacSWError.make("Unexpected daemon preparation arguments.", domain: "MacSW.SWCLIDaemonPreparation")
        }
        let paths = try resolvePaths(defaultPaths: AppPaths.live(), prefix: environment["MACSW_WINEPREFIX"])
        try await prepare(licenseServer: LicenseServerStore(paths: paths))
    }

    static func resolvePaths(defaultPaths: AppPaths, prefix: String?) throws -> AppPaths {
        guard let prefix, !prefix.isEmpty else { return defaultPaths }
        guard (prefix as NSString).isAbsolutePath else {
            throw MacSWError.make("MACSW_WINEPREFIX must be an absolute bottle path.", domain: "MacSW.SWCLIDaemonPreparation")
        }
        return AppPaths(appSupportDirectory: defaultPaths.appSupportDirectory,
                        bottle: URL(fileURLWithPath: prefix, isDirectory: true))
    }

    static func prepare(licenseServer: any SWCLILicenseServerPreparing) async throws {
        await licenseServer.refreshInstallation()
        // The existing store starts only an installed managed service whose port
        // matches a configured loopback endpoint; remote configuration is preserved.
        try await licenseServer.ensureRunningIfNeeded()
    }
}

@MainActor
protocol SWCLILicenseServerPreparing {
    func refreshInstallation() async
    func ensureRunningIfNeeded() async throws
}

extension LicenseServerStore: SWCLILicenseServerPreparing {}
