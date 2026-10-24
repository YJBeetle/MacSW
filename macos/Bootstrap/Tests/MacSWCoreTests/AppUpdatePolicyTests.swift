import XCTest
@testable import MacSWCore

final class AppUpdatePolicyTests: XCTestCase {
    func testMaintenanceBlocksEvenWithoutProcesses() {
        XCTAssertNotNil(AppUpdatePolicy.blockingReason(maintenance: true, processes: []))
        XCTAssertNil(AppUpdatePolicy.blockingReason(maintenance: false, processes: []))
    }

    func testUserClientsNeverGetKilledForAnUpdate() {
        for name in ["SLDWORKS.exe", "sldworks.exe", "sldworks_fs.exe", "python.exe", "notepad.exe", "unknown"] {
            let process = WineProcess(name: name, pid: 1, residentKB: 1, elapsed: "00:01")
            XCTAssertNotNil(AppUpdatePolicy.blockingReason(maintenance: false, processes: [process]), name)
        }
    }

    func testOnlyManagedInfrastructureCanBeStopped() {
        let processes = ["wineserver", "lmgrd.exe", "SW_D.exe"].map {
            WineProcess(name: $0, pid: 1, residentKB: 1, elapsed: "00:01")
        }
        XCTAssertNil(AppUpdatePolicy.blockingReason(maintenance: false, processes: processes))
    }

    func testEdDSAPublicKeyMustBe32Bytes() {
        XCTAssertTrue(AppUpdatePolicy.validPublicKey(Data(repeating: 1, count: 32).base64EncodedString()))
        for value in ["", "placeholder", Data(repeating: 1, count: 64).base64EncodedString()] {
            XCTAssertFalse(AppUpdatePolicy.validPublicKey(value))
        }
        XCTAssertEqual(AppUpdatePolicy.feedURL, "https://github.com/YJBeetle/MacSW/releases/latest/download/appcast.xml")
    }
}
