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

    /// 全角、西里尔、重音字符在 Unicode 里都算"字母数字"，绝不能被当成 24 位留下来。
    func testNormalizationDropsEverythingOutsideASCIIAlphanumeric() {
        XCTAssertEqual(InstallSerials.normalized("　-／"), "")
        XCTAssertEqual(InstallSerials.normalized("\u{00E9}"), "")      // 预组合 é：单个非 ASCII 标量
        XCTAssertEqual(InstallSerials.normalized("e\u{0301}"), "E")    // 分解形式：组合记号被丢，ASCII 字母留下
        XCTAssertEqual(InstallSerials.normalized("ß"), "")
        XCTAssertEqual(InstallSerials.normalized("ＡＢＣＤ"), "")
        XCTAssertEqual(InstallSerials.normalized("ВВВВ"), "")
        XCTAssertEqual(InstallSerials.normalized("В1"), "1")
        XCTAssertEqual(InstallSerials.normalized("１２３４"), "")
        XCTAssertEqual(InstallSerials.normalized("١٢٣٤"), "")
    }

    func testNonASCIISerialIsRejectedAsMalformed() {
        var serials = InstallSerials()
        // 24 个全角数字：字形簇刚好 24，但一个 ASCII 字符都不是。
        serials[.solidWorks] = "１２３４１２３４１２３４１２３４１２３４１２３４"
        XCTAssertEqual(serials.invalidFields(), [.solidWorks])
        XCTAssertFalse(serials.isComplete)
        XCTAssertTrue(serials.msiProperties.isEmpty)
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

    func testOnlyMSICapableProductsHaveFields() {
        XCTAssertEqual(InstallSerialField.forProduct(.solidWorks), .solidWorks)
        XCTAssertEqual(InstallSerialField.forProduct(.cosmosWorks), .simulation)
        XCTAssertEqual(InstallSerialField.forProduct(.cosmosMotion), .motion)
        XCTAssertEqual(InstallSerialField.forProduct(.mbd), .mbd)
        XCTAssertNil(InstallSerialField.forProduct(.plastics))
        XCTAssertNil(InstallSerialField.forProduct(.visualize))
    }

    /// 全角之类的垃圾输入是"填了但没填对"，不能被扫描结果悄悄盖掉。
    func testMergingKeepsTypedButUnusableInput() {
        var typed = InstallSerials(values: [.solidWorks: "\u{FF11}\u{FF12}\u{FF13}\u{FF14}"])
        let discovered = InstallSerials(values: [.solidWorks: "DDDD DDDD DDDD DDDD DDDD DDDD"])
        typed = typed.merging(discovered)
        XCTAssertEqual(typed[.solidWorks], "\u{FF11}\u{FF12}\u{FF13}\u{FF14}")
        XCTAssertEqual(typed.invalidFields(), [.solidWorks])
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
        XCTAssertEqual(languages.count, 2)
        XCTAssertEqual(
            Set(languages),
            Set([
                SolidWorksLanguage(
                    directoryName: "chinese-simplified",
                    msiFileName: "chinese-simplified.msi",
                    displayName: "简体中文"
                ),
                SolidWorksLanguage(directoryName: "german", msiFileName: "german.msi", displayName: "Deutsch")
            ])
        )
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
