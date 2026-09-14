import Foundation

public enum CompanionFileService {
    public static let maximumTextFileSize = 1_048_576

    public static func findSerialInputs(nextTo media: URL, fileManager: FileManager = .default) -> [SerialInputFile] {
        let parent = media.deletingLastPathComponent()
        let direct = candidates(in: parent, depth: 0, fileManager: fileManager)
        let nested = immediateDirectories(in: parent, fileManager: fileManager)
            .flatMap { candidates(in: $0, depth: 1, fileManager: fileManager) }
        return (direct + nested).sorted {
            if $0.depth != $1.depth { return $0.depth < $1.depth }
            let filenameOrder = $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent)
            if filenameOrder != .orderedSame { return filenameOrder == .orderedAscending }
            return $0.url.path.localizedCaseInsensitiveCompare($1.url.path) == .orderedAscending
        }
    }

    public static func preferredAutomaticSelection(from candidates: [SerialInputFile]) -> SerialInputFile? {
        let direct = candidates.filter { $0.depth == 0 }
        if direct.count == 1 { return direct[0] }
        if direct.count > 1 { return nil }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func immediateDirectories(in directory: URL, fileManager: FileManager) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private static func candidates(in directory: URL, depth: Int, fileManager: FileManager) -> [SerialInputFile] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  (values.fileSize ?? maximumTextFileSize + 1) <= maximumTextFileSize else { return nil }
            switch url.pathExtension.lowercased() {
            case "txt":
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      (try? SerialNumberService.parse(text)) != nil else { return nil }
                return SerialInputFile(url: url, kind: .text, depth: depth)
            case "reg":
                guard let data = try? Data(contentsOf: url), isHighConfidenceRegistry(data) else { return nil }
                return SerialInputFile(url: url, kind: .registry, depth: depth)
            default:
                return nil
            }
        }
    }

    private static func isHighConfidenceRegistry(_ data: Data) -> Bool {
        let encodings: [String.Encoding] = [.utf8, .utf16LittleEndian, .utf16BigEndian, .windowsCP1252]
        for encoding in encodings {
            guard let text = String(data: data, encoding: encoding) else { continue }
            let lowered = text.lowercased()
            let hasSerialNumberKey = lowered.contains("solidworks\\licenses\\serial numbers")
            let hasKnownProduct = SolidWorksProduct.allCases.contains {
                lowered.contains("\"\($0.rawValue.lowercased())\"")
            }
            let hasSecuritySplit = lowered.contains("solidworks\\security") &&
                lowered.contains("\"serial number\"")
            if (hasSerialNumberKey && hasKnownProduct) || hasSecuritySplit {
                return true
            }
        }
        return false
    }
}
