import Foundation
import XCTest
@testable import MacSWCore

final class RuntimeTests: XCTestCase {
    func testEnvironmentIsolationKeepsHostOutOfWineEnvironment() throws {
        let wine = WineService.shared
        let prefix = URL(fileURLWithPath: "/tmp/MacSW test's bottle")
        let env = wine.environment(winePrefix: prefix, solidWorks: true)

        XCTAssertEqual(env["WINEPREFIX"], prefix.path)
        XCTAssertTrue(env["WINELOADER"]?.hasSuffix("/Contents/Frameworks/wine/lib/wine/x86_64-unix/MacSW") == true)
        XCTAssertTrue(env["WINESERVER"]?.hasSuffix("/Contents/Frameworks/wine/bin/wineserver") == true)
        for key in [
            "CX_ROOT", "CX_BOTTLE", "WINEDLLPATH", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH",
            "MONO_ENV_OPTIONS", "MACSW_WINELOADER", "MACSW_APP_NAME"
        ] {
            XCTAssertNil(env[key], "Inherited environment leaked: \(key)")
        }

        let overrides = try XCTUnwrap(env["WINEDLLOVERRIDES"])
        XCTAssertTrue(overrides.contains("concrt140=n,b"))
        XCTAssertTrue(overrides.contains("atiadlxx=d"))
        XCTAssertFalse(overrides.contains("mscoree"))
        XCTAssertFalse(overrides.contains("d3d11"))
        XCTAssertNil(wine.environment(winePrefix: prefix)["WINEDLLOVERRIDES"])
        XCTAssertEqual(PrerequisiteService.themes.count, 5)
        XCTAssertTrue(WineService.isSuccessfulPrerequisiteStatus(0))
        XCTAssertTrue(WineService.isSuccessfulPrerequisiteStatus(194))
        XCTAssertTrue(WineService.isSuccessfulCleanupStop(killStatus: 1, waitStatus: 0))
        XCTAssertFalse(WineService.isSuccessfulCleanupStop(killStatus: 2, waitStatus: 0))
        XCTAssertFalse(WineService.isSuccessfulCleanupStop(killStatus: 0, waitStatus: 1))

        let missing = Process()
        missing.executableURL = URL(fileURLWithPath: "/nonexistent/macsw-test")
        XCTAssertThrowsError(try wine.run(missing))
    }

    func testCommandPromptTerminalCommandQuotesTheBottlePath() {
        let wine = WineService.shared
        let prefix = URL(fileURLWithPath: "/tmp/MacSW test's bottle")
        let command = wine.commandPromptTerminalCommand(prefix: prefix)

        XCTAssertTrue(command.hasPrefix("env WINEPREFIX='/tmp/MacSW test'\\''s bottle' "))
        XCTAssertTrue(command.contains("WINELOADER='\(wine.wineBinary.path)'"))
        XCTAssertTrue(command.contains("WINESERVER='\(wine.wineServerBinary.path)'"))
        XCTAssertTrue(command.hasSuffix(" 'C:\\windows\\system32\\cmd.exe'"))
    }

