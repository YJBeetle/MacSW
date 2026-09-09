import Foundation

class IsoService {
    static let shared = IsoService()

    func mountIso(at isoUrl: URL) -> String? {
        let task = Process()
        task.launchPath = "/usr/bin/hdiutil"
        task.arguments = ["attach", isoUrl.path, "-nobrowse", "-plist"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.launch()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let entities = plist["system-entities"] as? [[String: Any]] {
            for entity in entities {
                if let mountPoint = entity["mount-point"] as? String {
                    return mountPoint
                }
            }
        }
        return nil
    }

    func unmount(mountPoint: String) {
        let task = Process()
        task.launchPath = "/usr/bin/hdiutil"
        task.arguments = ["detach", mountPoint, "-force"]
        task.launch()
        task.waitUntilExit()
    }

    func findSetupExe(in directoryPath: String) -> String? {
        let fileManager = FileManager.default
        let candidates = [
            directoryPath + "/swwi/data/solidworks.msi",
            directoryPath + "/sldim/sldIM.exe",
            directoryPath + "/setup.exe"
        ]
        for candidate in candidates {
            if fileManager.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
