import Foundation

/// 静默安装会一次性走完整个部署，因此必须在做任何改动之前确认介质完整，
/// 避免把用户带到装了一半的状态。
public enum InstallationMedia {
    public struct Component: Equatable, Sendable {
        public let relativePath: String
        public let label: String

        public init(relativePath: String, label: String) {
            self.relativePath = relativePath
            self.label = label
        }
    }

    public static let requiredComponents: [Component] = [
        Component(relativePath: SilentInstallerPlan.coreMSIRelativePath, label: "SOLIDWORKS 主 MSI"),
        Component(
            relativePath: "PreReqs/VCRedist17/VC_redist.x64.exe",
            label: "官方 VC++ x64 运行库"
        ),
        Component(
            relativePath: "swloginmgr/SOLIDWORKS Login Manager.msi",
            label: "SOLIDWORKS Login Manager"
        ),
        Component(
            relativePath: "PreReqs/dotNetFx/ndp48-x86-x64-allos-enu.exe",
            label: "官方 .NET 4.8 安装包（WPF 主题来源）"
        )
    ]

    public static let toolboxDirectory = "Toolbox"

    public static func missingComponents(
        in media: URL,
        language: SolidWorksLanguage?,
        fileManager: FileManager = .default
    ) -> [Component] {
        var missing = requiredComponents.filter { !hasFile(at: media, relativePath: $0.relativePath, fileManager: fileManager) }
        if let language,
           !hasFile(at: media, relativePath: LanguageCatalog.relativeMSIPath(language), fileManager: fileManager) {
            missing.append(Component(
                relativePath: LanguageCatalog.relativeMSIPath(language),
                label: "\(language.displayName) 语言资源"
            ))
        }
        if !hasToolboxPayload(in: media, fileManager: fileManager) {
            missing.append(Component(relativePath: toolboxDirectory, label: "Toolbox 组件库"))
        }
        return missing
    }

    private static func hasFile(at media: URL, relativePath: String, fileManager: FileManager) -> Bool {
        let path = media.appendingPathComponent(relativePath).path
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              (attributes[.type] as? FileAttributeType) == .typeRegular else { return false }
        return (attributes[.size] as? Int) ?? 0 > 0
    }

    private static func hasToolboxPayload(in media: URL, fileManager: FileManager) -> Bool {
        let directory = media.appendingPathComponent(toolboxDirectory)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        return entries.contains { url in
            guard url.pathExtension.caseInsensitiveCompare("zip") == .orderedSame,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { return false }
            return (values.fileSize ?? 0) > 0
        }
    }
}
