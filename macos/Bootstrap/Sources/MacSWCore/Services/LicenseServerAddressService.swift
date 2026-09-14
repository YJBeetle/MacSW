import Foundation

public enum LicenseServerAddressService {
    public static func parse(_ text: String) throws -> LicenseServerList {
        let rawEntries = text.split(separator: ";", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !rawEntries.isEmpty else { throw LicenseServerAddressError.empty }
        return try LicenseServerList(endpoints: rawEntries.map(parseEntry))
    }

    public static func parseEntry(_ value: String) throws -> LicenseServerEndpoint {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let at = trimmed.firstIndex(of: "@") {
            guard trimmed[trimmed.index(after: at)...].firstIndex(of: "@") == nil else {
                throw LicenseServerAddressError.invalidEntry(value)
            }
            let portText = String(trimmed[..<at])
            let host = String(trimmed[trimmed.index(after: at)...])
            return try endpoint(port: portText, host: host, original: value)
        }

        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]"),
                  trimmed.index(after: close) < trimmed.endIndex,
                  trimmed[trimmed.index(after: close)] == ":" else {
                throw LicenseServerAddressError.invalidEntry(value)
            }
            let host = String(trimmed[...close])
            let portStart = trimmed.index(close, offsetBy: 2)
            return try endpoint(port: String(trimmed[portStart...]), host: host, original: value)
        }

        let colonCount = trimmed.filter { $0 == ":" }.count
        guard colonCount == 1, let colon = trimmed.lastIndex(of: ":") else {
            if colonCount > 1 { throw LicenseServerAddressError.ambiguousIPv6(value) }
            throw LicenseServerAddressError.invalidEntry(value)
        }
        return try endpoint(
            port: String(trimmed[trimmed.index(after: colon)...]),
            host: String(trimmed[..<colon]),
            original: value
        )
    }

    private static func endpoint(port: String, host: String, original: String) throws -> LicenseServerEndpoint {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty, !cleanHost.contains(";") else {
            throw LicenseServerAddressError.invalidEntry(original)
        }
        guard let value = UInt16(port), value > 0 else {
            throw LicenseServerAddressError.invalidPort(port)
        }
        return LicenseServerEndpoint(port: value, host: cleanHost)
    }
}
