import Foundation
import XCTest
@testable import MacSWCore

final class CommandLineToolTests: XCTestCase {
    private func fixture() throws -> CommandLineToolService {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacSW-CLI-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("App ' $(not-a-command) `literal` 中文.app")
        let launcher = app.appendingPathComponent("Contents/MacOS/swcli")
        try FileManager.default.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        return CommandLineToolService(bundleURL: app, command: root.appendingPathComponent("bin space '/swcli"))
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
            .deletingLastPathComponent().lastPathComponent + "/Contents/MacOS/swcli"
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
        try FileManager.default.createSymbolicLink(atPath: service.command.path, withDestinationPath: "/foreign/swcli")
        XCTAssertNotEqual(try run(script), 0)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: service.command.path), "/foreign/swcli")
    }

    func testOnlyPermissionFailuresCanRequestAdministratorPrivileges() {
        XCTAssertTrue(CommandLineToolService.needsAuthorization(CocoaError(.fileWriteNoPermission)))
        XCTAssertTrue(CommandLineToolService.needsAuthorization(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        let nested = NSError(domain: "test", code: 1, userInfo: [NSUnderlyingErrorKey: CocoaError(.fileWriteNoPermission)])
        XCTAssertTrue(CommandLineToolService.needsAuthorization(nested))
        XCTAssertFalse(CommandLineToolService.needsAuthorization(CocoaError(.fileWriteFileExists)))
        XCTAssertFalse(CommandLineToolService.needsAuthorization(CocoaError(.fileNoSuchFile)))
    }

    func testDefaultCommandHasOnlyTheNewName() {
        let service = CommandLineToolService(bundleURL: URL(fileURLWithPath: "/Applications/MacSW.app"))
        XCTAssertEqual(service.command.path, "/usr/local/bin/swcli")
        XCTAssertEqual(service.launcher.path, "/Applications/MacSW.app/Contents/MacOS/swcli")
    }

    func testInstallMigratesDanglingOwnedLegacyLinkWithoutAddingAnAlias() async throws {
        let service = try fixture()
        try makeLegacyLink(service)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.legacyLauncher.path))
        XCTAssertEqual(service.status(), .legacyInstalled)
        try await service.perform(.install)
        XCTAssertEqual(service.status(), .installed)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: service.legacyCommand.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: service.command.path), service.launcher.path)
    }

    func testRelativeOwnedLegacyLinkIsMigratedWithQuotedPaths() async throws {
        let service = try fixture()
        let appName = service.legacyLauncher.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().lastPathComponent
        try makeLegacyLink(service, target: "../" + appName + "/Contents/MacOS/sw-cli")
        XCTAssertEqual(service.status(), .legacyInstalled)
        try await service.perform(.install)
        XCTAssertEqual(service.status(), .installed)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: service.legacyCommand.path))
    }

    func testExistingNewEntryStillOffersLegacyCleanup() async throws {
        let service = try fixture()
        try await service.perform(.install)
        try makeLegacyLink(service)
        XCTAssertEqual(service.status(), .legacyInstalled)
        try await service.perform(.install)
        XCTAssertEqual(service.status(), .installed)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: service.command.path))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: service.legacyCommand.path))
    }

    func testUninstallRemovesOwnedLegacyEntryEvenWithoutNewEntry() async throws {
        let service = try fixture()
        try makeLegacyLink(service)
        try await service.perform(.uninstall)
        XCTAssertEqual(service.status(), .notInstalled)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: service.legacyCommand.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: service.launcher.path))
    }

    func testForeignLegacyEntriesArePreservedWhileNewCommandInstallsAndUninstalls() async throws {
        for kind in ["file", "directory", "foreign-link", "other-app-link"] {
            let service = try fixture()
            try FileManager.default.createDirectory(at: service.legacyCommand.deletingLastPathComponent(), withIntermediateDirectories: true)
            let foreignTarget = kind == "other-app-link" ? "/Applications/Other MacSW.app/Contents/MacOS/sw-cli" : "/foreign/sw-cli"
            switch kind {
            case "file": try Data("user command".utf8).write(to: service.legacyCommand)
            case "directory": try FileManager.default.createDirectory(at: service.legacyCommand, withIntermediateDirectories: true)
            default: try FileManager.default.createSymbolicLink(atPath: service.legacyCommand.path, withDestinationPath: foreignTarget)
            }
            try await service.perform(.install)
            XCTAssertEqual(service.status(), .installed)
            try await service.perform(.uninstall)
            XCTAssertEqual(service.status(), .notInstalled)
            if kind == "file" { XCTAssertEqual(try String(contentsOf: service.legacyCommand), "user command") }
            else if kind == "directory" { XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: service.legacyCommand.path), []) }
            else { XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: service.legacyCommand.path), foreignTarget) }
        }
    }

    func testPrimaryConflictDoesNotRemoveTheOwnedLegacyEntry() async throws {
        let service = try fixture()
        try makeLegacyLink(service)
        try Data("other tool".utf8).write(to: service.command)
        do {
            try await service.perform(.install)
            XCTFail("Replaced other tool")
        } catch {
            XCTAssertEqual(try String(contentsOf: service.command), "other tool")
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: service.legacyCommand.path), service.legacyLauncher.path)
        }
    }

    func testPrivilegedScriptsMigrateAndRemoveOwnedLegacyLinks() throws {
        for operation in [CommandLineToolService.Operation.install, .uninstall] {
            let service = try fixture()
            try makeLegacyLink(service)
            XCTAssertEqual(try run(service.shellCommand(for: operation)), 0)
            XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: service.legacyCommand.path))
            XCTAssertEqual(service.status(), operation == .install ? .installed : .notInstalled)
            XCTAssertTrue(FileManager.default.fileExists(atPath: service.launcher.path))
        }
    }

    func testInstallScriptPreservesLegacyLinkReplacedAfterAuthorization() throws {
        let service = try fixture()
        try makeLegacyLink(service)
        let script = try service.shellCommand(for: .install)
        try FileManager.default.removeItem(at: service.legacyCommand)
        try FileManager.default.createSymbolicLink(atPath: service.legacyCommand.path, withDestinationPath: "/foreign/sw-cli")
        XCTAssertEqual(try run(script), 0)
        XCTAssertEqual(service.status(), .installed)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: service.legacyCommand.path), "/foreign/sw-cli")
    }

    func testUninstallScriptPreservesLegacyFileReplacedAfterAuthorization() throws {
        let service = try fixture()
        XCTAssertEqual(try run(service.shellCommand(for: .install)), 0)
        try makeLegacyLink(service)
        let script = try service.shellCommand(for: .uninstall)
        try FileManager.default.removeItem(at: service.legacyCommand)
        try Data("new user executable".utf8).write(to: service.legacyCommand)
        XCTAssertEqual(try run(script), 0)
        XCTAssertEqual(service.status(), .notInstalled)
        XCTAssertEqual(try String(contentsOf: service.legacyCommand), "new user executable")
    }

    private func makeLegacyLink(_ service: CommandLineToolService, target: String? = nil) throws {
        try FileManager.default.createDirectory(at: service.legacyCommand.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: service.legacyCommand.path,
                                                 withDestinationPath: target ?? service.legacyLauncher.path)
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
