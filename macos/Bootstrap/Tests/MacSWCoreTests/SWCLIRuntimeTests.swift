import Foundation
import XCTest
@testable import MacSWCore

final class SWCLIRuntimeTests: XCTestCase {
    func testFreshInstallationCopiesBundledRuntimeIntoBottle() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("MacSW-swcli-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let bundle = root.appendingPathComponent("MacSW.app")
        let source = bundle.appendingPathComponent("Contents/Resources/SWCLI/runtime/Python311")
        let prefix = root.appendingPathComponent("bottle")
        try fileManager.createDirectory(
            at: source.appendingPathComponent("Lib/site-packages/swcli"),
            withIntermediateDirectories: true
        )
        try Data("python".utf8).write(to: source.appendingPathComponent("python.exe"))
        try Data("entrypoint".utf8).write(
            to: source.appendingPathComponent("Lib/site-packages/swcli/__main__.py")
        )

        try PrerequisiteService.prepareSWCLI(bundleURL: bundle, prefix: prefix)

        let target = prefix.appendingPathComponent(PrerequisiteService.swcliDestination)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("python.exe")), Data("python".utf8))
        XCTAssertEqual(
            try Data(contentsOf: target.appendingPathComponent("Lib/site-packages/swcli/__main__.py")),
            Data("entrypoint".utf8)
        )
    }

    func testMissingBundledRuntimeIsRejected() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSW-swcli-missing-\(UUID().uuidString)")
        XCTAssertThrowsError(
            try PrerequisiteService.prepareSWCLI(
                bundleURL: root.appendingPathComponent("MacSW.app"),
                prefix: root.appendingPathComponent("bottle")
            )
        )
    }
}
