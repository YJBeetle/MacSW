import Foundation

enum BuildInfo {
    private static func bundleString(_ key: String, fallback: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty,
              !value.hasPrefix("@") else {
            return fallback
        }
        return value
    }

    static let wineVersion = bundleString("MacSWWineVersion", fallback: "unknown")
    static let monoVersion = bundleString("MacSWMonoVersion", fallback: "unknown")
    static let monoPatchSHA256 = bundleString("MacSWMonoPatchSHA256", fallback: "unknown")
}
