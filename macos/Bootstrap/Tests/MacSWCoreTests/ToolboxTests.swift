import Foundation
import XCTest
@testable import MacSWCore

final class ToolboxTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-Toolbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func write(_ value: String, path: String, root: URL) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: file)
    }

    func testOfficialUpdaterUsesDefaultMonoWithoutChangingInstallerEnvironment() {
        let prefix = URL(fileURLWithPath: "/tmp/toolbox-test")
        let process = ToolboxService().makeUpdater(executable: URL(fileURLWithPath: "/sw/sldtoolboxupdater.exe"),
            dataPath: #"C:\SWData"#, archivesPath: #"Z:\media with spaces\Toolbox"#, prefix: prefix)
        XCTAssertEqual(process.arguments, ["/sw/sldtoolboxupdater.exe", #"C:\SWData"#, #"Z:\media with spaces\Toolbox"#, "TRUE"])
        XCTAssertEqual(process.environment?["WINE_MONO_AOT"], "none")
        XCTAssertEqual(WineService.shared.environment(winePrefix: prefix)["WINE_MONO_AOT"], "interp")
        XCTAssertNil(process.environment?["WINEDLLOVERRIDES"])
    }

    func testDataLocationIsVersionIndependentAndOnlyReadsGeneralSettings() {
        let paths = ToolboxService.dataPaths(in: #"""
        [Software\\SolidWorks\\SOLIDWORKS 2027\\General] 123
        "Toolbox Data Location"="D:\\Shared Toolbox"
        [Unrelated]
        "Toolbox Data Location"="C:\\wrong"
        "SolidWorks Folder"="C:\\Program Files\\SOLIDWORKS"
        """#)
        XCTAssertEqual(paths, [#"D:\Shared Toolbox"#])
    }

    func testDataLocationPrefersUserOverrideAndRejectsAmbiguousVersions() throws {
        let prefix = try root()
        let header = #"[Software\\SolidWorks\\SOLIDWORKS 2025\\General]"#
        try write(header + "\n\"Toolbox Data Location\"=\"C:\\\\SWData\"", path: "system.reg", root: prefix)
        XCTAssertEqual(try ToolboxService.configuredDataPath(prefix: prefix), #"C:\SWData"#)
        try write(header + "\n\"Toolbox Data Location\"=\"D:\\\\Custom\"", path: "user.reg", root: prefix)
        XCTAssertEqual(try ToolboxService.configuredDataPath(prefix: prefix), #"D:\Custom"#)
        try write(header + "\n\"Toolbox Data Location\"=\"D:\\\\One\"\n" +
                  #"[Software\\SolidWorks\\SOLIDWORKS 2026\\General]"# + "\n\"Toolbox Data Location\"=\"D:\\\\Two\"",
                  path: "user.reg", root: prefix)
        XCTAssertThrowsError(try ToolboxService.configuredDataPath(prefix: prefix))
    }

    func testOnlySelectedStandardsAreValidated() throws {
        let root = try root()
        try write("<ToolboxStandards><Standard><Name>GB</Name><Source>gb.zip</Source><Install>Yes</Install></Standard>" +
                  "<Standard><Name>ISO</Name><Source>iso.zip</Source><Install>No</Install></Standard></ToolboxStandards>",
                  path: "ToolboxStandards.xml", root: root)
        let selected = try ToolboxService.selectedStandards(in: root)
        XCTAssertEqual(selected, [.init(name: "GB", source: "gb.zip")])
        try write("index", path: "browser/ToolboxFiles.index", root: root)
        try write("part", path: "browser/GB/Bolts/bolt.SLDPRT", root: root)
        XCTAssertEqual(try ToolboxService.validate(root: root, standards: selected), 1)
    }

    func testExitZeroOrDatabaseAloneDoesNotProveToolboxDeployment() throws {
        let root = try root()
        let standards = [ToolboxService.Standard(name: "GB", source: "gb.zip")]
        try write("database", path: "lang/english/swbrowser.sldedb", root: root)
        XCTAssertThrowsError(try ToolboxService.validate(root: root, standards: standards))
        try write("index", path: "browser/ToolboxFiles.index", root: root)
        XCTAssertThrowsError(try ToolboxService.validate(root: root, standards: standards))
    }

    func testEachSelectedStandardNeedsModels() throws {
        let root = try root()
        try write("index", path: "browser/ToolboxFiles.index", root: root)
        try write("part", path: "browser/GB/bolt.sldprt", root: root)
        XCTAssertThrowsError(try ToolboxService.validate(root: root, standards: [
            .init(name: "GB", source: "gb.zip"), .init(name: "ISO", source: "iso.zip")]))
    }

    func testMalformedAndUnsafeStandardsAreRefused() throws {
        let root = try root()
        for xml in ["<ToolboxStandards>", "<unrelated />",
                    "<ToolboxStandards><Standard><Name>GB</Name><Source>../gb.zip</Source><Install>Yes</Install></Standard></ToolboxStandards>",
                    "<ToolboxStandards><Standard><Name>../GB</Name><Source>gb.zip</Source><Install>Yes</Install></Standard></ToolboxStandards>"] {
            try write(xml, path: "ToolboxStandards.xml", root: root)
            XCTAssertThrowsError(try ToolboxService.selectedStandards(in: root))
        }
    }

    func testToolboxRunsAfterThemesAndBeforeFinalValidation() {
        XCTAssertLessThan(InstallationStep.wpfThemes.rawValue, InstallationStep.toolbox.rawValue)
        XCTAssertLessThan(InstallationStep.toolbox.rawValue, InstallationStep.validation.rawValue)
    }
}
