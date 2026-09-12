import Foundation
import XCTest
@testable import MacSWCore

final class RegAsmTests: XCTestCase {
    func testCompatibilityMappingIsRepeatableAndPreservesUnknownTools() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MacSW-RegAsm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let runtime = root.appendingPathComponent("runtime")
        let prefix = root.appendingPathComponent("bottle")

        for arch in ["x86_64-windows", "i386-windows"] {
            let source = runtime.appendingPathComponent("lib/wine/\(arch)/regasm.exe")
            try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(arch.utf8).write(to: source)
        }

        try PrerequisiteService.prepareRegAsmCompatibility(runtime: runtime, prefix: prefix)
        try PrerequisiteService.prepareRegAsmCompatibility(runtime: runtime, prefix: prefix)
        let target = prefix.appendingPathComponent("drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/regasm.exe")
        XCTAssertEqual(try Data(contentsOf: target), Data("x86_64-windows".utf8))
        let log = try String(contentsOf: root.appendingPathComponent("logs/regasm-compatibility.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("SKIPPED"))

        try Data("native tool".utf8).write(to: target)
        XCTAssertThrowsError(try PrerequisiteService.prepareRegAsmCompatibility(runtime: runtime, prefix: prefix))
        XCTAssertEqual(try Data(contentsOf: target), Data("native tool".utf8))
    }
}
