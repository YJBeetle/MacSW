import Foundation
import XCTest
@testable import MacSWCore

final class InstallSerialsTests: XCTestCase {
    func testNormalizationStripsSeparatorsAndUppercases() {
        XCTAssertEqual(
            InstallSerials.normalized("abcd-efgh 1234 ijkl mnop qrst"),
            "ABCDEFGH1234IJKLMNOPQRST"
        )
    }

    func testMSIPropertiesAreDeterministicAndSkipEmptyFields() {
        var serials = InstallSerials()
        serials[.mbd] = "AAAA BBBB CCCC DDDD EEEE FFFF"
        serials[.solidWorks] = "1111-2222-3333-4444-5555-6666"
        serials[.motion] = "   "
        XCTAssertEqual(serials.msiProperties, [
            "MBDSERIALNUMBER=AAAABBBBCCCCDDDDEEEEFFFF",
            "SOLIDWORKSSERIALNUMBER=111122223333444455556666"
        ])
        XCTAssertFalse(serials.isEmpty)
        XCTAssertTrue(serials.isComplete)
    }

    func testInvalidFieldsOnlyReportFilledMalformedValues() {
        var serials = InstallSerials()
        serials[.simulation] = "12345"
        XCTAssertEqual(serials.invalidFields(), [.simulation])
        serials[.simulation] = ""
        XCTAssertTrue(serials.invalidFields().isEmpty)
    }

    func testParsedForRegistrySkipsEmptyFieldsAndUsesProductNames() {
        var serials = InstallSerials(values: [
            .solidWorks: "AAAA AAAA AAAA AAAA AAAA AAAA",
            .mbd: "  ",
            .motion: "CCCC CCCC CCCC CCCC CCCC CCCC"
        ])
        serials[.simulation] = "BBBB BBBB BBBB BBBB BBBB BBBB"
        let parsed = serials.parsedForRegistry
        // mbd 只有空白字符，视为未填写。
        XCTAssertEqual(Set(parsed.values.keys), [.solidWorks, .cosmosWorks, .cosmosMotion])
        XCTAssertEqual(parsed.values[.cosmosWorks], "BBBB BBBB BBBB BBBB BBBB BBBB")
        let assignments = SerialNumberService.registryAssignments(for: ParsedSerialNumbers(values: [
            .solidWorks: "AAAA AAAA AAAA AAAA AAAA AAAA"
        ]))
        XCTAssertTrue(assignments.contains { $0.key == "HKLM\\SOFTWARE\\SolidWorks\\Security" && $0.name == "Serial Number Extra" })
    }

    func testOnlyMSICapableProductsHaveFields() {
        XCTAssertEqual(InstallSerialField.forProduct(.solidWorks), .solidWorks)
        XCTAssertEqual(InstallSerialField.forProduct(.cosmosWorks), .simulation)
        XCTAssertEqual(InstallSerialField.forProduct(.cosmosMotion), .motion)
        XCTAssertEqual(InstallSerialField.forProduct(.mbd), .mbd)
        XCTAssertNil(InstallSerialField.forProduct(.plastics))
        XCTAssertNil(InstallSerialField.forProduct(.visualize))
    }

    func testMergingFillsOnlyEmptyFields() {
        var discovered = InstallSerials(values: [
            .solidWorks: "BBBB BBBB BBBB BBBB BBBB BBBB",
            .simulation: "CCCC CCCC CCCC CCCC CCCC CCCC",
            .motion: "   "
        ])
        var typed = InstallSerials(values: [.solidWorks: "AAAA AAAA AAAA AAAA AAAA AAAA"])
        typed = typed.merging(discovered)
        XCTAssertEqual(typed[.solidWorks], "AAAA AAAA AAAA AAAA AAAA AAAA")
        XCTAssertEqual(typed[.simulation], "CCCC CCCC CCCC CCCC CCCC CCCC")
        XCTAssertTrue(typed[.motion].isEmpty)
        discovered[.mbd] = "  "
        XCTAssertTrue(InstallSerials().merging(discovered)[.mbd].isEmpty)
    }
}

