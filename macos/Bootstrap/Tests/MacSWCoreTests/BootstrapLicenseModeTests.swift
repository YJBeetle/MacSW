import XCTest
@testable import MacSWCore

final class BootstrapLicenseModeTests: XCTestCase {
    func testUnconfiguredNeedsNoInput() {
        XCTAssertNil(BootstrapLicenseMode.unconfigured.missingInputMessage(address: " ", flexNetSource: nil))
    }

    func testRemoteServerRequiresParsableAddress() {
        let mode = BootstrapLicenseMode.remoteServer
        XCTAssertNotNil(mode.missingInputMessage(address: "  ", flexNetSource: nil))
        XCTAssertNotNil(mode.missingInputMessage(address: "not-an-address", flexNetSource: nil))
        XCTAssertNil(mode.missingInputMessage(address: " 25734@192.168.1.20 ", flexNetSource: nil))
    }

    func testManagedFlexNetRequiresDirectoryOnly() {
        let mode = BootstrapLicenseMode.managedFlexNet
        XCTAssertNotNil(mode.missingInputMessage(address: "25734@localhost", flexNetSource: nil))
        XCTAssertNil(mode.missingInputMessage(
            address: "25734@localhost",
            flexNetSource: URL(fileURLWithPath: "/tmp/SolidWorks_Flexnet_Server")
        ))
    }
}
