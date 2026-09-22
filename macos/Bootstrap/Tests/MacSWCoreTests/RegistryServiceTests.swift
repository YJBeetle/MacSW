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
        XCTAssertNoThrow(try RegistryService.registryFileText([
            RegistryAssignment(key: "HKLM\\SOFTWARE\\X", name: "V", value: "")
        ]))
        XCTAssertThrowsError(try RegistryService.registryFileText([
            RegistryAssignment(key: "HKLM\\SOFTWARE\\X", name: "V", multiStringValues: [])
        ]))
    }

    func testMultiStringValuesUseWineByteEncodingWithDoubleTerminator() throws {
        let assignment = RegistryAssignment(
            key: "HKLM\\SOFTWARE\\X",
            name: "Tahoma",
            multiStringValues: ["a.ttf,A", "b.otf,B"]
        )
        let text = try RegistryService.registryFileText([assignment])
        XCTAssertTrue(text.contains(
            #""Tahoma"=hex(7):61,2e,74,74,66,2c,41,00,62,2e,6f,74,66,2c,42,00,00"#
        ))
        XCTAssertThrowsError(try RegistryService.registryFileText([
            RegistryAssignment(key: "HKLM\\SOFTWARE\\X", name: "V", multiStringValues: ["中文"])
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

    func testManagedFontAssignmentsRegisterFilesAndLinkCommonUIFontFamilies() throws {
        let assignments = RegistryService.managedFontAssignments
        XCTAssertEqual(
            assignments.first { $0.name == "Noto Sans SC Regular (OpenType)" }?.value,
            PrerequisiteService.notoSansSCRegularName
        )
        XCTAssertEqual(
            assignments.first { $0.name == "Noto Sans SC Bold (OpenType)" }?.value,
            PrerequisiteService.notoSansSCBoldName
        )
        for alias in ["MS Shell Dlg", "MS Shell Dlg 2", "Microsoft Sans Serif", "Microsoft YaHei UI", "Segoe UI"] {
            let substitute = try XCTUnwrap(assignments.first { $0.name == alias })
            XCTAssertEqual(substitute.valueKind, .string)
            XCTAssertEqual(substitute.value, "Tahoma")
        }
        for alias in ["NSimSun", "SimSun", "Tahoma"] {
            let link = try XCTUnwrap(assignments.first { $0.name == alias })
            XCTAssertEqual(link.valueKind, .multiString)
            XCTAssertEqual(link.value, "NotoSansSC-Regular.otf,Noto Sans SC")
        }
        XCTAssertNil(assignments.first { $0.name == "System" })
    }
}
