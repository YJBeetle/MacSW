import Foundation
import XCTest
@testable import MacSWCore

final class FlexNetServiceTests: XCTestCase {
    private var root: URL!
    private var service: FlexNetService!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("MacSW-flexnet-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        service = FlexNetService(paths: AppPaths(appSupportDirectory: root.appendingPathComponent("support")))
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    @discardableResult
    private func write(_ bytes: [UInt8], as name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    @discardableResult
    private func write(_ text: String, as name: String) throws -> URL {
        try write([UInt8](text.utf8), as: name)
    }

    private func makePackage(license: String = "SERVER this_host ANY 25734\nVENDOR SW_D") throws {
        try write("PE binary", as: "lmgrd.exe")
        try write(license, as: "license.lic")
        try write("PE binary", as: "SW_D.exe")
    }

    func testValidationRequiresExecutableSingleLicensePortAndVendorDaemon() throws {
        XCTAssertThrowsError(try service.inspect(directory: root))
        try write("", as: "lmgrd.exe")
        try write("SERVER this_host ANY 25734\nVENDOR SW_D", as: "license.lic")
        // 0 字节的 lmgrd.exe 不算组件。
        XCTAssertThrowsError(try service.inspect(directory: root))
        try write("PE binary", as: "lmgrd.exe")
        try write("PE binary", as: "SW_D.exe")
        XCTAssertEqual(
            try service.inspect(directory: root),
            ManagedFlexNetInstallation(port: 25734, licenseFile: "license.lic", vendorDaemon: "SW_D.exe")
        )
        try write("SERVER other ANY 25735\nVENDOR SW_D", as: "second.lic")
        XCTAssertThrowsError(try service.inspect(directory: root))
    }

    func testSymlinkedComponentIsRejected() throws {
        try makePackage()
        try fileManager.removeItem(at: root.appendingPathComponent("lmgrd.exe"))
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("lmgrd.exe"),
            withDestinationURL: root.appendingPathComponent("elsewhere.exe")
        )
        // 符号链接指向的东西不算包内组件：拷进容器等于把瓶外的文件搬进瓶子。
        XCTAssertThrowsError(try service.inspect(directory: root))
    }

    func testDirectoryNamedLikeAComponentIsRejected() throws {
        try write("PE", as: "SW_D.exe")
        try write("SERVER this_host ANY 25734\nVENDOR SW_D", as: "license.lic")
        try fileManager.createDirectory(at: root.appendingPathComponent("lmgrd.exe"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try service.inspect(directory: root))
    }

    func testOversizedLicenseFileIsRejected() throws {
        try write("PE", as: "lmgrd.exe")
        try write("PE", as: "SW_D.exe")
        try write([UInt8](repeating: 0x41, count: FlexNetService.maximumLicenseBytes + 1), as: "license.lic")
        XCTAssertThrowsError(try service.inspect(directory: root))
    }

    /// Windows 导出的 .lic 常带非 UTF-8 注释，不能因此把整个可用包判死。
    func testLegacyEncodedLicenseStillParses() throws {
        try write("PE", as: "lmgrd.exe")
        try write("PE", as: "SW_D.exe")
        var bytes = [UInt8]("SERVER this_host ANY 25734\n# ".utf8)
        bytes.append(contentsOf: [0x81, 0xFE])
        bytes.append(contentsOf: "\nVENDOR SW_D".utf8)
        try write(bytes, as: "license.lic")
        XCTAssertEqual(
            try service.inspect(directory: root),
            ManagedFlexNetInstallation(port: 25734, licenseFile: "license.lic", vendorDaemon: "SW_D.exe")
        )
    }

    func testVendorDaemonNamedByLicenseMustExist() throws {
        try makePackage(license: "SERVER this_host ANY 25734\nVENDOR OTHERD")
        XCTAssertThrowsError(try service.inspect(directory: root))
    }
}
