import Foundation
import XCTest
@testable import MacSWCore

@MainActor
final class BootstrapStoreFlexNetCheckTests: XCTestCase {
    private var sandbox: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        sandbox = fileManager.temporaryDirectory.appendingPathComponent("MacSW-flexnet-check-\(UUID().uuidString)")
        try fileManager.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: sandbox)
    }

    private func makeStore() -> BootstrapStore {
        let store = BootstrapStore(paths: AppPaths(appSupportDirectory: sandbox.appendingPathComponent("support")))
        // 关掉静默安装，序列号不再参与校验，只看许可输入。
        store.silentInstall = false
        store.licenseMode = .managedFlexNet
        return store
    }

    private func settle(_ store: BootstrapStore) async {
        for _ in 0..<200 {
            guard case .checking = store.flexNetCheck else { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("FlexNet 校验没有在预期时间内结束")
    }

    func testInvalidFolderReportsWhyImmediatelyAndBlocksStart() async {
        let empty = sandbox.appendingPathComponent("随便一个目录")
        try? fileManager.createDirectory(at: empty, withIntermediateDirectories: true)
        let store = makeStore()

        store.chooseFlexNetDirectory(empty)
        await settle(store)

        guard case .rejected(let reason) = store.flexNetCheck else {
            return XCTFail("应当立即判为不可用，实际为 \(store.flexNetCheck)")
        }
        XCTAssertTrue(reason.contains("lmgrd.exe"), reason)
        XCTAssertEqual(store.startHint, reason)
    }

    func testValidPackageReportsPortAndDaemon() async throws {
        let package = sandbox.appendingPathComponent("SolidWorks_Flexnet_Server")
        try fileManager.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: package.appendingPathComponent("lmgrd.exe"))
        try Data("MZ".utf8).write(to: package.appendingPathComponent("SW_D.exe"))
        try "SERVER this_host ANY 25734\nVENDOR SW_D\n".write(
            to: package.appendingPathComponent("sw_d_SSQ.lic"), atomically: true, encoding: .utf8
        )
        let store = makeStore()

        store.chooseFlexNetDirectory(package)
        await settle(store)

        XCTAssertEqual(
            store.flexNetCheck,
            .ready(ManagedFlexNetInstallation(port: 25734, licenseFile: "sw_d_SSQ.lic", vendorDaemon: "SW_D.exe"))
        )
        XCTAssertNil(store.startHint)
    }
}
