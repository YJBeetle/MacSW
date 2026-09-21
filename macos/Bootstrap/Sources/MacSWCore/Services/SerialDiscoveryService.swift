import Foundation

public struct SerialDiscoveryResult: Equatable, Sendable {
    public var serials = InstallSerials()
    public var sources: [InstallSerialField: URL] = [:]
    public var ambiguousFields: [InstallSerialField] = []
    public var scannedFiles: [URL] = []

    public var isEmpty: Bool { serials.isEmpty && ambiguousFields.isEmpty }
}

/// 从介质同级与子级的文本/注册表文件里匹配序列号，供安装界面回填；
/// 只读取与匹配，不导入注册表。
public enum SerialDiscoveryService {
    public static let maximumTextFileSize = 1_048_576
    public static let maximumCandidateFiles = 200
    /// 只扫当前级与一级子级。
    public static let maximumWalkDepth = 2
    public static let textFileExtensions: Set<String> = [
        "txt", "reg", "lic", "license", "key", "keys", "serial", "csv", "md"
    ]

    private struct Candidate {
        let url: URL
        let rootIndex: Int
        let depth: Int
    }

    public static func discover(
        in roots: [URL],
        fileManager: FileManager = .default
    ) -> SerialDiscoveryResult {
        var result = SerialDiscoveryResult()
        var matches: [InstallSerialField: [(value: String, source: URL)]] = [:]

        for file in candidateFiles(in: roots, fileManager: fileManager) {
            result.scannedFiles.append(file)
            guard let data = try? Data(contentsOf: file),
                  let text = PlainTextDecoder.decode(data),
                  let parsed = try? SerialNumberService.parse(text) else { continue }
            for (product, value) in parsed.values {
                guard let field = InstallSerialField.forProduct(product) else { continue }
                if let first = matches[field], first.contains(where: { $0.value == value }) { continue }
                matches[field, default: []].append((value: value, source: file))
            }
        }

        for field in InstallSerialField.allCases {
            guard let found = matches[field], !found.isEmpty else { continue }
            if Set(found.map(\.value)).count > 1 {
                result.ambiguousFields.append(field)
                continue
            }
            result.serials[field] = found[0].value
            result.sources[field] = found[0].source
        }
        return result
    }

    public static func candidateFiles(
        in roots: [URL],
        fileManager: FileManager = .default
    ) -> [URL] {
        var seen = Set<String>()
        var candidates: [Candidate] = []

        for (rootIndex, root) in roots.enumerated() {
            let rootPath = root.standardizedFileURL.path
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                let relative = url.standardizedFileURL.path.dropFirst(rootPath.count + 1)
                let depth = relative.split(separator: "/").count
                if depth > maximumWalkDepth {
                    enumerator.skipDescendants()
                    continue
                }
                guard textFileExtensions.contains(url.pathExtension.lowercased()),
                      seen.insert(url.standardizedFileURL.path).inserted,
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true,
                      (values.fileSize ?? maximumTextFileSize + 1) <= maximumTextFileSize else { continue }
                candidates.append(Candidate(url: url, rootIndex: rootIndex, depth: depth))
                if candidates.count >= maximumCandidateFiles {
                    return sorted(candidates)
                }
            }
        }
        return sorted(candidates)
    }

    private static func sorted(_ candidates: [Candidate]) -> [URL] {
        candidates.sorted { left, right in
            if left.rootIndex != right.rootIndex { return left.rootIndex < right.rootIndex }
            if left.depth != right.depth { return left.depth < right.depth }
            return left.url.path.localizedCaseInsensitiveCompare(right.url.path) == .orderedAscending
        }.map(\.url)
    }
}
