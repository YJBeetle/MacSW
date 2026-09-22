import Foundation
import XCTest
@testable import MacSWCore

final class RegistryServiceTests: XCTestCase {
    func testLicenseServerQueryDistinguishesMissingValueFromFailures() throws {
        XCTAssertTrue(try RegistryService.licenseServers(fromQueryStatus: 1, output: "").endpoints.isEmpty)
        XCTAssertThrowsError(try RegistryService.licenseServers(fromQueryStatus: 2, output: "failed"))
        XCTAssertThrowsError(try RegistryService.licenseServers(fromQueryStatus: 0, output: "unexpected"))
        XCTAssertThrowsError(try RegistryService.licenseServers(
            fromQueryStatus: 0,
            output: "SW_D_LICENSE_FILE    REG_SZ    not-a-server"
        ))
        XCTAssertEqual(
            try RegistryService.licenseServers(
                fromQueryStatus: 0,
                output: "SW_D_LICENSE_FILE    REG_SZ    25734@localhost"
            ).canonical,
            "25734@localhost"
        )
    }

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

    /// HKCR/HKCU/HKLM 都要展开成 .reg 认识的完整根名，已经是全名的不重复加工。
    func testFullHiveExpandsShortRootsAndLeavesLongOnesAlone() {
        XCTAssertEqual(RegistryService.fullHive(#"HKCU\Software\X"#), #"HKEY_CURRENT_USER\Software\X"#)
        XCTAssertEqual(RegistryService.fullHive(#"HKLM\SOFTWARE"#), #"HKEY_LOCAL_MACHINE\SOFTWARE"#)
        XCTAssertEqual(RegistryService.fullHive(#"HKEY_CLASSES_ROOT\SldWorks.Application"#), #"HKEY_CLASSES_ROOT\SldWorks.Application"#)
        // 没见过的短写保持原样：.reg 会自己报错，比在这里猜一个根更安全。
        XCTAssertEqual(RegistryService.fullHive(#"HKCU\Software\X"#).hasPrefix("HKEY_"), true)
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

    /// SOLIDWORKS 的输入捕获与 MDI 标题按钮外观是同一批安装期兼容设置，
    /// 必须一次写齐；日常启动不再负责补写或迁移。
    func testSolidWorksCompatibilityAssignmentsCoverInputAndCaptionAppearance() {
        XCTAssertEqual(RegistryService.solidWorksCompatibilityAssignments, [
            RegistryAssignment(
                key: "HKCU\\Software\\Microsoft\\Windows NT\\CurrentVersion\\AppCompatFlags\\Layers",
                name: "sldworks.exe",
                value: "WINE_NOCAPTURERESEND"
            ),
            RegistryAssignment(
                key: "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\ThemeManager",
                name: "ThemeActive",
                value: "0"
            )
        ])
    }

    func testWineFontRegistryQueriesAndAppleAssignments() throws {
        let fontOutput = """
        HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts
            苹方-简 常规体 (TrueType)    REG_SZ    Z:\\System\\Library\\AssetsV2\\PingFang.ttc
        """
        let linksOutput = """
        HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontLink\\SystemLink
            Tahoma    REG_MULTI_SZ    tahoma.ttf\\0meiryo.ttc,Meiryo\\0simsun.ttc,SimSun
        """
        XCTAssertEqual(
            RegistryService.registeredPingFangFileName(fromQueryStatus: 0, output: fontOutput),
            "PingFang.ttc"
        )
        XCTAssertNil(RegistryService.registeredPingFangFileName(fromQueryStatus: 1, output: fontOutput))
        XCTAssertNil(RegistryService.registeredPingFangFileName(
            fromQueryStatus: 0,
            output: fontOutput.replacingOccurrences(of: "PingFang.ttc", with: "PingFangUI.bad")
        ))
        let links = try XCTUnwrap(RegistryService.tahomaLinks(fromQueryStatus: 0, output: linksOutput))
        XCTAssertEqual(links, ["tahoma.ttf", "meiryo.ttc,Meiryo", "simsun.ttc,SimSun"])
        let assignments = RegistryService.appleFontAssignments(fileName: "PingFang.ttc", existingTahomaLinks: links)
        XCTAssertEqual(assignments.first(where: { $0.name == "Tahoma" })?.valueKind, .multiString)
        XCTAssertEqual(assignments.first(where: { $0.name == "Tahoma" })?.value.components(separatedBy: "\0"),
                       ["PingFang.ttc,PingFang SC"] + links)
        XCTAssertEqual(assignments.first(where: { $0.name == "SimSun" })?.value, "Tahoma")
        XCTAssertEqual(assignments.first(where: { $0.name == "Microsoft YaHei" })?.value, "Tahoma")
        XCTAssertFalse(assignments.contains(where: { $0.name == "Tahoma" && $0.valueKind == .string }))
    }

    func testRegistryFileUsesUTF16LEForChineseNamesAndMultiStringValues() throws {
        let text = try RegistryService.registryFileText([
            RegistryAssignment(key: #"HKLM\Software\Test"#, name: "Tahoma",
                               multiStringValues: ["PingFang.ttc,PingFang SC", "tahoma.ttf"])
        ])
        XCTAssertTrue(text.contains(#""Tahoma"=hex(7):50,00,69,00,6e,00,67,00"#))
        XCTAssertTrue(text.contains("74,00,61,00,68,00,6f,00,6d,00,61,00,2e,00,74,00,74,00,66,00,00,00,00,00"))
        let data = try RegistryService.registryFileData([
            RegistryAssignment(key: #"HKLM\Software\Test"#, name: "宋体", value: "Tahoma")
        ])
        XCTAssertEqual(Array(data.prefix(2)), [0xff, 0xfe])
        XCTAssertTrue(String(data: data.dropFirst(2), encoding: .utf16LittleEndian)?
            .contains(#""宋体"="Tahoma""#) == true)
        XCTAssertThrowsError(try RegistryService.registryFileText([
            RegistryAssignment(key: #"HKLM\Software\Test"#, name: "Tahoma", multiStringValues: [""])
        ]))
        XCTAssertNoThrow(try RegistryService.registryFileText([
            RegistryAssignment(key: #"HKLM\Software\Test"#, name: "Tahoma", multiStringValues: ["苹方-简"])
        ]))
    }
}
