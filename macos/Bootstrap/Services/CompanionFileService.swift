import Foundation

/// Search only the selected item's siblings. Never recurse or inspect file contents.
enum CompanionFileService {
    struct Matches {
        var registry: URL?
        var license: URL?
        var patch: URL?
    }

    static func findSiblings(of selected: URL) -> Matches {
        let fm = FileManager.default
        guard selected.isFileURL,
              let entries = try? fm.contentsOfDirectory(at: selected.deletingLastPathComponent(),
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return Matches()
        }
        var registry: [URL] = [], license: [URL] = [], patch: [URL] = []
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else { continue }
            let name = entry.lastPathComponent.lowercased()
            if values.isDirectory == true {
                if name == "solidworks corp" { patch.append(entry) }
                if name == "solidworks_flexnet_server" { license.append(entry) }
            } else if values.isRegularFile == true,
                      name.hasPrefix("sw"), name.hasSuffix("_network_serials_licensing.reg") {
                registry.append(entry)
            }
        }
        // Ambiguous siblings remain unselected, rather than silently picking a version.
        return Matches(registry: registry.count == 1 ? registry.first : nil,
                       license: license.count == 1 ? license.first : nil,
                       patch: patch.count == 1 ? patch.first : nil)
    }
}
