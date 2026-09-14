import Foundation

public struct AppPaths: Sendable {
    public let appSupportDirectory: URL
    public let bottle: URL
    public let logs: URL
    public let managedFlexNet: URL

    public init(appSupportDirectory: URL) {
        self.appSupportDirectory = appSupportDirectory.standardizedFileURL
        self.bottle = self.appSupportDirectory.appendingPathComponent("bottle", isDirectory: true)
        self.logs = self.appSupportDirectory.appendingPathComponent("logs", isDirectory: true)
        self.managedFlexNet = self.bottle.appendingPathComponent("drive_c/opt/FlexNet", isDirectory: true)
    }

    public static func live(fileManager: FileManager = .default) -> AppPaths {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacSW", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return AppPaths(appSupportDirectory: root)
    }

    public var bottleExists: Bool {
        FileManager.default.fileExists(atPath: bottle.path)
    }

    public var solidWorksExecutable: URL {
        Self.resolveSolidWorksExecutable(in: bottle)
    }

    public var solidWorksInstalled: Bool {
        FileManager.default.fileExists(atPath: solidWorksExecutable.path)
    }

    public static func resolveSolidWorksExecutable(in bottle: URL, fileManager: FileManager = .default) -> URL {
        let systemRegistry = bottle.appendingPathComponent("system.reg")
        if let contents = try? String(contentsOf: systemRegistry, encoding: .utf8) {
            for line in contents.split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.hasPrefix("\"SolidWorks Folder\"="), let separator = text.firstIndex(of: "=") else { continue }
                let value = text[text.index(after: separator)...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\" \r\n"))
                    .replacingOccurrences(of: "\\\\", with: "/")
                    .replacingOccurrences(of: "\\", with: "/")
                guard value.lowercased().hasPrefix("c:/") else { continue }
                let relative = String(value.dropFirst(3)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let candidate = bottle.appendingPathComponent("drive_c")
                    .appendingPathComponent(relative)
                    .appendingPathComponent("SLDWORKS.exe")
                if fileManager.fileExists(atPath: candidate.path) { return candidate }
            }
        }

        let common = [
            "drive_c/Program Files/SOLIDWORKS Corp/SOLIDWORKS/SLDWORKS.exe",
            "drive_c/Program Files/SOLIDWORKS/SLDWORKS.exe"
        ].map { bottle.appendingPathComponent($0) }
        if let existing = common.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            return existing
        }

        let programFiles = bottle.appendingPathComponent("drive_c/Program Files")
        if let enumerator = fileManager.enumerator(
            at: programFiles,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.lastPathComponent.caseInsensitiveCompare("SLDWORKS.exe") == .orderedSame {
                return url
            }
        }
        return common[0]
    }
}
