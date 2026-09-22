import Foundation
import XCTest
@testable import MacSWCore

@MainActor
final class BootstrapStoreLifecycleTests: XCTestCase {
    private var sandbox: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        sandbox = fileManager.temporaryDirectory.appendingPathComponent("MacSW-bootstrap-lifecycle-\(UUID().uuidString)")
        try fileManager.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: sandbox)
    }

    private func media(named name: String, serial: String? = nil) throws -> URL {
        let directory = sandbox.appendingPathComponent(name)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: directory.appendingPathComponent("setup.exe"))
        if let serial {
            try "SolidWorks \(serial)\n".write(
                to: directory.appendingPathComponent("serials.txt"),
                atomically: true,
                encoding: .utf8
            )
        }
        return directory
    }

    private func waitForInspection(_ store: BootstrapStore) async {
        for _ in 0..<200 {
            if !store.isInspectingMedia { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("介质扫描没有在预期时间内结束")
    }

    func testChangingMediaReplacesOnlyPreviouslyAutoDiscoveredSerials() async throws {
        let first = try media(named: "first", serial: "1111 1111 1111 1111 1111 1111")
        let second = try media(named: "second", serial: "2222 2222 2222 2222 2222 2222")
        let store = BootstrapStore(paths: AppPaths(appSupportDirectory: sandbox.appendingPathComponent("support")))

        store.selectMedia(first)
        await waitForInspection(store)
        XCTAssertEqual(store.serialSolidWorks, "1111 1111 1111 1111 1111 1111")

        store.selectMedia(second)
        await waitForInspection(store)
        XCTAssertEqual(store.serialSolidWorks, "2222 2222 2222 2222 2222 2222")
        XCTAssertEqual(store.serialSources[.solidWorks]?.lastPathComponent, "serials.txt")

        store.serialSolidWorks = "3333 3333 3333 3333 3333 3333"
        store.selectMedia(first)
        await waitForInspection(store)
        XCTAssertEqual(store.serialSolidWorks, "3333 3333 3333 3333 3333 3333")
        XCTAssertNil(store.serialSources[.solidWorks], "手工值不能冒充成新介质自动发现的值")
    }

    func testInvalidSelectionCancelsInspectionStateImmediately() throws {
        let store = BootstrapStore(paths: AppPaths(appSupportDirectory: sandbox.appendingPathComponent("support")))
        store.selectMedia(try media(named: "valid"))
        store.selectMedia(sandbox.appendingPathComponent("missing"))

        XCTAssertFalse(store.isInspectingMedia)
        XCTAssertNil(store.resolvedMedia)
        XCTAssertNil(store.selectedMedia)
    }

    func testStartClaimsInstallationBeforeSchedulingTask() async throws {
        let store = BootstrapStore(paths: AppPaths(appSupportDirectory: sandbox.appendingPathComponent("support")))
        store.silentInstall = false
        store.selectMedia(try media(named: "install"))
        await waitForInspection(store)
        XCTAssertTrue(store.canStart)

        store.start()
        let firstGeneration = try XCTUnwrap(store.installationGeneration)
        XCTAssertEqual(store.state, .preparing)

        store.start()
        XCTAssertEqual(store.installationGeneration, firstGeneration)
        store.cancel()
    }
}