    func testKnownWineToolsUseExplicitWindowsPathsWithoutChangingExternalExecutables() {
        XCTAssertEqual(
            WineService.resolvingSystemTool(in: ["reg", "query", "HKCU\\Software"]),
            [#"C:\windows\system32\reg.exe"#, "query", "HKCU\\Software"]
        )
        XCTAssertEqual(
            WineService.resolvingSystemTool(in: ["MSIEXEC", "/i", "installer.msi"]),
            [#"C:\windows\system32\msiexec.exe"#, "/i", "installer.msi"]
        )
        XCTAssertEqual(
            WineService.resolvingSystemTool(in: ["/media/VC_redist.x64.exe", "/quiet"]),
            ["/media/VC_redist.x64.exe", "/quiet"]
        )
        XCTAssertEqual(WineService.resolvingSystemTool(in: []), [])
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

    /// 已取消的任务里再调取消安全包装会直接抛错，所以"取消后收尾"不能就地跑。
    func testCancelledScopeRefusesToStartNewProcesses() async {
        let task = Task { () -> Bool in
            try? await Task.sleep(nanoseconds: 50_000_000)
            do {
                _ = try await WineService.shared.runCancellable(Process())
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        task.cancel()
        let threw = await task.value
        XCTAssertTrue(threw)
    }

    /// `Task.detached` 不继承取消，这就是清理安装进程时用的逃生通道。
    func testDetachedTaskSurvivesParentCancellation() async {
        let task = Task { () -> Bool in
            try? await Task.sleep(nanoseconds: 50_000_000)
            return await Task.detached {
                try? await Task.sleep(nanoseconds: 2_000_000)
                return !Task.isCancelled
            }.value
        }
        task.cancel()
        let survived = await task.value
        XCTAssertTrue(survived)
    }

    /// 轮询观测要与用户意图合并，不能反向覆盖。
    func testPollingNeverOverridesUserIntent() {
        let failed = SolidWorksRuntimeState.failed("启动失败")
        XCTAssertEqual(SolidWorksRuntimeState.starting.applying(observedRunning: false, installed: true), .starting)
        XCTAssertEqual(SolidWorksRuntimeState.starting.applying(observedRunning: true, installed: true), .running)
        XCTAssertEqual(SolidWorksRuntimeState.stopping.applying(observedRunning: true, installed: true), .stopping)
        XCTAssertEqual(SolidWorksRuntimeState.stopping.applying(observedRunning: false, installed: true), .stopped)
        XCTAssertEqual(SolidWorksRuntimeState.stopping.applying(observedRunning: false, installed: false), .unavailable)
        XCTAssertEqual(failed.applying(observedRunning: false, installed: true), failed)
        XCTAssertEqual(failed.applying(observedRunning: true, installed: true), .running)
        // 没有意图的状态一律以观测为准。
        XCTAssertEqual(SolidWorksRuntimeState.unknown.applying(observedRunning: false, installed: true), .stopped)
        XCTAssertEqual(SolidWorksRuntimeState.running.applying(observedRunning: false, installed: false), .unavailable)
    }

    /// 进程状态只有退出码的低 8 位：3010 = 0xBC2 → 194，1638 = 0x666 → 102。
    /// 两边都归一之后再比，列表里写四位码还是写截断值都不会漏判。
    func testInstallerStatusesCompareTheLowEightBits() {
        XCTAssertTrue(WineService.isSuccessfulPrerequisiteStatus(0))
        XCTAssertTrue(WineService.isSuccessfulPrerequisiteStatus(194), "3010 需要重启")
        XCTAssertTrue(WineService.isSuccessfulPrerequisiteStatus(102), "1638 另一个安装进行中")
        XCTAssertTrue(WineService.isSuccessfulInstallerStatus(194))
        XCTAssertFalse(WineService.isSuccessfulInstallerStatus(67))
        XCTAssertTrue(WineService.isCancelledInstallerStatus(66), "1602 用户取消")
        XCTAssertTrue(WineService.isCancelledInstallerStatus(15), "SIGTERM")
        XCTAssertFalse(WineService.isCancelledInstallerStatus(16))
    }

    func testMSIReturnCodeComesFromTheVerboseLog() {
        let log = """
        Action ended 22:20:18: InstallFinalPackage. Return value 3.
        MSI (s) (CC:2C) [12:34:56:789]: MainEngineThread is returning 1603
        """
        XCTAssertEqual(InstallerDiagnostics.msiReturnCode(log), 1603)
        XCTAssertNil(InstallerDiagnostics.msiReturnCode("Action ended. Return value 1."))
    }

    /// 日志是追加写的，不设上限就会一直长到几 MB。
    func testOversizedLogIsRestartedBeforeAppending() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("wineboot.log")
        try Data(repeating: 0x41, count: Int(WineService.maximumLogBytes) + 1).write(to: log)
        let handle = try XCTUnwrap(WineService.shared.logHandle(for: log))
        XCTAssertEqual(try? log.resourceValues(forKeys: [.fileSizeKey]).fileSize, 0)
        try? handle.close()

        let fresh = directory.appendingPathComponent("fresh.log")
        XCTAssertNotNil(try WineService.shared.logHandle(for: fresh))
        XCTAssertNil(try WineService.shared.logHandle(for: nil))
    }

    func testStopCommandsCoverTheWholeProcessFamily() {
        XCTAssertEqual(
            WineService.taskkillArguments(force: false),
            ["taskkill", "/im", "SLDWORKS.exe", "/im", "sldworks_fs.exe"]
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
