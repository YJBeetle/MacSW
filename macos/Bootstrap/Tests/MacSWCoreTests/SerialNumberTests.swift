import XCTest
@testable import MacSWCore

final class SerialNumberTests: XCTestCase {
    func testParsesNamedProductsWithoutPrefixCollisions() throws {
        let parsed = try SerialNumberService.parse("""
        ComposerPlayer AAAA BBBB CCCC DDDD EEEE FFFF
        Composer 1111 2222 3333 4444 5555 6666
        Visualize Boost ABCD-EFGH-IJKL-MNOP-QRST-UVWX
        Visualize 0001 0002 0003 0004 0005 0006
        """)
        XCTAssertEqual(parsed.values[.composerPlayer], "AAAA BBBB CCCC DDDD EEEE FFFF")
        XCTAssertEqual(parsed.values[.composer], "1111 2222 3333 4444 5555 6666")
        XCTAssertEqual(parsed.values[.visualizeBoost], "ABCD EFGH IJKL MNOP QRST UVWX")
        XCTAssertEqual(parsed.values[.visualize], "0001 0002 0003 0004 0005 0006")
    }

    func testAllowsMultilineWithinSectionButDoesNotCrossNextHeading() throws {
        let parsed = try SerialNumberService.parse("""
        SolidWorks
        0018 0000 0010
        9647 NKHW WBH3
        CAM
        ABCD EFGH IJKL MNOP QRST UVWX
        """)
        XCTAssertEqual(parsed.values[.solidWorks], "0018 0000 0010 9647 NKHW WBH3")
        XCTAssertEqual(parsed.values[.cam], "ABCD EFGH IJKL MNOP QRST UVWX")
    }

    func testSingleUnlabelledSerialIsSolidWorksAndMultipleAreRejected() throws {
        let parsed = try SerialNumberService.parse("0018-0000-0010-9647-NKHW-WBH3")
        XCTAssertEqual(parsed.values, [.solidWorks: "0018 0000 0010 9647 NKHW WBH3"])
        XCTAssertThrowsError(try SerialNumberService.parse("""
        0018 0000 0010 9647 NKHW WBH3
        ABCD EFGH IJKL MNOP QRST UVWX
        """)) { error in
            XCTAssertEqual(error as? SerialNumberError, .multipleUnlabelledSerialNumbers)
        }
    }

    func testConflictingSerialsForSameProductAreRejected() {
        XCTAssertThrowsError(try SerialNumberService.parse("""
        SolidWorks 0018 0000 0010 9647 NKHW WBH3
        SolidWorks ABCD EFGH IJKL MNOP QRST UVWX
        """)) { error in
            XCTAssertEqual(error as? SerialNumberError, .conflictingSerialNumbers(.solidWorks))
        }
    }

    func testSolidWorksRegistryAssignmentsIncludeSecuritySplit() {
        let parsed = ParsedSerialNumbers(values: [
            .solidWorks: "0018 0000 0010 9647 NKHW WBH3",
            .cam: "ABCD EFGH IJKL MNOP QRST UVWX"
        ])
        let assignments = SerialNumberService.registryAssignments(for: parsed)
        XCTAssertTrue(assignments.contains(RegistryAssignment(
            key: "HKLM\\SOFTWARE\\SolidWorks\\Licenses\\Serial Numbers",
            name: "SolidWorks",
            value: "0018 0000 0010 9647 NKHW WBH3"
        )))
        XCTAssertTrue(assignments.contains(RegistryAssignment(
            key: "HKLM\\SOFTWARE\\SolidWorks\\Security",
            name: "Serial Number",
            value: "0018 0000 0010 9647"
        )))
        XCTAssertTrue(assignments.contains(RegistryAssignment(
            key: "HKLM\\SOFTWARE\\SolidWorks\\Security",
            name: "Serial Number Extra",
            value: "NKHW WBH3"
        )))
    }
}
