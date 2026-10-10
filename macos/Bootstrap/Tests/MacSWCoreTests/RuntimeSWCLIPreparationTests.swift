import Foundation
import XCTest
@testable import MacSWCore

@MainActor
final class RuntimeSWCLIPreparationTests: XCTestCase {
    private actor Calls {
        var count = 0
        func record() { count += 1 }
    }

    private func installedPaths() throws -> AppPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-sync-startup-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(appSupportDirectory: root)
        let executable = paths.bottle.appendingPathComponent("drive_c/Program Files/SOLIDWORKS Corp/SOLIDWORKS/SLDWORKS.exe")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: executable)
        return paths
    }

    func testStartupPreparesBackendWithoutAutoLaunchingSolidWorks() async throws {
        let paths = try installedPaths()
        let calls = Calls()
        let store = RuntimeStore(paths: paths, licenseServer: LicenseServerStore(paths: paths),
                                 fontLinkRepair: { _ in }, swcliPreparation: { prefix in
            XCTAssertEqual(prefix, paths.bottle)
            await calls.record()
        })
        await store.startup(autoLaunch: false)
        try await store.ensureSWCLIPrepared()
        let count = await calls.count
        XCTAssertEqual(count, 1)
        XCTAssertFalse(store.isRunning)
    }

    func testFailureIsVisibleAndCanBeRetriedAfterDaemonStops() async throws {
        let paths = try installedPaths()
        let calls = Calls()
        let store = RuntimeStore(paths: paths, licenseServer: LicenseServerStore(paths: paths),
                                 fontLinkRepair: { _ in }, swcliPreparation: { _ in
            await calls.record()
            if await calls.count == 1 {
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "daemon stop"])
            }
        })
        await store.startup(autoLaunch: false)
        XCTAssertTrue(store.statusMessage.contains("daemon stop"))
        try await store.ensureSWCLIPrepared()
        let count = await calls.count
        XCTAssertEqual(count, 2)
    }

    func testMissingBottleDoesNotDeployOrInitializeWine() async {
        let paths = AppPaths(appSupportDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSW-sync-missing-\(UUID().uuidString)"))
        let calls = Calls()
        let store = RuntimeStore(paths: paths, licenseServer: LicenseServerStore(paths: paths),
                                 fontLinkRepair: { _ in }, swcliPreparation: { _ in await calls.record() })
        await store.startup(autoLaunch: false)
        let count = await calls.count
        XCTAssertEqual(count, 0)
        XCTAssertFalse(paths.bottleExists)
    }

    func testDeletionWaitsForBackendPreparationAndBlocksNewTasks() async throws {
        let paths = try installedPaths()
        let calls = Calls()
        let store = RuntimeStore(paths: paths, licenseServer: LicenseServerStore(paths: paths),
                                 fontLinkRepair: { _ in }, swcliPreparation: { _ in
            await calls.record()
            try await Task.sleep(nanoseconds: 20_000_000)
            await calls.record()
        })
        let preparation = Task { try await store.ensureSWCLIPrepared() }
        while await calls.count == 0 { await Task.yield() }
        await store.suspendFontPreparationForBottleDeletion()
        try await preparation.value
        let count = await calls.count
        XCTAssertEqual(count, 2)
        do {
            try await store.ensureSWCLIPrepared()
            XCTFail("deletion must suspend new deployments")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("容器正在清理"))
        }
    }
}
