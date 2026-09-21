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

    func testManagedInstallationOwnsTheListWithASingleLoopbackAddress() {
        let metadata = ManagedFlexNetInstallation(port: 25734, licenseFile: "sw_d_SSQ.lic", vendorDaemon: "sw_d.exe")
        XCTAssertEqual(metadata.managedAddress, "25734@localhost")
        XCTAssertEqual(LicenseServerList(endpoints: [LicenseServerEndpoint(port: 25734, host: "localhost")]).canonical, "25734@localhost")
    }
}
