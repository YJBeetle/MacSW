import Foundation
import XCTest
@testable import MacSWCore

final class ProcessInventoryTests: XCTestCase {
    private static let bottle = "/Users/dev/Library/Application Support/MacSW/bottle"
    private static let wineRuntime = "/Applications/MacSW.app/Contents/Frameworks/wine"
    private static let sample = """
      PID    RSS ELAPSED COMMAND
      8239 114688   01:23:45 /Applications/MacSW.app/Contents/Frameworks/wine/bin/wineserver -w
      8240  65536   01:23:44 C:\\windows\\system32\\sw_ui_daemon.exe
      8241 192937984 01:23:40 C:\\Program Files\\SOLIDWORKS\\SLDWORKS.exe
      8244 200704   01:23:30 C:\\Program Files\\SOLIDWORKS\\sldworks_fs.exe
      8250   13112  00:10:00 C:\\opt\\FlexNet\\lmgrd.exe -c \(bottle)/drive_c/opt/FlexNet/sw_d_SSQ.lic
      51708  98304  02:00:00 /Applications/MacSW.app/Contents/MacOS/MacSW
      51709  12345  02:00:00 /usr/sbin/httpserver
      """

    private func parsed() -> [WineProcess] {
        ProcessInventory.parse(Self.sample, bottlePath: Self.bottle, wineRuntimePath: Self.wineRuntime)
    }

    func testListsEveryContainerProcessIncludingLicenseDaemons() {
        XCTAssertEqual(Set(parsed().map(\.name)), [
            "wineserver", "sw_ui_daemon.exe", "SLDWORKS.exe", "sldworks_fs.exe", "lmgrd.exe"
        ])
        XCTAssertFalse(parsed().contains { $0.name == "MacSW" })
        XCTAssertFalse(parsed().contains { $0.name == "httpserver" })
    }

    func testSortedByResidentMemoryWithSolidWorksFirst() {
        let processes = parsed()
        XCTAssertEqual(processes.first?.name, "SLDWORKS.exe")
        XCTAssertEqual(processes.first?.pid, 8241)
        XCTAssertEqual(processes.map(\.residentMB), processes.map(\.residentMB).sorted(by: >))
    }

    func testTotalsAndRunningState() {
        let processes = parsed()
        XCTAssertEqual(ProcessInventory.totalResidentMB(processes), processes.reduce(0) { $0 + $1.residentMB })
        XCTAssertTrue(ProcessInventory.isSolidWorksRunning(processes))
        XCTAssertFalse(ProcessInventory.isSolidWorksRunning(
            ProcessInventory.parse("  1 200 00:10:00 C:\\windows\\sw_ui_daemon.exe", bottlePath: "", wineRuntimePath: "")
        ))
    }

    func testDisplayNameSurvivesSpacesInWindowsPaths() {
        XCTAssertEqual(
            ProcessInventory.parse(
                "  1 200 00:10:00 C:\\Program Files\\SOLIDWORKS\\SLDWORKS.exe",
                bottlePath: "", wineRuntimePath: ""
            ).map(\.name),
            ["SLDWORKS.exe"]
        )
        XCTAssertTrue(ProcessInventory.parse("garbage header", bottlePath: Self.bottle, wineRuntimePath: Self.wineRuntime).isEmpty)
    }

    func testElapsedSecondsForTableSorting() {
        func seconds(_ elapsed: String) -> Int {
            WineProcess(name: "x", pid: 1, residentKB: 1, elapsed: elapsed).elapsedSeconds
        }
        XCTAssertEqual(seconds("00:00:45"), 45)
        XCTAssertEqual(seconds("01:23:45"), 5025)
        XCTAssertEqual(seconds("1-02:03:04"), 93_784)
        XCTAssertEqual(seconds("乱码"), 0)
    }

    func testElapsedFormatting() {
        XCTAssertEqual(ProcessInventory.formatElapsed("01:23:45"), "1 小时 23 分")
        XCTAssertEqual(ProcessInventory.formatElapsed("00:05:00"), "5 分")
        XCTAssertEqual(ProcessInventory.formatElapsed("00:00:45"), "不到 1 分")
        XCTAssertEqual(ProcessInventory.formatElapsed("1-02:03:04"), "1 天 2 小时 3 分")
    }
}
