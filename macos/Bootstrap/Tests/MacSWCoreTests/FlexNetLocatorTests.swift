import Foundation
import XCTest
@testable import MacSWCore

final class FlexNetLocatorTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("MacSW-FlexNet-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    private func makeDirectory(_ relativePath: String) throws {
        try fileManager.createDirectory(
            at: root.appendingPathComponent(relativePath),
            withIntermediateDirectories: true
        )
    }

    func testDirectoryNameMatchingIsCaseInsensitive() {
        XCTAssertTrue(FlexNetLocator.matches("SolidWorks_Flexnet_Server"))
        XCTAssertTrue(FlexNetLocator.matches("SOLIDWORKS_FLEXNET_SERVER"))
        XCTAssertFalse(FlexNetLocator.matches("FlexNet"))
        XCTAssertFalse(FlexNetLocator.matches("crack"))
    }

    func testFindsSiblingsAndFirstLevelSubdirectories() throws {
        let iso = root.appendingPathComponent("SolidWorks.iso")
        try Data("iso".utf8).write(to: iso)
        try makeDirectory("SolidWorks_Flexnet_Server")
        try makeDirectory("crack/SolidWorks_Flexnet_Server")
        let found = FlexNetLocator.discover(near: iso, fileManager: fileManager)
        XCTAssertEqual(found.map(\.lastPathComponent).sorted(), ["SolidWorks_Flexnet_Server", "SolidWorks_Flexnet_Server"])
        XCTAssertEqual(found.count, 2)
    }

    func testIgnoresDeeperNestingAndFiles() throws {
        let iso = root.appendingPathComponent("SolidWorks.iso")
        try Data("iso".utf8).write(to: iso)
        try fileManager.createDirectory(
            at: root.appendingPathComponent("deep/nested/SolidWorks_Flexnet_Server"),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: root.appendingPathComponent("SolidWorks_Flexnet_Server.txt"))
        XCTAssertTrue(FlexNetLocator.discover(near: iso, fileManager: fileManager).isEmpty)
    }
}
