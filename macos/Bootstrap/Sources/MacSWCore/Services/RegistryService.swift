import Foundation

public final class RegistryService {
    private let wine: WineService

    public init(wine: WineService = .shared) {
        self.wine = wine
    }

    /// 一次 reg import 顶掉逐条 reg add：每次 wine 进程启动就要 6 秒左右，
    /// 逐条写六个值能把一次点击拖成四十秒。
    public func write(_ assignments: [RegistryAssignment], prefix: URL) async throws {
        try await importRegistry(assignments, prefix: prefix)
    }

    private func importRegistry(_ assignments: [RegistryAssignment], prefix: URL) async throws {
        guard !assignments.isEmpty else { return }
        let name = "MacSW-\(UUID().uuidString).reg"
        let insideBottle = prefix.appendingPathComponent("drive_c/windows/temp").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: insideBottle.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.registryFileText(assignments).write(to: insideBottle, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: insideBottle) }
        let process = wine.makeProcess(
            arguments: ["reg", "import", "C:\\windows\\temp\\\(name)"],
            prefix: prefix
        )
        let log = wine.logDirectory(prefix.path).appendingPathComponent("registry-write.log")
        let code = try await wine.runCancellable(process, log: log)
        guard code == 0 else { throw registryError("导入注册表失败（\(code)）。") }
    }

    static func registryFileText(_ assignments: [RegistryAssignment]) -> String {
        var lines = ["Windows Registry Editor Version 5.00", ""]
        let grouped = Dictionary(grouping: assignments, by: { $0.key })
        for key in grouped.keys.sorted() {
            lines.append("[\(Self.fullHive(key))]")
            for assignment in (grouped[key] ?? []).sorted(by: { $0.name < $1.name }) {
                lines.append("\"\(Self.escape(assignment.name))\"=\"\(Self.escape(assignment.value))\"")
            }
            lines.append("")
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func fullHive(_ key: String) -> String {
        for (short, full) in [("HKLM\\", "HKEY_LOCAL_MACHINE\\"), ("HKCU\\", "HKEY_CURRENT_USER\\")] where key.hasPrefix(short) {
            return full + key.dropFirst(short.count)
        }
        return key
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// 托管 COM 只有注册表内容才算证据；查询失败按全部缺失处理。
    public func missingCOMRegistrations(
        at path: String,
        requires: [String],
        prefix: URL
    ) async -> [String] {
        let process = wine.makeProcess(arguments: ["reg", "query", path, "/s"], prefix: prefix)
        guard let (status, output) = try? await wine.captureCancellable(process), status == 0 else {
            return requires
        }
        return InstallerDiagnostics.missingRequirements(output: output, required: requires)
    }

    public func solidWorksApplicationCLSID(prefix: URL) async -> String? {
        let process = wine.makeProcess(
            arguments: ["reg", "query", #"HKCR\SldWorks.Application\CLSID"#, "/ve"],
            prefix: prefix
        )
        guard let (_, output) = try? await wine.captureCancellable(process) else { return nil }
        return InstallerDiagnostics.registeredCLSID(fromQuery: output)
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

    /// 清空即写空串（跟刚装完的容器状态一致），六个值一次导入搞定。
    public func clearLicenseServers(prefix: URL, includingServiceMarker: Bool = false) async throws {
        var assignments = Self.licenseValueTargets.map { RegistryAssignment(key: $0.key, name: $0.name, value: "") }
        if includingServiceMarker {
            assignments.append(RegistryAssignment(key: Self.serviceKey, name: "Service", value: ""))
        }
        try await importRegistry(assignments, prefix: prefix)
    }

    static let serviceKey = "HKLM\\SOFTWARE\\WOW6432Node\\FLEXlm License Manager"

    static let licenseValueTargets: [(key: String, name: String)] = [
        ("HKLM\\SOFTWARE\\FLEXlm License Manager", "SOLIDWORKS_LICENSE_FILE"),
        ("HKCU\\Software\\FLEXlm License Manager", "SOLIDWORKS_LICENSE_FILE"),
        ("HKLM\\SOFTWARE\\FLEXlm License Manager", "SW_D_LICENSE_FILE"),
        ("HKCU\\Software\\FLEXlm License Manager", "SW_D_LICENSE_FILE"),
        ("HKCU\\Software\\FLEXlm License Manager", "SEEMAGE_LICENSE_FILE"),
        ("HKLM\\SOFTWARE\\WOW6432Node\\FLEXlm License Manager", "SW_D_LICENSE_FILE")
    ]

    private func registryError(_ message: String) -> NSError {
        NSError(domain: "MacSW.Registry", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