final class LanguageCatalogTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("MacSW-Languages-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    private func makeLanguageDirectory(_ name: String, msiName: String? = nil) throws {
        let directory = root.appendingPathComponent(LanguageCatalog.relativeDirectory).appendingPathComponent(name)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("msi".utf8).write(to: directory.appendingPathComponent(msiName ?? "\(name).msi"))
        try Data("cab".utf8).write(to: directory.appendingPathComponent("payload.cab"))
    }

    func testDiscoveryOnlyKeepsDirectoriesWithAnMSI() throws {
        try makeLanguageDirectory("chinese-simplified")
        try makeLanguageDirectory("german", msiName: "german.msi")
        let empty = root.appendingPathComponent(LanguageCatalog.relativeDirectory).appendingPathComponent("korean")
        try fileManager.createDirectory(at: empty, withIntermediateDirectories: true)

        let languages = LanguageCatalog.discover(in: root, fileManager: fileManager)
        XCTAssertEqual(languages.map(\.directoryName), ["chinese-simplified", "german"])
        XCTAssertEqual(languages.map(\.displayName), ["简体中文", "Deutsch"])
    }

    func testDiscoveryAcceptsMismatchedMSIBasename() throws {
        try makeLanguageDirectory("turkish", msiName: "Turkish.msi")
        let languages = LanguageCatalog.discover(in: root, fileManager: fileManager)
        XCTAssertEqual(languages.first?.msiFileName, "Turkish.msi")
        XCTAssertEqual(
            LanguageCatalog.relativeMSIPath(languages[0]),
            "swwi/lang/turkish/Turkish.msi"
        )
    }

    func testDiscoveryReturnsEmptyWithoutMedia() {
        XCTAssertTrue(LanguageCatalog.discover(in: root.appendingPathComponent("missing")).isEmpty)
    }

    func testSystemLanguageIdentifiersMapToMediaDirectories() {
        XCTAssertEqual(LanguageCatalog.match(for: "en-US"), .baseLanguage)
        XCTAssertEqual(LanguageCatalog.match(for: "zh-Hans-CN"), .directory("chinese-simplified"))
        XCTAssertEqual(LanguageCatalog.match(for: "zh-CN"), .directory("chinese-simplified"))
        XCTAssertEqual(LanguageCatalog.match(for: "zh-Hant"), .directory("chinese"))
        XCTAssertEqual(LanguageCatalog.match(for: "zh-TW"), .directory("chinese"))
        XCTAssertEqual(LanguageCatalog.match(for: "zh-HK"), .directory("chinese"))
        XCTAssertEqual(LanguageCatalog.match(for: "de-DE"), .directory("german"))
        XCTAssertEqual(LanguageCatalog.match(for: "pt"), .directory("portuguese-brazilian"))
        XCTAssertEqual(LanguageCatalog.match(for: "nl-NL"), .unknown)
        XCTAssertEqual(LanguageCatalog.match(for: ""), .unknown)
    }

    func testAutoSelectionFollowsSystemPreferenceOrder() {
        let media = ["chinese-simplified", "japanese", "korean"].map {
            SolidWorksLanguage(directoryName: $0, msiFileName: "\($0).msi", displayName: $0)
        }
        XCTAssertEqual(
            LanguageCatalog.autoSelection(from: media, preferredLanguages: ["zh-Hans-CN", "en-US"])?.directoryName,
            "chinese-simplified"
        )
        // 无法识别的首选语言继续向后查找。
        XCTAssertEqual(
            LanguageCatalog.autoSelection(from: media, preferredLanguages: ["nl-NL", "ja"])?.directoryName,
            "japanese"
        )
        // 介质没有对应语言资源时不猜，保持介质默认。
        XCTAssertNil(LanguageCatalog.autoSelection(from: media, preferredLanguages: ["de-DE", "fr"]))
        XCTAssertNil(LanguageCatalog.autoSelection(from: media, preferredLanguages: ["en-GB"]))
        XCTAssertNil(LanguageCatalog.autoSelection(from: [], preferredLanguages: ["zh-Hans-CN"]))
    }
}
