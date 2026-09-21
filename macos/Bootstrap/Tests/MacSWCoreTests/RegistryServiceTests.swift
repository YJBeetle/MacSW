import Foundation
import XCTest
@testable import MacSWCore

final class RegistryServiceTests: XCTestCase {
    func testRegistryFileUsesFullHiveAndGroupsValuesUnderOneKey() {
        let text = RegistryService.registryFileText([
            RegistryAssignment(key: "HKLM\\SOFTWARE\\FLEXlm License Manager", name: "SW_D_LICENSE_FILE", value: "25734@localhost"),
            RegistryAssignment(key: "HKCU\\Software\\FLEXlm License Manager", name: "SW_D_LICENSE_FILE", value: "25734@localhost"),
            RegistryAssignment(key: "HKLM\\SOFTWARE\\FLEXlm License Manager", name: "SOLIDWORKS_LICENSE_FILE", value: "27000@x")
        ])
        let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.first, "Windows Registry Editor Version 5.00")
        XCTAssertEqual(text.components(separatedBy: "[HKEY_LOCAL_MACHINE").count - 1, 1)
        XCTAssertTrue(text.contains("[HKEY_LOCAL_MACHINE\\SOFTWARE\\FLEXlm License Manager]"))
        XCTAssertTrue(text.contains("[HKEY_CURRENT_USER\\Software\\FLEXlm License Manager]"))
        XCTAssertTrue(text.contains("\"SOLIDWORKS_LICENSE_FILE\"=\"27000@x\""))
        // 同键下的值按名称排序，写入结果可预期
        let lmSection = text.components(separatedBy: "[HKEY_LOCAL_MACHINE\\SOFTWARE\\FLEXlm License Manager]")[1]
        XCTAssertTrue(lmSection.range(of: "SOLIDWORKS_LICENSE_FILE")!.lowerBound
            < lmSection.range(of: "SW_D_LICENSE_FILE")!.lowerBound)
    }

    func testEscapingKeepsBackslashesAndQuotesInsideOneValue() {
        XCTAssertEqual(RegistryService.escape(#"a\b"c"#), #"a\\b\"c"#)
    }
}
