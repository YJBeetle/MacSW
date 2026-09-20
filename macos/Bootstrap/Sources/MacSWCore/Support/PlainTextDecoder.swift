import Foundation

/// 微软安装器与注册表导出常见 UTF-16 或传统代码页，逐个兜底解码。
public enum PlainTextDecoder {
    public static func decode(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data, encoding: .utf16LittleEndian) }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16BigEndian) }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .windowsCP1252)
    }
}
