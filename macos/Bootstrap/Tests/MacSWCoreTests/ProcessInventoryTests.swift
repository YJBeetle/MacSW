import Foundation
import XCTest
@testable import MacSWCore

final class ProcessInventoryTests: XCTestCase {
    private let sample = """
      PID    RSS ELAPSED COMMAND
      8239 114688   01:23:45 /Volumes/Data/Workspace/MacSW/build/app/MacSW.app/Contents/Frameworks/wine/bin/wineserver -w
      8240  65536   01:23:44 C:\\windows\\system32\\sw_ui_daemon.exe WINELOADER=/x
      8241 192937984 01:23:40 C:\\Program Files\\SOLIDWORKS\\SLDWORKS.exe
      8244 200704   01:23:30 C:\\Program Files\\SOLIDWORKS\\sldworks_fs.exe
      51708  98304   02:00:00 /Volumes/Data/Workspace/MacSW/build/app/MacSW.app/Contents/MacOS/MacSW
      """

    func testSnapshotPicksOnlyContainerProcessesInDeclaredOrder() {
        let processes = ProcessInventory.parse(sample)
        XCTAssertEqual(processes.map(\.name), [
            "SLDWORKS.exe", "sldworks_fs.exe", "sw_ui_daemon.exe", "wineserver"
        ])
        XCTAssertEqual(processes.first?.pid, 8241)
        XCTAssertEqual(processes.first?.residentMB, 188416)
        XCTAssertFalse(processes.contains { $0.name == "MacSW" })
    }

    func testTotalsAndRunningState() {
        let processes = ProcessInventory.parse(sample)
        XCTAssertEqual(ProcessInventory.totalResidentMB(processes), 188416 + 196 + 64 + 112)
        XCTAssertTrue(ProcessInventory.isSolidWorksRunning(processes))
        XCTAssertFalse(ProcessInventory.isSolidWorksRunning(
            ProcessInventory.parse("  1 200 00:10:00 C:\\windows\\sw_ui_daemon.exe")
        ))
        XCTAssertTrue(ProcessInventory.parse("garbage header").isEmpty)
    }

    func testElapsedFormatting() {
        XCTAssertEqual(ProcessInventory.formatElapsed("01:23:45"), "1 小时 23 分")
        XCTAssertEqual(ProcessInventory.formatElapsed("00:05:00"), "5 分")
        XCTAssertEqual(ProcessInventory.formatElapsed("00:00:45"), "不到 1 分")
        XCTAssertEqual(ProcessInventory.formatElapsed("1-02:03:04"), "1 天 2 小时 3 分")
    }
}
