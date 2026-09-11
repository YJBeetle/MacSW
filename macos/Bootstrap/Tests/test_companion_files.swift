import Foundation

@main
struct CompanionFileTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MacSW-companion-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let patch = root.appendingPathComponent("SOLIDWORKS Corp")
        let license = root.appendingPathComponent("SolidWorks_Flexnet_Server")
        let registry = root.appendingPathComponent("sw2025_network_serials_licensing.reg")
        try fm.createDirectory(at: patch, withIntermediateDirectories: true)
        try fm.createDirectory(at: license, withIntermediateDirectories: true)
        try Data().write(to: registry)
        for selected in [patch, license, registry] {
            let match = CompanionFileService.findSiblings(of: selected)
            precondition(match.patch?.lastPathComponent == patch.lastPathComponent)
            precondition(match.license?.lastPathComponent == license.lastPathComponent)
            precondition(match.registry?.lastPathComponent == registry.lastPathComponent)
        }
        // Do not scan children or choose arbitrarily when multiple versions match.
        let nested = root.appendingPathComponent("nested")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("sw2030_network_serials_licensing.reg"))
        precondition(CompanionFileService.findSiblings(of: patch).registry != nil)
        let second = root.appendingPathComponent("sw2024_network_serials_licensing.reg")
        try Data().write(to: second)
        precondition(CompanionFileService.findSiblings(of: patch).registry == nil)
        try fm.removeItem(at: second)
        try fm.removeItem(at: registry)
        try fm.createDirectory(at: registry, withIntermediateDirectories: true)
        precondition(CompanionFileService.findSiblings(of: patch).registry == nil)
        print("PASS: all three entry points, sibling-only scope, ambiguity and file type checks")
    }
}
