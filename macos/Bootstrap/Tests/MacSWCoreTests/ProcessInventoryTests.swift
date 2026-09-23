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
      8260    4096  00:00:02 \(wineRuntime)/bin/wineloader \(wineRuntime)/bin/wine reg import C:\\windows\\temp\\MacSW-316C1F25.reg
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
        // wine / wineloader 这些宿主侧命令行工具不该出现在容器表里
        XCTAssertFalse(parsed().contains { $0.name.contains("wineloader") || $0.name.contains(".reg") })
    }

    func testFindsOrphanedFlexNetFromAnOlderAppBuildAfterWineserverExit() {
        let output = """
          5212 1024  09:59:13 C:\\opt\\FlexNet\\lmgrd.exe -c \(Self.bottle)/drive_c/opt/FlexNet/sw_d_SSQ.lic
        """
        let processes = ProcessInventory.parse(
            output,
            bottlePath: Self.bottle,
            wineRuntimePath: "/Applications/New-MacSW.app/Contents/Frameworks/wine"
        )
        XCTAssertEqual(processes.map(\.pid), [5212], "旧 lmgrd 即使没有 wineserver 也必须阻止删除容器")
        XCTAssertEqual(processes.first?.name, "lmgrd.exe")
    }

    func testSortedByResidentMemoryWithSolidWorksFirst() {
        let processes = parsed()
        XCTAssertEqual(processes.first?.name, "SLDWORKS.exe")
        XCTAssertEqual(processes.first?.pid, 8241)
        XCTAssertEqual(processes.map(\.residentMB), processes.map(\.residentMB).sorted(by: >))
    }

    func testTotalsAndRunningState() {
        let processes = parsed()
        XCTAssertTrue(ProcessInventory.isSolidWorksRunning(processes))
        XCTAssertFalse(ProcessInventory.isSolidWorksRunning(
            ProcessInventory.parse("  1 200 00:10:00 C:\\windows\\sw_ui_daemon.exe", bottlePath: "", wineRuntimePath: "")
        ))
    }

    /// 合计必须从 KB 换算：逐行向上取整会把两个 600 KB 报成 2 MB。
    func testTotalRoundsOnceInsteadOfPerRow() {
        let small = [
            WineProcess(name: "a.exe", pid: 1, residentKB: 600, elapsed: "00:00:01"),
            WineProcess(name: "b.exe", pid: 2, residentKB: 600, elapsed: "00:00:01")
        ]
        XCTAssertEqual(small.map(\.residentMB), [1, 1])
        XCTAssertEqual(ProcessInventory.totalResidentMB(small), 1)
    }

    /// 容器与 App 都可能装在带空格的路径里，宿主侧 wine 工具仍要认出来。
    func testHostWineToolsAreFilteredEvenWithSpacesInTheRuntimePath() {
        let runtime = "/Applications/My App/wine"
        let command = "  7 100 00:00:01 \(runtime)/bin/wineloader \(runtime)/bin/wine reg import C:\\windows\\temp\\x.reg"
        XCTAssertTrue(ProcessInventory.parse(command, bottlePath: "", wineRuntimePath: runtime).isEmpty)
        XCTAssertEqual(
            ProcessInventory.parse(
                "  8 100 00:00:01 \(runtime)/bin/wineserver -w", bottlePath: "", wineRuntimePath: runtime
            ).map(\.name),
            ["wineserver"]
        )
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
        XCTAssertEqual(seconds("05:23"), 323, "不满一小时 ps 只给 mm:ss")
        XCTAssertEqual(seconds("乱码"), 0)
    }

    func testElapsedFormatting() {
        XCTAssertEqual(ProcessInventory.formatElapsed("01:23:45"), "1 小时 23 分")
        XCTAssertEqual(ProcessInventory.formatElapsed("00:05:00"), "5 分")
        XCTAssertEqual(ProcessInventory.formatElapsed("00:00:45"), "不到 1 分")
        XCTAssertEqual(ProcessInventory.formatElapsed("1-02:03:04"), "1 天 2 小时 3 分")
        XCTAssertEqual(ProcessInventory.formatElapsed("05:23"), "5 分")
        XCTAssertEqual(ProcessInventory.formatElapsed("00:45"), "不到 1 分")
    }
}
