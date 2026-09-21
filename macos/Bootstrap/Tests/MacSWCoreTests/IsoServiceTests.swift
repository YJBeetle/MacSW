import Foundation
import XCTest
@testable import MacSWCore

final class IsoServiceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSW-ISO-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func shell(_ script: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        return process
    }

    /// plist 解析器只能看到标准输出：混进 stderr 告警会让整段解析失败。
    func testCaptureKeepsStderrOutOfStandardOutput() async throws {
        let capture = try await WineService.shared.capturePairCancellable(
            shell("printf 'warning: noisy\\n' >&2; printf '<plist>ok</plist>'")
        )
        XCTAssertEqual(capture.status, 0)
        XCTAssertEqual(capture.standardOutput, "<plist>ok</plist>")
        XCTAssertEqual(capture.standardError, "warning: noisy\n")
    }

    /// 超过管道缓冲的输出必须在等待退出前抽干，否则子进程与父进程互等。
    func testCaptureDrainsLargeOutputWithoutDeadlocking() async throws {
        let capture = try await WineService.shared.capturePairCancellable(
            shell("i=0; while [ $i -lt 4000 ]; do printf 'line-%s-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\n' $i; i=$((i+1)); done")
        )
        XCTAssertEqual(capture.status, 0)
        XCTAssertEqual(capture.standardOutput.split(separator: "\n").count, 4000)
    }

    func testExistingMountPointIgnoresMissingAndDirectoryPaths() async throws {
        let iso = IsoService()
        let missing = directory.appendingPathComponent("absent.dmg")
        let fromMissing: URL? = try? await iso.existingMountPoint(of: missing)
        XCTAssertNil(fromMissing)
        let fromDirectory: URL? = try? await iso.existingMountPoint(of: directory)
        XCTAssertNil(fromDirectory)
    }

    func testUnmountSkipsVolumesWeDidNotMount() {
        // 别人（Finder、上一次运行）挂好的卷不能替用户推出；0 表示"没动手，也算成功"。
        let unmounted = directory.appendingPathComponent("not-mounted")
        XCTAssertEqual(IsoService().unmount(MountedMedia(mountPoint: unmounted, isOurs: false)), 0)
        XCTAssertNotEqual(IsoService().unmount(MountedMedia(mountPoint: unmounted, isOurs: true)), 0)
    }
}
