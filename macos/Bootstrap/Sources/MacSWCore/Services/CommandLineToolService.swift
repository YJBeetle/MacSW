import Foundation

/// The global entry is only a link to this App's launcher, never a copied runtime.
public struct CommandLineToolService: Sendable {
    public enum State: Equatable, Sendable {
        case notInstalled
        case installed
        case conflict(String)
    }

    public enum Operation: Sendable { case install, uninstall }

    public let launcher: URL
    public let command: URL

    public init(bundleURL: URL = Bundle.main.bundleURL,
                command: URL = URL(fileURLWithPath: "/usr/local/bin/sw-cli")) {
        launcher = bundleURL.appendingPathComponent("Contents/MacOS/sw-cli").standardizedFileURL
        self.command = command.standardizedFileURL
    }

    public func status() -> State {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: command.path)
            guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
                return .conflict("\(command.path) 已有其他文件，未改动。")
            }
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: command.path)
            let resolved = URL(fileURLWithPath: target, relativeTo: command.deletingLastPathComponent())
                .standardizedFileURL
            guard resolved == launcher else {
                return .conflict("\(command.path) 指向其他位置：\(target)")
            }
            return .installed
        } catch CocoaError.fileReadNoSuchFile {
            return .notInstalled
        } catch {
            return .conflict("无法检查 \(command.path)：\(error.localizedDescription)")
        }
    }

    public func perform(_ operation: Operation) async throws {
        try validate(operation)
        do {
            try apply(operation)
        } catch {
            guard Self.needsAuthorization(error) else { throw error }
            // The privileged command rechecks ownership after the authorization dialog.
            let command = try shellCommand(for: operation)
            try await Self.authorize(command)
        }
        let expected: State = operation == .install ? .installed : .notInstalled
        guard status() == expected else {
            throw Self.failure("命令行工具状态已变化，请重新检查。")
        }
    }

    private func validate(_ operation: Operation) throws {
        if case let .conflict(detail) = status() { throw Self.failure(detail) }
        if operation == .install, !FileManager.default.isExecutableFile(atPath: launcher.path) {
            throw Self.failure("当前 App 的 sw-cli 启动器缺失或不可执行，请重新安装 MacSW。")
        }
    }

    private func apply(_ operation: Operation) throws {
        try validate(operation)
        switch (operation, status()) {
        case (.install, .notInstalled):
            try FileManager.default.createDirectory(at: command.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            // No replace/remove: creation fails if another tool appeared in the meantime.
            try FileManager.default.createSymbolicLink(at: command, withDestinationURL: launcher)
        case (.uninstall, .installed):
            try FileManager.default.removeItem(at: command)
        default:
            break
        }
    }

    /// Only mkdir/link/unlink run with privileges; no App/Python/Wine code runs as root.
    func shellCommand(for operation: Operation) throws -> String {
        try validate(operation)
        let destination = Self.quote(command.path)
        let source = Self.quote(launcher.path)
        let existingTarget = (try? FileManager.default.destinationOfSymbolicLink(atPath: command.path))
            ?? launcher.path
        guard URL(fileURLWithPath: existingTarget, relativeTo: command.deletingLastPathComponent())
            .standardizedFileURL == launcher else {
            throw Self.failure("命令入口已指向其他位置，未改动。")
        }
        let owned = "[ -L \(destination) ] && [ \"$(/usr/bin/readlink \(destination))\" = \(Self.quote(existingTarget)) ]"
        let occupied = "[ -e \(destination) ] || [ -L \(destination) ]"
        let conflict = "/usr/bin/printf '%s\\n' 'sw-cli 已有其他文件或链接，未改动。' >&2; exit 1"
        switch operation {
        case .install:
            return """
            set -eu
            if \(occupied); then
                \(owned) || { \(conflict); }
            else
                /bin/mkdir -p \(Self.quote(command.deletingLastPathComponent().path))
                /bin/ln -s \(source) \(destination)
            fi
            """
        case .uninstall:
            return """
            set -eu
            if \(occupied); then
                \(owned) || { \(conflict); }
                /bin/rm \(destination)
            fi
            """
        }
    }

    static func needsAuthorization(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
           [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(error.code) { return true }
        if error.domain == NSPOSIXErrorDomain, [Int(EACCES), Int(EPERM)].contains(error.code) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return needsAuthorization(underlying)
        }
        return false
    }

    private static func authorize(_ command: String) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            // The shell command is argv data, not interpolated AppleScript source.
            process.arguments = ["-e", """
            on run argv
                do shell script (item 1 of argv) with administrator privileges
            end run
            """, command]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw failure(detail.isEmpty ? "未完成命令行工具安装或卸载。" : detail)
            }
        }.value
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func failure(_ message: String) -> NSError {
        MacSWError.make(message, domain: "MacSW.CommandLineTool")
    }
}
