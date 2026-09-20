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

    func testMergingMapsAddinProductsToMSIFieldsAndIgnoresTheRest() {
        let parsed = ParsedSerialNumbers(values: [
            .solidWorks: "AAAA AAAA AAAA AAAA AAAA AAAA",
            .cosmosWorks: "BBBB BBBB BBBB BBBB BBBB BBBB",
            .cosmosMotion: "CCCC CCCC CCCC CCCC CCCC CCCC",
            .mbd: "DDDD DDDD DDDD DDDD DDDD DDDD",
            .plastics: "EEEE EEEE EEEE EEEE EEEE EEEE"
        ])
        let merged = InstallSerials().merging(parsed)
        XCTAssertEqual(merged[.simulation], "BBBB BBBB BBBB BBBB BBBB BBBB")
        XCTAssertEqual(merged[.motion], "CCCC CCCC CCCC CCCC CCCC CCCC")
        XCTAssertEqual(merged[.mbd], "DDDD DDDD DDDD DDDD DDDD DDDD")
        XCTAssertEqual(merged.msiProperties.count, 4)
    }

    func testMergingKeepsValuesTheUserAlreadyTyped() {
        let parsed = ParsedSerialNumbers(values: [.solidWorks: "BBBB BBBB BBBB BBBB BBBB BBBB"])
        var serials = InstallSerials()
        serials[.solidWorks] = "AAAA AAAA AAAA AAAA AAAA AAAA"
        XCTAssertEqual(serials.merging(parsed)[.solidWorks], "AAAA AAAA AAAA AAAA AAAA AAAA")
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

    func testPreferredFallsBackToFirstLanguage() throws {
        try makeLanguageDirectory("german")
        XCTAssertEqual(LanguageCatalog.preferred(from: LanguageCatalog.discover(in: root))?.directoryName, "german")

        try makeLanguageDirectory("chinese-simplified")
        XCTAssertEqual(
            LanguageCatalog.preferred(from: LanguageCatalog.discover(in: root))?.directoryName,
            "chinese-simplified"
        )
    }

    func testDiscoveryReturnsEmptyWithoutMedia() {
        XCTAssertTrue(LanguageCatalog.discover(in: root.appendingPathComponent("missing")).isEmpty)
    }
}
