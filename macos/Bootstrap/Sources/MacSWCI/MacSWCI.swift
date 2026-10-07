import Foundation
import MacSWCore

/// Test-only entrypoint, copied into a private CI clone of the built app.
/// It is never packaged in the distributed MacSW.app.
@main
struct MacSWCI {
    @MainActor
    static func main() async {
        do {
            try await run()
        } catch {
            // MSI logs contain serials; keep those logs private, even on failure.
            let message = sanitized(error.localizedDescription)
            if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
               let temporary = ProcessInfo.processInfo.environment["RUNNER_TEMP"] {
                let directory = URL(fileURLWithPath: temporary).resolvingSymlinksInPath()
                    .appendingPathComponent("MacSW-runtime/evidence")
                try? writeEvidence(["completed": false, "error": message], directory: directory, name: "setup-failure.json")
            }
            FileHandle.standardError.write(Data("MacSW CI failed: \(message)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["GITHUB_ACTIONS"] == "true", let temporary = env["RUNNER_TEMP"] else {
            throw failure("This entrypoint only runs on a GitHub Actions runner.")
        }
        let root = URL(fileURLWithPath: temporary).resolvingSymlinksInPath()
            .appendingPathComponent("MacSW-runtime", isDirectory: true)
        guard Bundle.main.bundleURL.resolvingSymlinksInPath().path == root.appendingPathComponent("MacSW.app").path else {
            throw failure("Only the isolated CI App bundle is allowed.")
        }
        let paths = AppPaths(appSupportDirectory: root.appendingPathComponent("app-support"))
        let wine = WineService.shared
        let licensing = LicenseServerStore(paths: paths)
        let evidence = root.appendingPathComponent("evidence")
        switch CommandLine.arguments.dropFirst().first {
        case "install":
            guard !paths.bottleExists else { throw failure("CI requires a fresh bottle; refusing to reuse one.") }
            guard let media = env["MACSW_CI_MEDIA"], let assetsPath = env["MACSW_CI_ASSETS"],
                  let serial = env["SW_SERIAL_SOLIDWORKS"], !serial.isEmpty else {
                throw failure("Missing CI installation inputs.")
            }
            let mediaURL = URL(fileURLWithPath: media).resolvingSymlinksInPath()
            guard mediaURL.deletingLastPathComponent().path == root.appendingPathComponent("media-mount").path,
                  mediaURL.pathExtension.lowercased() == "iso",
                  URL(fileURLWithPath: assetsPath).resolvingSymlinksInPath().path == root.appendingPathComponent("private/assets").path else {
                throw failure("Only isolated private installation inputs are allowed.")
            }
            let assets = URL(fileURLWithPath: assetsPath)
            let candidates = FlexNetLocator.discover(in: assets)
            guard candidates.count == 1, let flexNet = candidates.first else {
                throw failure("CI assets must contain exactly one FlexNet package.")
            }
            let check = await licensing.checkedPackage(at: flexNet)
            guard case .ready = check else { throw failure("CI FlexNet package did not pass validation.") }
            let bootstrap = BootstrapStore(paths: paths, licensing: licensing)
            bootstrap.selectMedia(URL(fileURLWithPath: media))
            while bootstrap.isInspectingMedia { try await Task.sleep(nanoseconds: 100_000_000) }
            bootstrap.serials = InstallSerials(values: [.solidWorks: serial])
            bootstrap.silentInstall = true
            let language = env["MACSW_CI_LANGUAGE"] ?? "chinese-simplified"
            if language == "english" {
                bootstrap.selectedLanguage = nil
            } else {
                guard let selected = LanguageCatalog.official.first(where: { $0.directoryName == language }) else {
                    throw failure("Unsupported CI language.")
                }
                bootstrap.selectedLanguage = selected
            }
            // The reusable official base must contain no private license package.
            // The same Core licensing path runs in the separate fixtures stage.
            bootstrap.licenseMode = .unconfigured
            guard bootstrap.canStart else { throw failure(bootstrap.startHint ?? "Installation inputs are not ready.") }
            bootstrap.start()
            var previous: InstallationState?
            while bootstrap.state.isActive {
                if previous != bootstrap.state {
                    print("CI installation: \(bootstrap.state)")
                    previous = bootstrap.state
                    try writeInstallationEvidence(bootstrap, directory: evidence)
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            try writeInstallationEvidence(bootstrap, directory: evidence)
            guard bootstrap.state == .completed else { throw failure(bootstrap.statusMessage) }
            try writeEvidence(["completed": true, "fixture_ready": false], directory: evidence, name: "setup.json")
            print("CI fresh official installation completed.")
        case "fixtures":
            guard paths.solidWorksInstalled, let assetsPath = env["MACSW_CI_ASSETS"],
                  URL(fileURLWithPath: assetsPath).resolvingSymlinksInPath().path == root.appendingPathComponent("private/assets").path else {
                throw failure("Missing isolated installation or private fixtures.")
            }
            let assets = URL(fileURLWithPath: assetsPath)
            let candidates = FlexNetLocator.discover(in: assets)
            guard candidates.count == 1, let flexNet = candidates.first else {
                throw failure("CI assets must contain exactly one FlexNet package.")
            }
            let check = await licensing.checkedPackage(at: flexNet)
            guard case .ready = check else { throw failure("CI FlexNet package did not pass validation.") }
            try await licensing.configureDuringInstallation(address: "", flexNetSource: flexNet)
            // These are CI-only private fixtures, never a product installer feature.
            let overlay = assets.appendingPathComponent("SOLIDWORKS Corp/SOLIDWORKS")
            guard FileManager.default.fileExists(atPath: overlay.path) else { throw failure("CI application fixture missing.") }
            let files = try overlayFiles(in: overlay)
            let destination = paths.solidWorksExecutable.deletingLastPathComponent()
            let copy = Process()
            copy.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            copy.arguments = [overlay.path, destination.path]
            guard try await wine.runCancellable(copy) == 0 else { throw failure("CI fixture copy failed.") }
            var verifiedBytes = 0
            for file in files {
                let relative = String(file.path.dropFirst(overlay.path.count + 1))
                let installed = destination.appendingPathComponent(relative)
                guard installed.resolvingSymlinksInPath().path.hasPrefix(paths.bottle.path + "/"),
                      FileManager.default.contentsEqual(atPath: file.path, andPath: installed.path) else {
                    throw failure("CI application fixture verification failed.")
                }
                verifiedBytes += try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            }
            // Aggregate proof only: never publish fixture names, license data or binaries.
            try writeEvidence(["completed": true, "verified_files": files.count, "verified_bytes": verifiedBytes],
                              directory: evidence, name: "fixture-copy.json")
            let registrations = try FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.lowercased().hasSuffix("serials_licensing.reg") }
            guard !registrations.isEmpty else { throw failure("CI licensing fixture missing.") }
            for registration in registrations {
                // Restored bases deliberately have no runner-root/Z: mapping.
                // Import from the bottle's own C: instead of passing a Unix path.
                let name = "MacSW-CI-\(UUID().uuidString).reg"
                let local = paths.bottle.appendingPathComponent("drive_c/windows/temp").appendingPathComponent(name)
                try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: registration, to: local)
                defer { try? FileManager.default.removeItem(at: local) }
                let process = wine.makeProcess(arguments: ["reg", "import", "C:\\windows\\temp\\\(name)"], prefix: paths.bottle)
                guard try await wine.runCancellable(process) == 0 else { throw failure("CI fixture registry import failed.") }
            }
            await licensing.refreshInstallation()
            guard let installed = licensing.installation else { throw failure("CI managed FlexNet missing.") }
            try await licensing.configureDuringInstallation(address: installed.managedAddress, flexNetSource: nil)
            // The orchestrator unmounts the read-only remote and deletes sparse
            // VFS blocks after installation. Never delete the remote ISO itself.
            try writeEvidence(["completed": true, "fixture_ready": true], directory: evidence, name: "setup.json")
            print("CI temporary runtime fixtures prepared.")
        case "prepare":
            guard paths.solidWorksInstalled else { throw failure("No CI installation to prepare.") }
            await licensing.refreshInstallation()
            guard licensing.isInstalled else { throw failure("No CI managed FlexNet installation.") }
            try await licensing.ensureRunningIfNeeded()
            // Exactly the App startup preparation path, with no auto-launch.
            let runtime = RuntimeStore(paths: paths, licenseServer: licensing)
            await runtime.startup(autoLaunch: false)
            guard runtime.statusMessage.isEmpty else { throw failure(runtime.statusMessage) }
            let registry = RegistryService()
            let clsid = await registry.solidWorksApplicationCLSID(prefix: paths.bottle)
            var queries: [[String: Any]] = []
            var keys = [#"HKCR\SldWorks.Application"#]
            if let clsid { keys.append("HKCR\\CLSID\\\(clsid)") }
            for key in keys {
                let result = try await wine.capturePairCancellable(
                    wine.makeProcess(arguments: ["reg", "query", key, "/s", "/reg:64"], prefix: paths.bottle)
                )
                queries.append(["key": key, "exit_code": result.status,
                                "stdout": result.standardOutput, "stderr": result.standardError])
            }
            try writeEvidence(["clsid": clsid ?? "", "queries": queries],
                              directory: evidence, name: "com-registration.json")
            guard let clsid else { throw failure("CI fixture/startup stage lost SldWorks.Application registration.") }
            let missing = await registry.missingCOMRegistrations(
                at: "HKCR\\CLSID\\\(clsid)", requires: InstallerDiagnostics.solidWorksRequirements,
                prefix: paths.bottle
            )
            guard missing.isEmpty else { throw failure("CI COM registration missing: \(missing.joined(separator: ", ")).") }
            print("CI App startup font preparation completed.")
        case "cleanup":
            guard paths.bottleExists else { return }
            guard try await wine.stopWineServerForCleanup(prefix: paths.bottle) else {
                throw failure("CI Wine server did not stop.")
            }
        default:
            throw failure("Usage: MacSWCI install|fixtures|prepare|cleanup")
        }
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "MacSW.CI", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func overlayFiles(in directory: URL) throws -> [URL] {
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw failure("CI application fixture links are not allowed.")
        }
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        var enumerationFailed = false
        guard let entries = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: Array(keys), errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }
        ) else { throw failure("CI application fixture cannot be enumerated.") }
        var files: [URL] = []
        for case let entry as URL in entries {
            let values = try entry.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw failure("CI application fixture links are not allowed.") }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw failure("CI application fixture contains a special file.") }
            files.append(entry)
        }
        guard !enumerationFailed, !files.isEmpty else { throw failure("CI application fixture is empty or unreadable.") }
        return files
    }

    static func sanitized(_ text: String) -> String {
        let serial = ProcessInfo.processInfo.environment["SW_SERIAL_SOLIDWORKS"] ?? ""
        var message = text
        for value in [serial, InstallSerials.normalized(serial)] where !value.isEmpty {
            message = message.replacingOccurrences(of: value, with: "[REDACTED]")
        }
        return message.replacingOccurrences(
            of: #"(?i)[A-Z0-9]{4}(?:[- \t]*[A-Z0-9]{4}){5}"#,
            with: "[REDACTED]", options: .regularExpression
        )
    }

    @MainActor
    static func writeInstallationEvidence(_ bootstrap: BootstrapStore, directory: URL) throws {
        var statuses: [String: String] = [:]
        var details: [String: String] = [:]
        for step in InstallationStep.allCases {
            statuses[step.title] = bootstrap.stepStatuses[step]?.rawValue
            details[step.title] = bootstrap.stepDetails[step].map(sanitized)
        }
        try writeEvidence([
            "completed": bootstrap.state == .completed,
            "state": sanitized(String(describing: bootstrap.state)),
            "steps": statuses, "details": details
        ], directory: directory, name: "installation.json")
    }

    static func writeEvidence(_ record: [String: Any], directory: URL, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
