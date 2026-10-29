import Darwin
import Foundation

/// Shared by normal quit and update installation. All snapshots are strict;
/// native signals additionally require live prefix and PID-generation proof.
struct ContainerShutdownService: Sendable {
    let snapshot: @Sendable () async throws -> [WineProcess]
    let stopServer: @Sendable () async throws -> Void
    let signal: @Sendable (WineProcess, Int32) async throws -> Void
    var pause: @Sendable () async throws -> Void = { try await Task.sleep(nanoseconds: 250_000_000) }
    var serverTimeout: UInt64 = 10_000_000_000

    private func checked(protectMain: Bool) async throws -> [WineProcess] {
        try Task.checkCancellation()
        let processes = try await snapshot()
        if protectMain, ProcessInventory.isSolidWorksRunning(processes) {
            throw MacSWError.make("SOLIDWORKS 仍在运行，请先保存文档并退出。", domain: "MacSW.Shutdown")
        }
        return processes
    }

    func stop(protectMain: Bool) async throws {
        var remaining = try await checked(protectMain: protectMain)
        guard !remaining.isEmpty else { return }
        // Give helpers a normal TERM grace period; leave the server alive so
        // clients can finish their own shutdown before the prefix-wide stop.
        for process in remaining where process.name.lowercased() != "wineserver" {
            _ = try await checked(protectMain: protectMain)
            try await signal(process, SIGTERM)
        }
        for _ in 0..<8 {
            remaining = try await checked(protectMain: protectMain)
            if remaining.isEmpty { return }
            if remaining.allSatisfy({ $0.name.lowercased() == "wineserver" }) { break }
            try await pause()
        }
        _ = try await checked(protectMain: protectMain)
        do { try await boundedServerStop() }
        catch { try Task.checkCancellation() } // Native cleanup still handles a stuck helper/server.
        remaining = try await checked(protectMain: protectMain)
        for process in remaining {
            _ = try await checked(protectMain: protectMain)
            try await signal(process, SIGKILL)
        }
        for _ in 0..<8 {
            remaining = try await checked(protectMain: protectMain)
            if remaining.isEmpty { return }
            try await pause()
        }
        remaining = try await checked(protectMain: protectMain)
        guard !remaining.isEmpty else { return }
        throw MacSWError.make("容器仍有无法结束的进程：" + remaining.map { "\($0.name)（\($0.pid)）" }.joined(separator: "、"),
                              domain: "MacSW.Shutdown")
    }

    private func boundedServerStop() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await stopServer() }
            group.addTask {
                try await Task.sleep(nanoseconds: serverTimeout)
                throw MacSWError.make("停止容器超时。", domain: "MacSW.Shutdown")
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}
