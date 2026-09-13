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
    static let monoMscorlibSHA256 = bundleString("MacSWMonoMscorlibSHA256", fallback: "unknown")
    static let monoRegAsmX86SHA256 = bundleString("MacSWMonoRegAsmX86SHA256", fallback: "unknown")
    static let monoRegAsmX64SHA256 = bundleString("MacSWMonoRegAsmX64SHA256", fallback: "unknown")
    static let stdoleVersion = bundleString("MacSWStdoleVersion", fallback: "unknown")
    static let stdoleSHA256 = bundleString("MacSWStdoleSHA256", fallback: "unknown")
}
