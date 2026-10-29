import Darwin
import Foundation
import XCTest
@testable import MacSWCore

final class ContainerShutdownTests: XCTestCase {
    private actor World {
        var processes: [WineProcess]
        var events: [String] = []
        var reads = 0
        var mainAppearsOnRead: Int?
        var cooperative = false
        var hangServer = false
        var ignoreSignals = false

        init(_ processes: [WineProcess]) { self.processes = processes }
        func configure(cooperative: Bool = false, hangServer: Bool = false,
                       mainAppearsOnRead: Int? = nil, ignoreSignals: Bool = false) {
            self.cooperative = cooperative
            self.hangServer = hangServer
            self.mainAppearsOnRead = mainAppearsOnRead
            self.ignoreSignals = ignoreSignals
        }
        func snapshot() -> [WineProcess] {
            reads += 1
            if mainAppearsOnRead == reads {
                processes.append(WineProcess(name: "SLDWORKS.exe", pid: 99, residentKB: 1, elapsed: "00:01"))
            }
            return processes
        }
        func signal(_ process: WineProcess, _ signal: Int32) {
            events.append("\(process.pid):\(signal)")
            if !ignoreSignals && (signal == SIGKILL || cooperative) {
                processes.removeAll { $0.pid == process.pid }
            }
        }
        func server() async throws {
            events.append("server")
            if hangServer {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) }
                catch { events.append("server-cancelled"); throw error }
            }
        }
        func recordedEvents() -> [String] { events }
    }

    private var helper: WineProcess {
        WineProcess(name: "sldworks_fs.exe", pid: 42, residentKB: 1, elapsed: "1-02:03:04", startIdentity: 123)
    }

    private func service(_ world: World) -> ContainerShutdownService {
        ContainerShutdownService(snapshot: { await world.snapshot() }, stopServer: { try await world.server() },
                                 signal: { process, signal in await world.signal(process, signal) },
                                 pause: {}, serverTimeout: 10_000_000)
    }

    func testCooperativeHelperExitsWithoutForcedStop() async throws {
        let world = World([helper])
        await world.configure(cooperative: true)
        try await service(world).stop(protectMain: true)
        let events = await world.recordedEvents()
        XCTAssertEqual(events, ["42:\(SIGTERM)"])
    }

    func testStubbornHelperAndHungServerAreBoundedThenKilled() async throws {
        let world = World([helper])
        await world.configure(hangServer: true)
        try await service(world).stop(protectMain: true)
        let events = await world.recordedEvents()
        XCTAssertEqual(events, ["42:\(SIGTERM)", "server", "server-cancelled", "42:\(SIGKILL)"])
    }

    func testMainProcessAppearingDuringGraceBlocksForce() async throws {
        let world = World([helper])
        await world.configure(mainAppearsOnRead: 3)
        do { try await service(world).stop(protectMain: true); XCTFail("must preserve the new CAD session") }
        catch { XCTAssertTrue(error.localizedDescription.contains("SOLIDWORKS")) }
        let events = await world.recordedEvents()
        XCTAssertEqual(events, ["42:\(SIGTERM)"])
    }

    func testFailedObservationCannotBeTreatedAsAnEmptyContainer() async {
        let world = World([helper])
        let cleanup = ContainerShutdownService(snapshot: { throw NSError(domain: "ps", code: 1) },
            stopServer: { try await world.server() }, signal: { p, s in await world.signal(p, s) }, pause: {})
        do { try await cleanup.stop(protectMain: true); XCTFail("observation must fail closed") } catch { }
        let events = await world.recordedEvents()
        XCTAssertTrue(events.isEmpty)
    }

    func testSurvivorsDoNotProduceAFalseSuccessfulExit() async {
        let world = World([helper])
        await world.configure(ignoreSignals: true)
        do { try await service(world).stop(protectMain: true); XCTFail("still running") }
        catch { XCTAssertTrue(error.localizedDescription.contains("sldworks_fs.exe")) }
    }

    private func launchHelper(prefix: URL, name: String, ignoreTERM: Bool = false) throws -> Process {
        // macOS hides KERN_PROCARGS2 environments for platform binaries such
        // as /bin/sleep. Use our own tiny executable so ownership is genuinely
        // proven from WINEPREFIX, just as it is for the bundled Wine clients.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("macsw-exit-helper-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("helper.c")
        let executable = root.appendingPathComponent("helper")
        try "#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [source.path, "-o", executable.path]
        try compiler.run()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else { throw NSError(domain: "helper-compile", code: 1) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        let script = (ignoreTERM ? "trap '' TERM; " : "") + "exec -a \"$1\" \"$2\""
        process.arguments = ["--noprofile", "--norc", "-c", script, "shutdown-test", name, executable.path]
        process.environment = ["WINEPREFIX": prefix.path, "PATH": "/usr/bin:/bin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let identity = ProcessInventory.startIdentity(pid: process.processIdentifier)
        addTeardownBlock {
            if process.isRunning, identity == ProcessInventory.startIdentity(pid: process.processIdentifier) {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: root)
        }
        return process
    }

    private func observe(_ process: Process, prefix: URL) async throws -> WineProcess {
        for _ in 0..<50 {
            let result = try await ProcessInventory.snapshotForUpdate(bottlePath: prefix.path, wineRuntimePath: "")
            if let found = result.first(where: { $0.pid == process.processIdentifier && $0.name == process.arguments?[5] }) {
                return found
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(domain: "missing-helper", code: 1)
    }

    func testNativeSignalsCheckGenerationAndOtherPrefixBeforeSignalling() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("macsw-shutdown-\(UUID())")
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        let a = try launchHelper(prefix: first, name: "sldworks_fs.exe")
        let b = try launchHelper(prefix: second, name: "python.exe")
        let target = try await observe(a, prefix: first)
        _ = try await observe(b, prefix: second)
        let generation = try XCTUnwrap(target.startIdentity)
        try await ProcessInventory.signalAuxiliary(target, signal: SIGKILL, bottlePath: second.path, wineRuntimePath: "")
        let reused = WineProcess(name: target.name, pid: target.pid, residentKB: 0, elapsed: "00:01", startIdentity: generation + 1)
        try await ProcessInventory.signalAuxiliary(reused, signal: SIGKILL, bottlePath: first.path, wineRuntimePath: "")
        XCTAssertTrue(a.isRunning)
        XCTAssertTrue(b.isRunning)
        try await ProcessInventory.signalAuxiliary(target, signal: SIGTERM, bottlePath: first.path, wineRuntimePath: "")
        a.waitUntilExit()
        XCTAssertFalse(a.isRunning)
        XCTAssertTrue(b.isRunning)
    }

    func testNativeFallbackNeverSignalsTheMainProcess() async throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("macsw-main-\(UUID())")
        let main = try launchHelper(prefix: prefix, name: "SLDWORKS.exe")
        let target = try await observe(main, prefix: prefix)
        try await ProcessInventory.signalAuxiliary(target, signal: SIGKILL, bottlePath: prefix.path, wineRuntimePath: "")
        XCTAssertTrue(main.isRunning)
    }

    func testNativeStubbornHelperIsKilledAndTheOtherContainerSurvives() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("macsw-stubborn-\(UUID())")
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        let a = try launchHelper(prefix: first, name: "sldworks_fs.exe", ignoreTERM: true)
        let b = try launchHelper(prefix: second, name: "python.exe")
        _ = try await observe(a, prefix: first)
        _ = try await observe(b, prefix: second)
        let cleanup = ContainerShutdownService(
            snapshot: { try await ProcessInventory.snapshotForUpdate(bottlePath: first.path, wineRuntimePath: "") },
            stopServer: { try await Task.sleep(nanoseconds: 60_000_000_000) },
            signal: { process, signal in
                try await ProcessInventory.signalAuxiliary(process, signal: signal, bottlePath: first.path, wineRuntimePath: "")
            }, pause: { try await Task.sleep(nanoseconds: 10_000_000) }, serverTimeout: 10_000_000)
        try await cleanup.stop(protectMain: true)
        a.waitUntilExit()
        XCTAssertFalse(a.isRunning)
        XCTAssertTrue(b.isRunning)
    }
}
