import Foundation
import XCTest
@testable import MacSWCore

final class CommandLineToolTests: XCTestCase {
    private func fixture() throws -> CommandLineToolService {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-CLI-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("App ' $(not-a-command) `literal` 中文.app")
        let launcher = app.appendingPathComponent("Contents/MacOS/sw-cli")
        try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        return CommandLineToolService(bundleURL: app, command: root.appendingPathComponent("bin space '/sw-cli"))
    }

    func testInstallUpdateAtSameLocationAndUninstallOnlyChangeTheLink() async throws {
        let service = try fixture()
        XCTAssertEqual(service.status(), .notInstalled)
        try await service.perform(.install)
        try await service.perform(.install)
        XCTAssertEqual(service.status(), .installed)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: service.command.path), service.launcher.path)
        let updated = Data("#!/bin/sh\n# updated App\nexit 0\n".utf8)
        try updated.write(to: service.launcher, options: .atomic)
        XCTAssertEqual(try Data(contentsOf: service.command), updated)
        try await service.perform(.uninstall)
        try await service.perform(.uninstall)
        XCTAssertEqual(service.status(), .notInstalled)
        XCTAssertEqual(try Data(contentsOf: service.launcher), updated)
    }

    func testForeignFileDirectoryAndBrokenLinkCannotBeInstalledOverOrRemoved() async throws {
        for kind in ["file", "directory", "broken-link"] {
            let service = try fixture()
            try FileManager.default.createDirectory(at: service.command.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch kind {
            case "file": try Data("foreign command".utf8).write(to: service.command)
            case "directory": try FileManager.default.createDirectory(at: service.command, withIntermediateDirectories: true)
            default: try FileManager.default.createSymbolicLink(atPath: service.command.path, withDestinationPath: "/missing/foreign-command")
            }
            guard case .conflict = service.status() else { return XCTFail("Accepted foreign \(kind)") }
            for operation in [CommandLineToolService.Operation.install, .uninstall] {
                do {
                    try await service.perform(operation)
                    XCTFail("Modified foreign \(kind)")
                } catch {
                    XCTAssertEqual((error as NSError).domain, "MacSW.CommandLineTool")
                }
            }
            if kind == "file" { XCTAssertEqual(try String(contentsOf: service.command), "foreign command") }
            else if kind == "broken-link" {
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: service.command.path), "/missing/foreign-command")
            } else {
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: service.command.path), [])
            }
        }
    }

    func testMissingLauncherIsRejectedBeforeCreatingGlobalDirectory() async throws {
        let service = try fixture()
        try FileManager.default.removeItem(at: service.launcher)
        do {
            try await service.perform(.install)
            XCTFail("Installed missing launcher")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: service.command.deletingLastPathComponent().path))
        }
    }

    func testRelativeLinkToThisAppCanBeUninstalledWithoutFollowingIt() async throws {
        let service = try fixture()
        try FileManager.default.createDirectory(at: service.command.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = "../" + service.launcher.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().lastPathComponent + "/Contents/MacOS/sw-cli"
        try FileManager.default.createSymbolicLink(atPath: service.command.path, withDestinationPath: target)
        XCTAssertEqual(service.status(), .installed)
        try await service.perform(.uninstall)
        XCTAssertTrue(FileManager.default.fileExists(atPath: service.launcher.path))
        XCTAssertEqual(service.status(), .notInstalled)
    }

    func testPrivilegedOperationScriptsTreatQuotesAndShellMetacharactersAsPaths() throws {
        let service = try fixture()
        XCTAssertEqual(try run(service.shellCommand(for: .install)), 0)
        XCTAssertEqual(service.status(), .installed)
        XCTAssertEqual(try run(service.shellCommand(for: .install)), 0)
        XCTAssertEqual(try run(service.shellCommand(for: .uninstall)), 0)
        XCTAssertEqual(service.status(), .notInstalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: service.launcher.path))
    }

    func testInstallScriptRechecksConflictAfterAuthorization() throws {
        let service = try fixture()
        let script = try service.shellCommand(for: .install)
        try FileManager.default.createDirectory(at: service.command.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("appeared during authorization".utf8).write(to: service.command)
        XCTAssertNotEqual(try run(script), 0)
        XCTAssertEqual(try String(contentsOf: service.command), "appeared during authorization")
    }

    func testUninstallScriptRechecksLinkOwnerAfterAuthorization() throws {
        let service = try fixture()
        XCTAssertEqual(try run(service.shellCommand(for: .install)), 0)
        let script = try service.shellCommand(for: .uninstall)
        try FileManager.default.removeItem(at: service.command)
        try FileManager.default.createSymbolicLink(atPath: service.command.path, withDestinationPath: "/foreign/sw-cli")
        XCTAssertNotEqual(try run(script), 0)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: service.command.path), "/foreign/sw-cli")
    }

    func testOnlyPermissionFailuresCanRequestAdministratorPrivileges() {
        XCTAssertTrue(CommandLineToolService.needsAuthorization(CocoaError(.fileWriteNoPermission)))
        XCTAssertTrue(CommandLineToolService.needsAuthorization(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        let nested = NSError(domain: "test", code: 1, userInfo: [NSUnderlyingErrorKey: CocoaError(.fileWriteNoPermission)])
        XCTAssertTrue(CommandLineToolService.needsAuthorization(nested))
        XCTAssertFalse(CommandLineToolService.needsAuthorization(CocoaError(.fileWriteFileExists)))
        XCTAssertFalse(CommandLineToolService.needsAuthorization(CocoaError(.fileNoSuchFile)))
    }

    private func run(_ script: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
