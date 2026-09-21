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
        try fileManager.createDirectory(at: root.appendingPathComponent(relativePath), withIntermediateDirectories: true)
    }

    func testDirectoryNameNeedsBothFlexnetAndServer() {
        XCTAssertTrue(FlexNetLocator.matches("SolidWorks_Flexnet_Server"))
        XCTAssertTrue(FlexNetLocator.matches("SOLIDWORKS FLEXNET SERVER"))
        XCTAssertTrue(FlexNetLocator.matches("FlexNet2Server"))
        XCTAssertFalse(FlexNetLocator.matches("FlexNet"))
        XCTAssertFalse(FlexNetLocator.matches("Server"))
        XCTAssertFalse(FlexNetLocator.matches("crack"))
    }

    func testScansCurrentLevelAndOneLevelOfSubdirectories() throws {
        try makeDirectory("SolidWorks_Flexnet_Server")
        try makeDirectory("crack/SolidWorks_Flexnet_Server")
        let found = FlexNetLocator.discover(in: root, fileManager: fileManager)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found.map(\.lastPathComponent), Array(repeating: "SolidWorks_Flexnet_Server", count: 2))
        XCTAssertTrue(found.contains { $0.path.hasSuffix("/crack/SolidWorks_Flexnet_Server") })
    }

    func testIgnoresDeeperNestingFilesAndHiddenEntries() throws {
        try fileManager.createDirectory(
            at: root.appendingPathComponent("a/b/c/SolidWorks_Flexnet_Server"),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: root.appendingPathComponent("SolidWorks_Flexnet_Server.txt"))
        try makeDirectory(".hidden/SolidWorks_Flexnet_Server")
        XCTAssertTrue(FlexNetLocator.discover(in: root, fileManager: fileManager).isEmpty)
    }
}

final class InstallationMediaResolverTests: XCTestCase {
    private var root: URL!

    /// 临时目录可能带 /var 与 /private/var 两种写法，比较前统一解析符号链接。
    private func real(_ url: URL) -> String { url.resolvingSymlinksInPath().path }
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("MacSW-Resolve-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    @discardableResult
    private func write(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: url)
        return url
    }

    func testIsoFileBecomesIsoMediaScanningItsOwnFolder() throws {
        let iso = try write("media/SolidWorks.iso")
        let resolved = InstallationMediaResolver.resolve(iso, fileManager: fileManager)
        XCTAssertEqual(resolved.map { real($0.displayURL) }, real(iso))
        XCTAssertEqual(resolved.map { real($0.attachmentDirectory) }, real(root.appendingPathComponent("media")))
        XCTAssertTrue(resolved?.isIso == true)
    }

    func testDroppedSetupExeResolvesToItsFolderAndScansTheParent() throws {
        let exe = try write("dvd/setup.exe")
        guard let resolved = InstallationMediaResolver.resolve(exe, fileManager: fileManager) else {
            return XCTFail("setup.exe 应当被识别为介质")
        }
        XCTAssertEqual(real(resolved.mediaDirectory), real(exe.deletingLastPathComponent()))
        XCTAssertFalse(resolved.isIso)
        XCTAssertEqual(real(resolved.attachmentDirectory), real(root))
    }

    func testSelectedFolderWithOwnSetupExeScansItself() throws {
        try write("dvd/setup.exe")
        let selected = root.appendingPathComponent("dvd")
        let resolved = InstallationMediaResolver.resolve(selected, fileManager: fileManager)
        XCTAssertEqual(resolved.map { real($0.mediaDirectory) }, real(selected))
        XCTAssertEqual(resolved.map { real($0.attachmentDirectory) }, real(selected))
    }

    func testNestedSetupExeScansTheChosenFolder() throws {
        try write("chosen/dvd2/setup.exe")
        guard let resolved = InstallationMediaResolver.resolve(root.appendingPathComponent("chosen"), fileManager: fileManager) else {
            return XCTFail("一级子目录内的 setup.exe 应当被识别")
        }
        XCTAssertEqual(resolved.mediaDirectory.lastPathComponent, "dvd2")
        XCTAssertFalse(resolved.attachmentDirectory.lastPathComponent == "dvd2")
    }

    func testIsoInsideSelectedFolderIsUsedWhenNoSetupExeExists() throws {
        let iso = try write("chosen/disc/SolidWorks.iso")
        let resolved = InstallationMediaResolver.resolve(root.appendingPathComponent("chosen"), fileManager: fileManager)
        XCTAssertEqual(resolved.map { real($0.displayURL) }, real(iso))
    }

    func testUnrelatedInputIsRejected() throws {
        let note = try write("nothing/readme.txt")
        XCTAssertNil(InstallationMediaResolver.resolve(note, fileManager: fileManager))
        try fileManager.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        XCTAssertNil(InstallationMediaResolver.resolve(root.appendingPathComponent("empty"), fileManager: fileManager))
    }
}
