import Foundation
import XCTest
@testable import MacSWCore

final class AppPathsInstallationCacheTests: XCTestCase {
    private var bottle: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        bottle = fileManager.temporaryDirectory.appendingPathComponent("MacSW-Paths-\(UUID().uuidString)")
        try fileManager.createDirectory(at: bottle, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        AppPaths.invalidateInstallationState()
        try? fileManager.removeItem(at: bottle)
    }

    func testResolutionIsCachedUntilInstallationStateIsInvalidated() throws {
        let cached = AppPaths.resolveSolidWorksExecutable(in: bottle)
        let installed = bottle.appendingPathComponent("drive_c/Program Files/SOLIDWORKS/SLDWORKS.exe")
        try fileManager.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("exe".utf8).write(to: installed)

        XCTAssertEqual(AppPaths.resolveSolidWorksExecutable(in: bottle), cached, "第二次解析应命中缓存")

        AppPaths.invalidateInstallationState()
        XCTAssertEqual(AppPaths.resolveSolidWorksExecutable(in: bottle), installed, "失效后应重新解析到新路径")
    }
}
