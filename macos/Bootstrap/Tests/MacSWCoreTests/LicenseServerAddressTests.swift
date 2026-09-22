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
        XCTAssertEqual(LicenseServerList.managed(port: 27000).canonical, "27000@localhost")
    }

    /// 启动时只有指向本机的地址才值得顺手把托管服务器拉起来。
    func testLoopbackRecognitionCoversEveryLocalSpelling() {
        XCTAssertTrue(LicenseServerEndpoint(port: 1, host: "localhost").isLoopback)
        XCTAssertTrue(LicenseServerEndpoint(port: 1, host: "LOCALHOST").isLoopback)
        XCTAssertTrue(LicenseServerEndpoint(port: 1, host: "127.0.0.1").isLoopback)
        XCTAssertTrue(LicenseServerEndpoint(port: 1, host: "[::1]").isLoopback)
        XCTAssertFalse(LicenseServerEndpoint(port: 1, host: "license.example").isLoopback)
        XCTAssertFalse(LicenseServerEndpoint(port: 1, host: "notlocalhost").isLoopback)
        XCTAssertFalse(LicenseServerEndpoint(port: 1, host: "10.0.0.5").isLoopback)
    }

    /// 主机名不带空白与控制字符：它会直接进注册表值和命令行。
    func testEmptyHostsPortsAndWhitespaceAreRejected() {
        XCTAssertThrowsError(try LicenseServerAddressService.parse(""))
        XCTAssertThrowsError(try LicenseServerAddressService.parse("   "))
        XCTAssertThrowsError(try LicenseServerAddressService.parse("server"))
        XCTAssertThrowsError(try LicenseServerAddressService.parse("@server"))
        XCTAssertThrowsError(try LicenseServerAddressService.parse("25734@"))
        XCTAssertThrowsError(try LicenseServerAddressService.parse("0@server"))
        XCTAssertThrowsError(try LicenseServerAddressService.parse("99999@server"))
        XCTAssertThrowsError(try LicenseServerAddressService.parse("25734@bad host"))
        XCTAssertThrowsError(try LicenseServerAddressService.parse("25734@a\nb"))
        XCTAssertEqual(try LicenseServerAddressService.parse(" 25734@server ; 27000@backup ").canonical, "25734@server;27000@backup")
        // parseEntry 是列表拆分之内的单条判定，空串同样不能通过。
        XCTAssertThrowsError(try LicenseServerAddressService.parseEntry(""))
        XCTAssertThrowsError(try LicenseServerAddressService.parseEntry("25734@[::"))
    }

    func testEndpointsCompareCaseInsensitivelyAndConsistentlyWithHashing() {
        let upper = LicenseServerEndpoint(port: 27000, host: "BACKUP")
        let lower = LicenseServerEndpoint(port: 27000, host: "backup")
        XCTAssertEqual(upper, lower)
        XCTAssertEqual(Set([upper, lower]).count, 1)
        XCTAssertNotEqual(upper, LicenseServerEndpoint(port: 27001, host: "backup"))
    }
}
