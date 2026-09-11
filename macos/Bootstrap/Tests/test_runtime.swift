import Foundation

@main
struct RuntimeTests {
    static func main() throws {
        let wine = WineService.shared
        let prefix = "/tmp/MacSW test's bottle"
        let env = wine.environment(winePrefix: prefix, solidWorks: true)
        precondition(env["WINEPREFIX"] == prefix)
        precondition(env["WINELOADER"]!.hasSuffix("/Contents/Frameworks/wine/bin/wineloader"))
        precondition(env["WINESERVER"]!.hasSuffix("/Contents/Frameworks/wine/bin/wineserver"))
        for key in ["CX_ROOT", "CX_BOTTLE", "WINEDLLPATH", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH", "MONO_ENV_OPTIONS"] {
            precondition(env[key] == nil, "Inherited environment leaked: \(key)")
        }
        let overrides = env["WINEDLLOVERRIDES"]!
        precondition(overrides.contains("concrt140=n,b"))
        precondition(overrides.contains("atiadlxx=d"))
        precondition(!overrides.contains("mscoree"))
        precondition(!overrides.contains("d3d11"))
        precondition(wine.environment(winePrefix: prefix)["WINEDLLOVERRIDES"] == nil)
        precondition(PrerequisiteService.themes.count == 5)
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/bash")
        shell.arguments = ["-c", wine.buildEnvironmentScript(winePrefix: prefix) + "\n[ \"$WINEPREFIX\" = " + WineService.quote(prefix) + " ]"]
        let shellResult = try wine.run(shell)
        precondition(shellResult == 0)
        let missing = Process()
        missing.executableURL = URL(fileURLWithPath: "/nonexistent/macsw-test")
        do { _ = try wine.run(missing); preconditionFailure("Expected launch error") } catch { }
        print("PASS: bundle-only runtime, environment isolation, VC overrides, shell quoting, launch errors")
    }
}
