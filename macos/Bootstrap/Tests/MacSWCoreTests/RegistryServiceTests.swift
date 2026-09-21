import Foundation
import XCTest
@testable import MacSWCore

final class RegistryServiceTests: XCTestCase {
    func testRegistryFileUsesFullHiveAndGroupsValuesUnderOneKey() throws {
        let text = try RegistryService.registryFileText([
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

    /// .reg 的行格式装不下含换行的值：必须在生成阶段拒绝，而不是写坏注册表。
    func testValuesWithNewlinesAreRejectedBeforeBeingWritten() {
        let illegal = [RegistryAssignment(key: "HKLM\\SOFTWARE\\X", name: "V", value: "a\nb")]
        XCTAssertThrowsError(try RegistryService.registryFileText(illegal))
        XCTAssertThrowsError(try RegistryService.registryFileText([
            RegistryAssignment(key: "HKLM\\SOFTWARE\\X", name: "V", value: "a\tb")
        ]))
        XCTAssertNoThrow(try RegistryService.registryFileText([
            RegistryAssignment(key: "HKLM\\SOFTWARE\\X", name: "V", value: #"a\b"c"#)
        ]))
    }

    /// 许可地址要覆盖六个值，并且 `Service` 标记每次都写：切出托管时它就是空串。
    func testLicenseAssignmentsCoverEveryValueAndAlwaysStateTheServiceMarker() {
        let servers = LicenseServerList(endpoints: [LicenseServerEndpoint(port: 27000, host: "license.example")])
        let expected = Set(RegistryService.licenseValueTargets.map { "\($0.key)|\($0.name)" })
        let managed = RegistryService.licenseAssignments(servers, serviceName: FlexNetService.serviceName)
        XCTAssertEqual(Set(managed.map { "\($0.key)|\($0.name)" }), expected.union(["\(RegistryService.serviceKey)|Service"]))
        XCTAssertEqual(managed.filter { $0.name != "Service" }.map(\.value).filter { $0 != servers.canonical }.count, 0)
        XCTAssertEqual(managed.first { $0.name == "Service" }?.value, FlexNetService.serviceName)
        let remote = RegistryService.licenseAssignments(servers, serviceName: nil)
        XCTAssertEqual(remote.first { $0.name == "Service" }?.value, "")
    }
}
