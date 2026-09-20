import Foundation
import XCTest
@testable import MacSWCore

final class RuntimeTests: XCTestCase {
    func testEnvironmentIsolationOverridesAndShellQuoting() throws {
        let wine = WineService.shared
        let prefix = URL(fileURLWithPath: "/tmp/MacSW test's bottle")
        let env = wine.environment(winePrefix: prefix, solidWorks: true)

        XCTAssertEqual(env["WINEPREFIX"], prefix.path)
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
        XCTAssertEqual(WineService.solidWorksCompatibilityArguments, [
            "reg", "add", "HKCU\\Software\\Microsoft\\Windows NT\\CurrentVersion\\AppCompatFlags\\Layers",
            "/v", "sldworks.exe", "/t", "REG_SZ", "/d", "WINE_NOCAPTURERESEND", "/f"
        ])
        XCTAssertNil(wine.environment(winePrefix: prefix)["WINEDLLOVERRIDES"])
        XCTAssertEqual(PrerequisiteService.themes.count, 5)
        XCTAssertTrue(WineService.isSuccessfulPrerequisiteStatus(0))
        XCTAssertTrue(WineService.isSuccessfulPrerequisiteStatus(194))
        XCTAssertTrue(WineService.isSuccessfulCleanupStop(killStatus: 1, waitStatus: 0))
        XCTAssertFalse(WineService.isSuccessfulCleanupStop(killStatus: 2, waitStatus: 0))
        XCTAssertFalse(WineService.isSuccessfulCleanupStop(killStatus: 0, waitStatus: 1))

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/bash")
        shell.arguments = ["-c", wine.buildEnvironmentScript(winePrefix: prefix) + "\n[ \"$WINEPREFIX\" = " + WineService.quote(prefix.path) + " ]"]
        XCTAssertEqual(try wine.run(shell), 0)

        let missing = Process()
        missing.executableURL = URL(fileURLWithPath: "/nonexistent/macsw-test")
        XCTAssertThrowsError(try wine.run(missing))
    }

    func testCancellableProcessIsTerminatedPromptly() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        let task = Task { try await WineService.shared.runCancellable(process) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled process unexpectedly completed successfully")
        } catch is CancellationError {
            XCTAssertFalse(process.isRunning)
        }
    }

    func testStopCommandsCoverTheWholeProcessFamily() {
        XCTAssertEqual(
            WineService.taskkillArguments(force: false),
            ["taskkill", "/im", "SLDWORKS.exe", "/im", "sldworks_fs.exe", "/im", "sw_ui_daemon.exe"]
        )
        XCTAssertEqual(WineService.taskkillArguments(force: true).prefix(2), ["taskkill", "/f"])
    }

    func testCapturedOutputSurvivesNonUTF8LocaleBytes() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf 'InprocServer32    REG_SZ    \\304\\253\\277\\275mscoree.dll\\n'"]
        let (status, output) = try await WineService.shared.captureCancellable(process)
        XCTAssertEqual(status, 0)
        XCTAssertTrue(output.contains("mscoree.dll"), "实际捕获: \(output.debugDescription)")
    }
}
