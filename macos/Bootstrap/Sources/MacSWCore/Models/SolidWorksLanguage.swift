import Foundation

public struct SolidWorksLanguage: Identifiable, Hashable, Sendable {
    public let directoryName: String
    public let msiFileName: String
    public let displayName: String

    public init(directoryName: String, msiFileName: String, displayName: String) {
        self.directoryName = directoryName
        self.msiFileName = msiFileName
        self.displayName = displayName
    }

    public var id: String { directoryName }
}

public enum LanguageCatalog {
    public static let relativeDirectory = "swwi/lang"
    public static let preferredDirectoryName = "chinese-simplified"

    private static let displayNames: [String: String] = [
        "chinese": "繁體中文",
        "chinese-simplified": "简体中文",
        "czech": "čeština",
        "dutch": "Nederlands",
        "english": "English",
        "french": "français",
        "german": "Deutsch",
        "italian": "italiano",
        "japanese": "日本語",
        "korean": "한국어",
        "polish": "polski",
        "portuguese-brazilian": "português (Brasil)",
        "russian": "русский",
        "spanish": "español",
        "turkish": "Türkçe"
    ]

    public static func displayName(for directoryName: String) -> String {
        displayNames[directoryName.lowercased()] ?? directoryName
    }

    public static func discover(in media: URL, fileManager: FileManager = .default) -> [SolidWorksLanguage] {
        let root = media.appendingPathComponent(relativeDirectory)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { directory -> SolidWorksLanguage? in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let name = directory.lastPathComponent
            guard let msi = languageMSI(in: directory, name: name, fileManager: fileManager) else { return nil }
            return SolidWorksLanguage(
                directoryName: name,
                msiFileName: msi,
                displayName: displayName(for: name)
            )
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public static func preferred(from languages: [SolidWorksLanguage]) -> SolidWorksLanguage? {
        languages.first { $0.directoryName.caseInsensitiveCompare(preferredDirectoryName) == .orderedSame }
            ?? languages.first
    }

    public static func relativeMSIPath(_ language: SolidWorksLanguage) -> String {
        "\(relativeDirectory)/\(language.directoryName)/\(language.msiFileName)"
    }

    private static func languageMSI(in directory: URL, name: String, fileManager: FileManager) -> String? {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let files = entries.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        let expected = "\(name).msi"
        if let match = files.first(where: {
            $0.lastPathComponent.caseInsensitiveCompare(expected) == .orderedSame
        }) {
            return match.lastPathComponent
        }
        return files
            .filter { $0.pathExtension.caseInsensitiveCompare("msi") == .orderedSame }
            .map(\.lastPathComponent)
            .sorted()
            .first
    }
}
