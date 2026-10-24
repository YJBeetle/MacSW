import Foundation

/// Finder may send open events before launch finishes, or while a previous file
/// is still opening. Keep one ordered queue and coalesce only pending requests.
@MainActor
public final class DocumentOpenQueue {
    private var pending: [URL] = []
    private var inFlight: URL?
    private var task: Task<Void, Never>?
    private var ready = false
    private let open: @MainActor (URL) async throws -> Void
    private let report: @MainActor (URL, Error) -> Void

    public init(open: @escaping @MainActor (URL) async throws -> Void,
                report: @escaping @MainActor (URL, Error) -> Void) {
        self.open = open
        self.report = report
    }

    public func enqueue(_ urls: [URL]) {
        for url in urls {
            let file = url.standardizedFileURL
            if file != inFlight, !pending.contains(file) { pending.append(file) }
        }
        drainIfReady()
    }

    public func start() {
        ready = true
        drainIfReady()
    }

    public func waitForPending() async {
        if let task { await task.value }
    }

    private func drainIfReady() {
        guard ready, task == nil, !pending.isEmpty else { return }
        task = Task {
            defer { inFlight = nil; task = nil }
            while !pending.isEmpty {
                let file = pending.removeFirst()
                inFlight = file
                do { try await open(file) }
                catch { report(file, error) }
            }
        }
    }
}
