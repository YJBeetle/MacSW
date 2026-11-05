import Foundation
import XCTest
@testable import MacSWCore

@MainActor
final class SWCLIDaemonPreparationTests: XCTestCase {
    private final class LicensePreparation: SWCLILicenseServerPreparing {
        var calls: [String] = []
        var failure: Error?
        func refreshInstallation() async { calls.append("refresh") }
        func ensureRunningIfNeeded() async throws {
            calls.append("ensure")
            if let failure { throw failure }
        }
    }

    func testRefreshesInstalledManifestBeforeExistingConditionalStart() async throws {
        let license = LicensePreparation()
        try await SWCLIDaemonPreparation.prepare(licenseServer: license)
        XCTAssertEqual(license.calls, ["refresh", "ensure"])
    }

    func testPreparationFailureIsPropagatedWithoutAnotherStart() async {
        let license = LicensePreparation()
        license.failure = NSError(domain: "prepare-test", code: 42)
        do {
            try await SWCLIDaemonPreparation.prepare(licenseServer: license)
            XCTFail("startup must reject a failed prerequisite")
        } catch {
            XCTAssertEqual((error as NSError).domain, "prepare-test")
            XCTAssertEqual((error as NSError).code, 42)
        }
        XCTAssertEqual(license.calls, ["refresh", "ensure"])
    }

    func testUninstalledBottleDoesNotInitializeWineOrInstallLicenseService() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-headless-missing-\(UUID().uuidString)")
        let paths = AppPaths(appSupportDirectory: root)
        let store = LicenseServerStore(paths: paths)
        try await SWCLIDaemonPreparation.prepare(licenseServer: store)
        XCTAssertFalse(store.isInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testExplicitBottleUsesTheExactUtilityPrefixAndDefaultLogs() throws {
        let defaults = AppPaths(appSupportDirectory: URL(fileURLWithPath: "/tmp/default-support"))
        let custom = URL(fileURLWithPath: "/tmp/a custom bottle")
        let paths = try SWCLIDaemonPreparation.resolvePaths(defaultPaths: defaults, prefix: custom.path)
        XCTAssertEqual(paths.bottle.path, custom.path)
        XCTAssertEqual(paths.managedFlexNet.path, custom.appendingPathComponent(AppPaths.managedFlexNetRelativePath).path)
        XCTAssertEqual(paths.logs, defaults.logs)
        XCTAssertEqual(try SWCLIDaemonPreparation.resolvePaths(defaultPaths: defaults, prefix: nil).bottle,
                       defaults.bottle)
        XCTAssertThrowsError(try SWCLIDaemonPreparation.resolvePaths(defaultPaths: defaults, prefix: "relative/bottle"))
    }

    func testUnexpectedArgumentsFailBeforePreparingAnyBottle() async {
        do {
            try await SWCLIDaemonPreparation.run(arguments: [SWCLIDaemonPreparation.argument, "--install"])
            XCTFail("unsupported preparation requests must not launch the UI or runtime")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Unexpected"))
        }
    }
}
