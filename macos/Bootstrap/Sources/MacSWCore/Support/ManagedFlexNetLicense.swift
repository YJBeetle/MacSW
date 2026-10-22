import Foundation

/// Only the SERVER address in a locally managed copy is editable here.
/// Work on code units so legacy comments, signatures, BOMs and line endings
/// survive byte-for-byte; never decode and re-encode the entire license.
enum ManagedFlexNetLicense {
    static func loopbackCopy(of data: Data) throws -> Data {
        let bytes = Array(data)
        let littleEndian = bytes.starts(with: [0xFF, 0xFE])
        let bigEndian = bytes.starts(with: [0xFE, 0xFF])
        let width = littleEndian || bigEndian ? 2 : 1
        guard bytes.count % width == 0 else {
            throw failure("托管许可证的 UTF-16 编码不完整。")
        }
        let units: [UInt16]
        if width == 2 {
            units = stride(from: 0, to: bytes.count, by: 2).map { index -> UInt16 in
                let first = UInt16(bytes[index])
                let second = UInt16(bytes[index + 1])
                if littleEndian { return first | (second << 8) }
                return (first << 8) | second
            }
        } else {
            units = bytes.map(UInt16.init)
        }
        var start = width == 2 ? 1 : bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        var hostname: Range<Int>?
        while start < units.count {
            let end = units[start...].firstIndex(where: { $0 == 10 || $0 == 13 }) ?? units.count
            var tokens: [Range<Int>] = []
            var cursor = start
            while cursor < end {
                if units[cursor] == 32 || units[cursor] == 9 {
                    cursor += 1
                    continue
                }
                let first = cursor
                while cursor < end, units[cursor] != 32, units[cursor] != 9 { cursor += 1 }
                tokens.append(first..<cursor)
            }
            if let keyword = tokens.first, isServer(units[keyword]) {
                guard hostname == nil else {
                    throw failure("本机托管仅支持单一 SERVER；不能将冗余许可服务器改为本机地址。")
                }
                guard tokens.count >= 4 else {
                    throw failure("托管许可证的 SERVER 行缺少地址、HostID 或端口。")
                }
                hostname = tokens[1]
            }
            start = end + 1
        }
        guard let hostname else { throw failure("托管许可证缺少 SERVER 行。") }
        let replacement: [UInt8] = "127.0.0.1".utf8.flatMap { byte in
            width == 1 ? [byte] : littleEndian ? [byte, 0] : [0, byte]
        }
        var result = data
        result.replaceSubrange((hostname.lowerBound * width)..<(hostname.upperBound * width),
                               with: replacement)
        return result
    }

    private static func isServer(_ units: ArraySlice<UInt16>) -> Bool {
        let keyword = Array("SERVER".utf8)
        return units.count == keyword.count && zip(units, keyword).allSatisfy { unit, ascii in
            unit == UInt16(ascii) || unit == UInt16(ascii) + 32
        }
    }

    private static func failure(_ message: String) -> NSError {
        MacSWError.make(message, domain: "MacSW.FlexNet")
    }
}
