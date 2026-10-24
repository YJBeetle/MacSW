import Foundation

public enum SolidWorksDocument {
    public static let extensions: Set<String> = ["sldprt", "sldasm", "slddrw"]

    public static func validatedURL(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw failure("只能打开本地 SOLIDWORKS 文件。") }
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        guard extensions.contains(file.pathExtension.lowercased()) else {
            throw failure("仅支持 .sldprt、.sldasm 和 .slddrw 文件。")
        }
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              FileManager.default.isReadableFile(atPath: file.path) else {
            throw failure("文件不存在、不可读取，或不是普通文件：\(file.lastPathComponent)")
        }
        return file
    }

    static func failure(_ message: String) -> NSError {
        MacSWError.make(message, domain: "MacSW.DocumentOpen")
    }
}

