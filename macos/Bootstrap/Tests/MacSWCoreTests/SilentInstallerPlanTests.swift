import Foundation
import XCTest
@testable import MacSWCore

final class SilentInstallerPlanTests: XCTestCase {
    func testCoreArgumentsRunTheOfficialMSIQuietlyWithValidatedFeatureTree() {
        var serials = InstallSerials()
        serials[.solidWorks] = "1111 2222 3333 4444 5555 6666"
        let arguments = SilentInstallerPlan.coreInstallArguments(
            msi: URL(fileURLWithPath: "/media/swwi/data/solidworks.msi"),
            log: URL(fileURLWithPath: "/logs/install_msi.log"),
            serials: serials
        )
        XCTAssertEqual(arguments.prefix(8), [
            "msiexec", "/i", "/media/swwi/data/solidworks.msi", "/qb", "/norestart",
            "DISABLEROLLBACK=1", "/l*v", "/logs/install_msi.log"
        ])
        XCTAssertTrue(arguments.contains("INSTALLLEVEL=100"))
        XCTAssertTrue(arguments.contains(
            "ADDLOCAL=SolidWorks,ProgramFiles,i386_ProgramFiles,i386_ThirdPtyFiles,i386_DCubeFiles,i386_SWFiles,i386_VistaFiles"
        ))
        XCTAssertTrue(arguments.contains("TOOLBOXFOLDER=C:\\SWData"))
        XCTAssertTrue(arguments.contains("SOLIDWORKSSERIALNUMBER=111122223333444455556666"))
    }

    func testLanguageArgumentsCarryNoCoreFeatureSelection() {
        let arguments = SilentInstallerPlan.languageInstallArguments(
            msi: URL(fileURLWithPath: "/media/swwi/lang/chinese-simplified/chinese-simplified.msi"),
            log: URL(fileURLWithPath: "/logs/language.log")
        )
        XCTAssertFalse(arguments.contains { $0.hasPrefix("ADDLOCAL") })
        XCTAssertFalse(arguments.contains { $0.hasPrefix("INSTALLLEVEL") })
        XCTAssertEqual(arguments.count, 8)
    }
}

final class InstallationMediaTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("MacSW-Media-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    private func write(_ relativePath: String, contents: String = "payload") throws {
        let url = root.appendingPathComponent(relativePath)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func completeMedia() throws {
        for component in InstallationMedia.requiredComponents {
            try write(component.relativePath)
        }
        try write("Toolbox/ToolboxUpdates.zip")
    }

    func testCompleteMediaReportsNothingMissing() throws {
        try completeMedia()
        XCTAssertTrue(InstallationMedia.missingComponents(in: root, language: nil).isEmpty)
    }

    func testEmptyFileCountsAsMissing() throws {
        try write("swwi/data/solidworks.msi", contents: "")
        for component in InstallationMedia.requiredComponents.dropFirst() { try write(component.relativePath) }
        try write("Toolbox/ToolboxUpdates.zip")
        XCTAssertEqual(
            InstallationMedia.missingComponents(in: root, language: nil),
            [InstallationMedia.Component(
                relativePath: "swwi/data/solidworks.msi",
                label: "SOLIDWORKS 主 MSI"
            )]
        )
    }

    func testDirectoryInPlaceOfMSICountsAsMissing() throws {
        try fileManager.createDirectory(
            at: root.appendingPathComponent("swwi/data/solidworks.msi"),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(InstallationMedia.missingComponents(in: root, language: nil).contains {
            $0.relativePath == "swwi/data/solidworks.msi"
        })
    }

    func testMissingToolboxPayloadIsReported() throws {
        try completeMedia()
        try fileManager.removeItem(at: root.appendingPathComponent("Toolbox/ToolboxUpdates.zip"))
        try fileManager.createDirectory(at: root.appendingPathComponent("Toolbox/empty.zip"), withIntermediateDirectories: true)
        XCTAssertEqual(InstallationMedia.missingComponents(in: root, language: nil).map(\.relativePath), ["Toolbox"])
    }

    func testSelectedLanguageMSIIsVerifiedAgainstMedia() throws {
        try completeMedia()
        let language = SolidWorksLanguage(
            directoryName: "chinese-simplified",
            msiFileName: "chinese-simplified.msi",
            displayName: "简体中文"
        )
        XCTAssertEqual(
            InstallationMedia.missingComponents(in: root, language: language).map(\.relativePath),
            ["swwi/lang/chinese-simplified/chinese-simplified.msi"]
        )
        try write("swwi/lang/chinese-simplified/chinese-simplified.msi")
        XCTAssertTrue(InstallationMedia.missingComponents(in: root, language: language).isEmpty)
    }
}

final class InstallerDiagnosticsTests: XCTestCase {
    func testErrorSummaryKeepsMSIFailureLines() {
        let log = """
        Action 0:00:12. WriteToolboxStandardsXML.
        SW MESSAGE|ERROR|0|1603|||Error 1639. invalid command line argument
        Info 1603. Source file not found: somecab.cab
        Property(S): cannot find the requested registry value
        Out of scope chatter about nothing.
        """
        let summary = InstallerDiagnostics.msiErrorSummary(log)
        XCTAssertEqual(summary.count, 3)
        XCTAssertTrue(summary[0].hasPrefix("SW MESSAGE|ERROR|"))
    }

    func testErrorSummaryNeverLeaksSerialNumbersOrLicenseServers() {
        let log = """
        Property(S): SOLIDWORKSSERIALNUMBER = AAAA BBBB CCCC DDDD EEEE FFFF cannot find
        Property(S): SERVERLIST = 25734@localhost Error 1639
        """
        XCTAssertTrue(InstallerDiagnostics.msiErrorSummary(log).isEmpty)
    }

    func testMissingRequirementsAreCaseInsensitive() {
        let output = #"InprocServer32    REG_SZ    mscoree.dll\nClass    REG_SZ    sldLoginManager.LoginManager"#
        XCTAssertEqual(
            InstallerDiagnostics.missingRequirements(
                output: output.uppercased(),
                required: InstallerDiagnostics.loginManagerRequirements
            ),
            ["sldLoginManager.dll"]
        )
        XCTAssertTrue(InstallerDiagnostics.missingRequirements(
            output: output,
            required: ["MSCOREE.DLL", "sldloginmanager.loginmanager"]
        ).isEmpty)
    }

    func testRegisteredCLSIDReadsOnlyTheGUIDValue() {
        let output = """
        HKEY_CLASSES_ROOT\\SldWorks.Application\\CLSID
            (Default)    REG_SZ    {DA0BCE20-060A-4807-9C53-A46527C57EF1}
        """
        XCTAssertEqual(
            InstallerDiagnostics.registeredCLSID(fromQuery: output),
            "{DA0BCE20-060A-4807-9C53-A46527C57EF1}"
        )
        XCTAssertNil(InstallerDiagnostics.registeredCLSID(fromQuery: "REG_SZ    not-a-guid"))
    }
}
