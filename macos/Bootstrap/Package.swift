// swift-tools-version: 5.10

import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let versionsURL = packageDirectory
    .appendingPathComponent("../../config/versions.env")
    .standardizedFileURL
let versionsText = try String(contentsOf: versionsURL, encoding: .utf8)

func versionValue(_ key: String) -> String {
    let prefix = "\(key)="
    guard let line = versionsText.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) else {
        fatalError("Missing \(key) in \(versionsURL.path)")
    }
    return line.dropFirst(prefix.count).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
}

func supportedMacOSVersion(_ value: String) -> SupportedPlatform.MacOSVersion {
    switch value {
    case "13", "13.0": return .v13
    case "14", "14.0": return .v14
    default: fatalError("Unsupported MACOS_DEPLOYMENT_TARGET: \(value)")
    }
}

let minimumMacOS = supportedMacOSVersion(versionValue("MACOS_DEPLOYMENT_TARGET"))

let package = Package(
    name: "MacSW",
    platforms: [.macOS(minimumMacOS)],
    products: [
        .executable(name: "MacSW", targets: ["MacSWApp"]),
        .executable(name: "MacSWCI", targets: ["MacSWCI"]),
        .executable(name: "MacSWCIRuntime", targets: ["MacSWCIRuntime"])
    ],
    targets: [
        // Official SPM artifact, pinned to the checksum in Sparkle's 2.10.0 manifest.
        .binaryTarget(name: "Sparkle",
            url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip",
            checksum: "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"),
        .target(
            name: "MacSWCore",
            path: "Sources/MacSWCore"
        ),
        .executableTarget(
            name: "MacSWApp",
            dependencies: ["MacSWCore", "Sparkle"],
            path: "Sources/MacSWApp",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(
            name: "MacSWCI",
            dependencies: ["MacSWCore"],
            path: "Sources/MacSWCI"
        ),
        .executableTarget(
            name: "MacSWCIRuntime",
            dependencies: ["MacSWCore"],
            path: "Sources/MacSWCIRuntime"
        ),
        .testTarget(
            name: "MacSWCoreTests",
            dependencies: ["MacSWCore"],
            path: "Tests/MacSWCoreTests"
        )
    ]
)
