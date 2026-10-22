import Foundation
import XCTest
@testable import MacSWCore

final class ManagedFlexNetLicenseTests: XCTestCase {
    func testOnlyHostnameChangesAndAllAuthorizationFieldsSurvive() throws {
        for host in ["this_host", "localhost", "127.0.0.1", "ascii-host", "𐌂𐌏ⵍ𐌔𐌕𐌀ⵍ𐌔𐌄", "用户的电脑"] {
            let before = "# SERVER comment stays\r\n\tSeRvEr\t\(host)\t001122aabbcc 25734\r\nVENDOR SW_D\r\nFEATURE sample SW_D 1.0 permanent 1 SIGN=ABCDEF\r\n"
            let after = before.replacingOccurrences(of: "\t\(host)\t", with: "\t127.0.0.1\t")
            let prepared = try ManagedFlexNetLicense.loopbackCopy(of: Data(before.utf8))
            XCTAssertEqual(prepared, Data(after.utf8), host)
            XCTAssertEqual(try ManagedFlexNetLicense.loopbackCopy(of: prepared), prepared)
        }
    }

    func testNewlinesAndFinalLineWithoutTerminatorArePreserved() throws {
        for separator in ["\n", "\r\n", "\r"] {
            let before = "VENDOR SW_D\(separator)SERVER this_host HOSTNAME=original-machine 25734"
            let after = "VENDOR SW_D\(separator)SERVER 127.0.0.1 HOSTNAME=original-machine 25734"
            XCTAssertEqual(try ManagedFlexNetLicense.loopbackCopy(of: Data(before.utf8)), Data(after.utf8))
        }
    }

    func testUTF8BOMAndLegacyCommentBytesArePreserved() throws {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let trailer: [UInt8] = [10, 35, 32, 0x81, 0xFE, 0xE9, 13, 10]
        let before = Data(bom + Array("SERVER this_host 001122aabbcc 25734\r\nVENDOR SW_D".utf8) + trailer)
        let after = Data(bom + Array("SERVER 127.0.0.1 001122aabbcc 25734\r\nVENDOR SW_D".utf8) + trailer)
        XCTAssertEqual(try ManagedFlexNetLicense.loopbackCopy(of: before), after)
    }

    func testUTF16BothByteOrdersPreserveBOMAndSurrogateComments() throws {
        let before = "SERVER 𐌂𐌏ⵍ𐌔𐌕𐌀ⵍ𐌔𐌄 001122aabbcc 25734\r\n# 注释🧩\r\nVENDOR SW_D\r\nFEATURE x SIGN=abc\r\n"
        let after = before.replacingOccurrences(of: "𐌂𐌏ⵍ𐌔𐌕𐌀ⵍ𐌔𐌄", with: "127.0.0.1")
        for littleEndian in [true, false] {
            func encode(_ text: String) -> Data {
                Data(([UInt16(0xFEFF)] + Array(text.utf16)).flatMap { unit -> [UInt8] in
                    let low = UInt8(unit & 0xFF), high = UInt8(unit >> 8)
                    return littleEndian ? [low, high] : [high, low]
                })
            }
            XCTAssertEqual(try ManagedFlexNetLicense.loopbackCopy(of: encode(before)), encode(after))
        }
    }

    func testMissingMalformedAndRedundantServerLinesAreRejected() throws {
        for text in ["", "VENDOR SW_D", "# SERVER host id 25734", "SERVER host id",
                     "SERVER one id1 25734\nSERVER two id2 25734\nVENDOR SW_D"] {
            XCTAssertThrowsError(try ManagedFlexNetLicense.loopbackCopy(of: Data(text.utf8)), text)
        }
        XCTAssertThrowsError(try ManagedFlexNetLicense.loopbackCopy(of: Data([0xFF, 0xFE, 0x41])))
    }
}
