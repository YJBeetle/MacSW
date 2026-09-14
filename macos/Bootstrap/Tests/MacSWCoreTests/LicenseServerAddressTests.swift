import XCTest
@testable import MacSWCore

final class LicenseServerAddressTests: XCTestCase {
    func testOfficialAndConvenienceFormatsNormalizeToOfficialForm() throws {
        XCTAssertEqual(try LicenseServerAddressService.parse("25734@server").canonical, "25734@server")
        XCTAssertEqual(try LicenseServerAddressService.parse("server:25734").canonical, "25734@server")
        XCTAssertEqual(try LicenseServerAddressService.parse("[2001:db8::1]:25734").canonical, "25734@[2001:db8::1]")
        XCTAssertThrowsError(try LicenseServerAddressService.parse("2001:db8::1:25734")) { error in
            guard case .ambiguousIPv6 = error as? LicenseServerAddressError else {
                return XCTFail("Expected ambiguous IPv6 error, got \(error)")
            }
        }
    }

    func testMultipleServersAreDeduplicatedAndOrderIsPreserved() throws {
        let list = try LicenseServerAddressService.parse("27000@backup;server:25734;27000@BACKUP")
        XCTAssertEqual(list.canonical, "27000@backup;25734@server")
    }

    func testManagedLocalServerIsMergedAndRemovedWithoutChangingOthers() throws {
        let existing = try LicenseServerAddressService.parse("27000@backup;25734@127.0.0.1;28000@other")
        let installed = existing.addingManagedLocal(port: 25734)
        XCTAssertEqual(installed.canonical, "25734@localhost;27000@backup;28000@other")
        XCTAssertEqual(installed.removingManagedLocal(port: 25734).canonical, "27000@backup;28000@other")
    }
}
