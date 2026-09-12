import Foundation
import XCTest
@testable import MacSWCore

final class RuntimeTests: XCTestCase {
    func testEnvironmentIsolationOverridesAndShellQuoting() throws {
        let wine = WineService.shared
        let prefix = "/tmp/MacSW test's bottle"
        let env = wine.environment(winePrefix: prefix, solidWorks: true)

        XCTAssertEqual(env["WINEPREFIX"], prefix)
        XCTAssertTrue(env["WINELOADER"]?.hasSuffix("/Contents/Frameworks/wine/bin/wineloader") == true)
        XCTAssertTrue(env["WINESERVER"]?.hasSuffix("/Contents/Frameworks/wine/bin/wineserver") == true)
        for key in ["CX_ROOT", "CX_BOTTLE", "WINEDLLPATH", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH", "MONO_ENV_OPTIONS"] {
            XCTAssertNil(env[key], "Inherited environment leaked: \(key)")
        }

        let overrides = try XCTUnwrap(env["WINEDLLOVERRIDES"])
        XCTAssertTrue(overrides.contains("concrt140=n,b"))
        XCTAssertTrue(overrides.contains("atiadlxx=d"))
        XCTAssertFalse(overrides.contains("mscoree"))
        XCTAssertFalse(overrides.contains("d3d11"))
        XCTAssertNil(wine.environment(winePrefix: prefix)["WINEDLLOVERRIDES"])
        XCTAssertEqual(PrerequisiteService.themes.count, 5)

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/bash")
        shell.arguments = ["-c", wine.buildEnvironmentScript(winePrefix: prefix) + "\n[ \"$WINEPREFIX\" = " + WineService.quote(prefix) + " ]"]
        XCTAssertEqual(try wine.run(shell), 0)

        let missing = Process()
        missing.executableURL = URL(fileURLWithPath: "/nonexistent/macsw-test")
        XCTAssertThrowsError(try wine.run(missing))
    }
}
