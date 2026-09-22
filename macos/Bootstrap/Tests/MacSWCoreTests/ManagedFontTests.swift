import CryptoKit
import Foundation
import XCTest
@testable import MacSWCore

final class ManagedFontTests: XCTestCase {
    func testNotoSansSCFontsAreVerifiedAndProvisionedAtomically() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MacSW-fonts-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let bundle = root.appendingPathComponent("MacSW.app")
        let resources = bundle.appendingPathComponent("Contents/Resources/fonts/NotoSansSC")
        let prefix = root.appendingPathComponent("bottle")
        let regular = Data("validated regular font".utf8)
        let bold = Data("validated bold font".utf8)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        try regular.write(to: resources.appendingPathComponent(PrerequisiteService.notoSansSCRegularName))
        try bold.write(to: resources.appendingPathComponent(PrerequisiteService.notoSansSCBoldName))

        let regularHash = SHA256.hash(data: regular).map { String(format: "%02x", $0) }.joined()
        let boldHash = SHA256.hash(data: bold).map { String(format: "%02x", $0) }.joined()
        try PrerequisiteService.prepareManagedFonts(
            bundleURL: bundle,
            prefix: prefix,
            expectedRegularSHA256: regularHash,
            expectedBoldSHA256: boldHash
        )

        let target = prefix.appendingPathComponent(PrerequisiteService.fontsDestination)
        XCTAssertEqual(
            try Data(contentsOf: target.appendingPathComponent(PrerequisiteService.notoSansSCRegularName)),
            regular
        )
        XCTAssertEqual(
            try Data(contentsOf: target.appendingPathComponent(PrerequisiteService.notoSansSCBoldName)),
            bold
        )

        try Data("stale".utf8).write(
            to: target.appendingPathComponent(PrerequisiteService.notoSansSCRegularName)
        )
        try PrerequisiteService.prepareManagedFonts(
            bundleURL: bundle,
            prefix: prefix,
            expectedRegularSHA256: regularHash,
            expectedBoldSHA256: boldHash
        )
        XCTAssertEqual(
            try Data(contentsOf: target.appendingPathComponent(PrerequisiteService.notoSansSCRegularName)),
            regular
        )

        XCTAssertThrowsError(try PrerequisiteService.prepareManagedFonts(
            bundleURL: bundle,
            prefix: prefix,
            expectedRegularSHA256: String(repeating: "0", count: 64),
            expectedBoldSHA256: boldHash
        ))
        try fm.removeItem(at: resources.appendingPathComponent(PrerequisiteService.notoSansSCBoldName))
        XCTAssertThrowsError(try PrerequisiteService.prepareManagedFonts(
            bundleURL: bundle,
            prefix: prefix,
            expectedRegularSHA256: regularHash,
            expectedBoldSHA256: boldHash
        ))
    }
}
