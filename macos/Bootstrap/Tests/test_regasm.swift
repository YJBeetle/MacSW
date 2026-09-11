import Foundation

@main
struct RegAsmTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MacSW-RegAsm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let runtime = root.appendingPathComponent("runtime")
        let prefix = root.appendingPathComponent("bottle")
        for arch in ["x86_64-windows", "i386-windows"] {
            let source = runtime.appendingPathComponent("lib/wine/\(arch)/regasm.exe")
            try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(arch.utf8).write(to: source)
        }
        try PrerequisiteService.prepareRegAsmCompatibility(runtime: runtime, prefix: prefix)
        try PrerequisiteService.prepareRegAsmCompatibility(runtime: runtime, prefix: prefix)
        let target = prefix.appendingPathComponent("drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/regasm.exe")
        let installed = try Data(contentsOf: target)
        precondition(installed == Data("x86_64-windows".utf8))
        let log = try String(contentsOf: root.appendingPathComponent("logs/regasm-compatibility.log"), encoding: .utf8)
        precondition(log.contains("SKIPPED"))
        try Data("native tool".utf8).write(to: target)
        do {
            try PrerequisiteService.prepareRegAsmCompatibility(runtime: runtime, prefix: prefix)
            preconditionFailure("Must preserve unknown/native tool")
        } catch { }
        let preserved = try Data(contentsOf: target)
        precondition(preserved == Data("native tool".utf8))
        print("PASS: architecture mapping, repeat setup, warning log, native-tool protection")
    }
}
