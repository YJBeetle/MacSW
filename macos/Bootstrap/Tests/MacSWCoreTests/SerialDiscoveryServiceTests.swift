import Foundation
import XCTest
@testable import MacSWCore

final class SerialDiscoveryServiceTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default

    private static let core = "AAAA AAAA AAAA AAAA AAAA AAAA"
    private static let simulation = "BBBB BBBB BBBB BBBB BBBB BBBB"
    private static let motion = "CCCC CCCC CCCC CCCC CCCC CCCC"
    private static let mbd = "DDDD DDDD DDDD DDDD DDDD DDDD"
    private static let other = "EEEE EEEE EEEE EEEE EEEE EEEE"
    private static let alternativeCore = "9999 9999 9999 9999 9999 9999"

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("MacSW-Discovery-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    @discardableResult
    private func write(_ relativePath: String, text: String, encoding: String.Encoding = .utf8) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.data(using: encoding)!.write(to: url)
        return url
    }

    func testHeadingsFillMSIFieldsAndIgnoreAddinsWithoutProperties() throws {
        try write("serials.txt", text: """
        SolidWorks           \(Self.core)
        COSMOSWorks          \(Self.simulation)
        COSMOSMotion         \(Self.motion)
        MBD                  \(Self.mbd)
        Plastics             \(Self.other)
        """)
        let result = SerialDiscoveryService.discover(in: [root])
        XCTAssertEqual(result.serials[.solidWorks], Self.core)
        XCTAssertEqual(result.serials[.simulation], Self.simulation)
        XCTAssertEqual(result.serials[.motion], Self.motion)
        XCTAssertEqual(result.serials[.mbd], Self.mbd)
        XCTAssertEqual(result.serials.msiProperties.count, 4)
        XCTAssertEqual(result.sources[.solidWorks]?.lastPathComponent, "serials.txt")
        XCTAssertTrue(result.ambiguousFields.isEmpty)
    }

    func testRegistryExportStyleFileIsMatchedWithoutImportingIt() throws {
        try write("license.reg", text: """
        Windows Registry Editor Version 5.00

        [HKEY_LOCAL_MACHINE\\SOFTWARE\\SolidWorks\\Licenses\\Serial Numbers]
        "SolidWorks"="\(Self.core)"
        "MBD"="\(Self.mbd)"

        [HKEY_LOCAL_MACHINE\\SOFTWARE\\SolidWorks]
        "SolidWorks Folder"="C:\\\\Program Files\\\\SOLIDWORKS"
        """, encoding: .utf16)
        let result = SerialDiscoveryService.discover(in: [root])
        XCTAssertEqual(result.serials[.solidWorks], Self.core)
        XCTAssertEqual(result.serials[.mbd], Self.mbd)
        XCTAssertTrue(result.serials[.simulation].isEmpty)
        XCTAssertTrue(result.ambiguousFields.isEmpty)
    }

    func testConflictingValuesAcrossFilesLeaveTheFieldAmbiguous() throws {
        try write("first.txt", text: "SolidWorks: \(Self.core)")
        try write("second.txt", text: "SolidWorks: \(Self.alternativeCore)")
        let result = SerialDiscoveryService.discover(in: [root])
        XCTAssertEqual(result.ambiguousFields, [.solidWorks])
        XCTAssertTrue(result.serials[.solidWorks].isEmpty)
        XCTAssertNil(result.sources[.solidWorks])
    }

    func testRepeatedIdenticalValueIsNotAmbiguousAndKeepsTheShallowestSource() throws {
        try write("keys.txt", text: "SolidWorks \(Self.core)")
        try write("nested/deep.txt", text: "SOLIDWORKS: \(Self.core)")
        let result = SerialDiscoveryService.discover(in: [root])
        XCTAssertTrue(result.ambiguousFields.isEmpty)
        XCTAssertEqual(result.sources[.solidWorks]?.lastPathComponent, "keys.txt")
    }

    func testOnlyTextLikeSmallFilesAreScanned() throws {
        try write("readme.md", text: "SolidWorks \(Self.core)")
        try write("notes.bin", text: "SolidWorks \(Self.alternativeCore)")
        try write("big.txt", text: "SolidWorks \(Self.alternativeCore)\n" + String(repeating: "x", count: 2_000_000))
        let result = SerialDiscoveryService.discover(in: [root])
        XCTAssertEqual(result.serials[.solidWorks], Self.core)
        XCTAssertEqual(result.scannedFiles.map(\.lastPathComponent), ["readme.md"])
    }

    func testWalkStopsAtTheConfiguredDepth() throws {
        try write("a/b/c/d/deep.txt", text: "SolidWorks \(Self.core)")
        XCTAssertTrue(SerialDiscoveryService.candidateFiles(in: [root]).isEmpty)
    }

    func testSearchRootsLimitWhichFilesParticipate() throws {
        try write("sibling.txt", text: "SolidWorks \(Self.core)")
        let media = root.appendingPathComponent("media")
        let inside: URL = try write("media/inside.txt", text: "SolidWorks \(Self.alternativeCore)")

        let mediaOnly = SerialDiscoveryService.discover(in: [media])
        XCTAssertEqual(mediaOnly.sources[.solidWorks]?.lastPathComponent, inside.lastPathComponent)

        // 同级与介质内部命中不同值时按歧义处理，不做猜测。
        let both = SerialDiscoveryService.discover(in: [root])
        XCTAssertEqual(both.ambiguousFields, [.solidWorks])
    }

    func testFileWithoutAnySerialIsIgnored() throws {
        try write("install.txt", text: "运行 setup.exe 并按提示完成安装。")
        let result = SerialDiscoveryService.discover(in: [root])
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.scannedFiles.count, 1)
    }
    /// 扫描有上限，撞到上限必须说出来：静默少扫会让"没找到序列号"变成假结论。
    func testScanReportsTruncationWhenCandidateListHitsTheCap() throws {
        for index in 0...(SerialDiscoveryService.maximumCandidateFiles) {
            try write("docs/notes-\(index).txt", text: "没有序列号")
        }
        let result = SerialDiscoveryService.discover(in: [root])
        XCTAssertTrue(result.scanTruncated)
        XCTAssertEqual(result.scannedFiles.count, SerialDiscoveryService.maximumCandidateFiles)

        let small = root.appendingPathComponent("small")
        try fileManager.createDirectory(at: small, withIntermediateDirectories: true)
        try write("only.txt", text: "没有序列号")
        XCTAssertFalse(SerialDiscoveryService.discover(in: [small]).scanTruncated)
    }

}
