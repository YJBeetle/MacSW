import Foundation
import XCTest
@testable import MacSWCore

final class CompanionFileTests: XCTestCase {
    func testScansDirectFilesAndExactlyOneSubdirectoryLevel() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("SOLIDWORKS.iso")
        try Data().write(to: media)
        let direct = root.appendingPathComponent("serials.txt")
        try serialText().write(to: direct, atomically: true, encoding: .utf8)
        let child = root.appendingPathComponent("extras")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let nested = child.appendingPathComponent("serials.reg")
        try registryText().write(to: nested, atomically: true, encoding: .utf8)
        let grandchild = child.appendingPathComponent("deeper")
        try FileManager.default.createDirectory(at: grandchild, withIntermediateDirectories: true)
        try serialText().write(
            to: grandchild.appendingPathComponent("ignored.txt"), atomically: true, encoding: .utf8
        )

        let results = CompanionFileService.findSerialInputs(nextTo: media)
        XCTAssertEqual(results.map(\.url.lastPathComponent), ["serials.txt", "serials.reg"])
        XCTAssertEqual(results.map(\.depth), [0, 1])
    }

    func testAutomaticSelectionPrefersOneDirectCandidateAndRejectsAmbiguity() {
        let direct = SerialInputFile(url: URL(fileURLWithPath: "/direct.txt"), kind: .text, depth: 0)
        let nested = SerialInputFile(url: URL(fileURLWithPath: "/nested.reg"), kind: .registry, depth: 1)
        XCTAssertEqual(CompanionFileService.preferredAutomaticSelection(from: [direct, nested]), direct)
        XCTAssertEqual(CompanionFileService.preferredAutomaticSelection(from: [nested]), nested)
        XCTAssertNil(CompanionFileService.preferredAutomaticSelection(from: [direct, direct]))
    }

    func testRejectsUnrelatedRegistryFilesAndOversizedText() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("SOLIDWORKS.iso")
        try Data().write(to: media)
        try "Windows Registry Editor Version 5.00".write(
            to: root.appendingPathComponent("unrelated.reg"), atomically: true, encoding: .utf8
        )
        try Data(repeating: 65, count: CompanionFileService.maximumTextFileSize + 1)
            .write(to: root.appendingPathComponent("large.txt"))
        XCTAssertTrue(CompanionFileService.findSerialInputs(nextTo: media).isEmpty)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSW-companion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func serialText() -> String {
        "SolidWorks 0018 0000 0010 9647 NKHW WBH3"
    }

    private func registryText() -> String {
        """
        Windows Registry Editor Version 5.00
        [HKEY_LOCAL_MACHINE\\SOFTWARE\\SolidWorks\\Licenses\\Serial Numbers]
        "SolidWorks"="0018 0000 0010 9647 NKHW WBH3"
        """
    }
}
