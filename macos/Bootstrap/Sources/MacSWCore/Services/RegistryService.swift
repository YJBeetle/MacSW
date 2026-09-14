import Foundation

public final class RegistryService {
    private let wine: WineService

    public init(wine: WineService = .shared) {
        self.wine = wine
    }

    public func write(_ assignments: [RegistryAssignment], prefix: URL) async throws {
        let log = wine.logDirectory(prefix.path).appendingPathComponent("registry-write.log")
        for assignment in assignments {
            try Task.checkCancellation()
            let process = wine.makeProcess(arguments: [
                "reg", "add", assignment.key,
                "/v", assignment.name, "/t", "REG_SZ", "/d", assignment.value, "/f"
            ], prefix: prefix.path)
            let code = try await wine.runCancellable(process, log: log)
            guard code == 0 else { throw registryError("写入 \(assignment.key)\\\(assignment.name) 失败（\(code)）。") }
        }
    }

    public func importRegistryFile(_ file: URL, prefix: URL) async throws {
        let process = wine.makeProcess(arguments: ["regedit", "/S", file.path], prefix: prefix.path)
        let code = try await wine.runCancellable(
            process,
            log: wine.logDirectory(prefix.path).appendingPathComponent("registry-import.log")
        )
        guard code == 0 else { throw registryError("注册表文件导入失败（\(code)）。") }
    }

    public func writeLicenseServers(_ servers: LicenseServerList, prefix: URL, serviceName: String? = nil) async throws {
        guard !servers.endpoints.isEmpty else {
            try await clearLicenseServers(prefix: prefix)
            return
        }
        let address = servers.canonical
        var assignments = [
            RegistryAssignment(key: "HKLM\\SOFTWARE\\FLEXlm License Manager", name: "SOLIDWORKS_LICENSE_FILE", value: address),
            RegistryAssignment(key: "HKCU\\Software\\FLEXlm License Manager", name: "SOLIDWORKS_LICENSE_FILE", value: address),
            RegistryAssignment(key: "HKLM\\SOFTWARE\\FLEXlm License Manager", name: "SW_D_LICENSE_FILE", value: address),
            RegistryAssignment(key: "HKCU\\Software\\FLEXlm License Manager", name: "SW_D_LICENSE_FILE", value: address),
            RegistryAssignment(key: "HKCU\\Software\\FLEXlm License Manager", name: "SEEMAGE_LICENSE_FILE", value: address),
            RegistryAssignment(key: "HKLM\\SOFTWARE\\WOW6432Node\\FLEXlm License Manager", name: "SW_D_LICENSE_FILE", value: address)
        ]
        if let serviceName {
            assignments.append(RegistryAssignment(
                key: "HKLM\\SOFTWARE\\WOW6432Node\\FLEXlm License Manager",
                name: "Service",
                value: serviceName
            ))
        }
        try await write(assignments, prefix: prefix)
    }

    public func readLicenseServers(prefix: URL) async -> LicenseServerList {
        let process = wine.makeProcess(arguments: [
            "reg", "query", "HKLM\\SOFTWARE\\FLEXlm License Manager", "/v", "SW_D_LICENSE_FILE"
        ], prefix: prefix)
        guard let (code, output) = try? await wine.captureCancellable(process), code == 0,
              let marker = output.range(of: "REG_SZ", options: .caseInsensitive) else {
            return LicenseServerList(endpoints: [])
        }
        let value = output[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? LicenseServerAddressService.parse(value)) ?? LicenseServerList(endpoints: [])
    }

    public func clearLicenseServers(prefix: URL) async throws {
        let values = [
            ("HKLM\\SOFTWARE\\FLEXlm License Manager", "SOLIDWORKS_LICENSE_FILE"),
            ("HKCU\\Software\\FLEXlm License Manager", "SOLIDWORKS_LICENSE_FILE"),
            ("HKLM\\SOFTWARE\\FLEXlm License Manager", "SW_D_LICENSE_FILE"),
            ("HKCU\\Software\\FLEXlm License Manager", "SW_D_LICENSE_FILE"),
            ("HKCU\\Software\\FLEXlm License Manager", "SEEMAGE_LICENSE_FILE"),
            ("HKLM\\SOFTWARE\\WOW6432Node\\FLEXlm License Manager", "SW_D_LICENSE_FILE")
        ]
        for (key, name) in values {
            let process = wine.makeProcess(arguments: ["reg", "delete", key, "/v", name, "/f"], prefix: prefix)
            _ = try? await wine.runCancellable(process, log: wine.logDirectory(prefix.path).appendingPathComponent("registry-write.log"))
        }
    }

    public func removeManagedServiceMarker(prefix: URL) async {
        let process = wine.makeProcess(arguments: [
            "reg", "delete", "HKLM\\SOFTWARE\\WOW6432Node\\FLEXlm License Manager",
            "/v", "Service", "/f"
        ], prefix: prefix)
        _ = try? await wine.runCancellable(process, log: wine.logDirectory(prefix.path).appendingPathComponent("registry-write.log"))
    }

    private func registryError(_ message: String) -> NSError {
        NSError(domain: "MacSW.Registry", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
