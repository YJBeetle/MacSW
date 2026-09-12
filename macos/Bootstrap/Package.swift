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
    name: "MacSWBootstrap",
    platforms: [.macOS(minimumMacOS)],
    products: [
        .executable(name: "MacSW_Bootstrap", targets: ["MacSWApp"])
    ],
    targets: [
        .target(
            name: "MacSWCore",
            path: ".",
            exclude: ["App", "Tests", "build_bootstrap.sh", "Package.swift"],
            sources: ["Application.swift", "AppState.swift", "BuildInfo.swift", "Services", "Views"]
        ),
        .executableTarget(
            name: "MacSWApp",
            dependencies: ["MacSWCore"],
            path: "App"
        ),
        .testTarget(
            name: "MacSWCoreTests",
            dependencies: ["MacSWCore"],
            path: "Tests/MacSWCoreTests"
        )
    ]
)
