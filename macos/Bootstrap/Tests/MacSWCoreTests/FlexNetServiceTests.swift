import Foundation
import XCTest
@testable import MacSWCore

final class FlexNetServiceTests: XCTestCase {
    func testValidationRequiresExecutableSingleLicensePortAndVendorDaemon() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSW-flexnet-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = AppPaths(appSupportDirectory: root.appendingPathComponent("support"))
        let service = FlexNetService(paths: paths)

        XCTAssertThrowsError(try service.inspect(directory: root))
        try Data().write(to: root.appendingPathComponent("lmgrd.exe"))
        try "SERVER this_host ANY 25734\nVENDOR SW_D".write(
            to: root.appendingPathComponent("license.lic"), atomically: true, encoding: .utf8
        )
        XCTAssertThrowsError(try service.inspect(directory: root))
        try Data().write(to: root.appendingPathComponent("SW_D.exe"))
        XCTAssertEqual(
            try service.inspect(directory: root),
            ManagedFlexNetInstallation(port: 25734, licenseFile: "license.lic", vendorDaemon: "SW_D.exe")
        )
        try Data().write(to: root.appendingPathComponent("second.lic"))
        XCTAssertThrowsError(try service.inspect(directory: root))
    }
}
