import Foundation

/// Finish the official Toolbox deployment separately from the x86 MSI host.
/// WPF's x64 window setup fails under Mono interpreter mode; do not change the
/// interpreter setting used by the other installer/RegAsm processes.
public final class ToolboxService: @unchecked Sendable {
    private let wine: WineService

    public init(wine: WineService = .shared) { self.wine = wine }

    public func install(media: URL, paths: AppPaths) async throws -> Int {
        let rootPath = try Self.configuredDataPath(prefix: paths.bottle)
        let mapping = wine.makeProcess(arguments: ["winepath", "-u", rootPath], prefix: paths.bottle)
        let (mappingStatus, output) = try await wine.captureCancellable(mapping)
        let hostPath = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mappingStatus == 0, hostPath.hasPrefix("/"), !hostPath.contains("\n"),
              !hostPath.contains("\u{FFFD}") else {
            throw Self.failure("无法解析已配置的 Toolbox 数据目录。")
        }
        let root = URL(fileURLWithPath: hostPath)
        let selected = try Self.selectedStandards(in: root)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("lang/english/swbrowser.sldedb").path) else {
            throw Self.failure("Toolbox 数据库缺失，不能仅凭 MSI 成功继续安装。")
        }
        let executable = paths.solidWorksExecutable.deletingLastPathComponent().appendingPathComponent("sldtoolboxupdater.exe")
        let archives = media.appendingPathComponent(InstallationMedia.toolboxDirectory)
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw Self.failure("官方 Toolbox 更新工具缺失。")
        }
        for standard in selected {
            guard FileManager.default.fileExists(atPath: archives.appendingPathComponent(standard.source).path) else {
                throw Self.failure("介质缺少 Toolbox 标准件包：\(standard.source)。")
            }
        }
        let archivePath = try await wine.windowsPath(for: archives, prefix: paths.bottle)
        let process = makeUpdater(executable: executable, dataPath: rootPath, archivesPath: archivePath, prefix: paths.bottle)
        let code = try await wine.runCancellable(process, log: paths.logs.appendingPathComponent("toolbox-install.log"))
        guard code == 0 else {
            throw Self.failure("Toolbox 标准件部署失败（\(code)），请查看 toolbox-install.log；未标记安装成功。")
        }
        return try await Task.detached { try Self.validate(root: root, standards: selected) }.value
    }

    func makeUpdater(executable: URL, dataPath: String, archivesPath: String, prefix: URL) -> Process {
        let process = wine.makeProcess(arguments: [executable.path, dataPath, archivesPath, "TRUE"], prefix: prefix)
        process.environment?["WINE_MONO_AOT"] = "none"
        return process
    }

    struct Standard: Equatable, Sendable {
        let name: String
        let source: String
    }

    /// Read the official installation's choice rather than hard-code a year or
    /// override the folder selected in the interactive wizard. Ambiguity fails
    /// closed instead of silently writing into another version's data folder.
    static func configuredDataPath(prefix: URL) throws -> String {
        for hive in ["user.reg", "system.reg"] {
            guard let data = try? Data(contentsOf: prefix.appendingPathComponent(hive)),
                  let text = PlainTextDecoder.decode(data) else { continue }
            let paths = dataPaths(in: text)
            if paths.count == 1 { return paths[0] }
            if paths.count > 1 { throw failure("存在多个 Toolbox 数据目录，无法安全选择部署目标。") }
        }
        throw failure("官方安装没有记录 Toolbox 数据目录。")
    }

    static func dataPaths(in registry: String) -> [String] {
        var general = false
        var paths = Set<String>()
        for line in registry.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("[") {
                general = text.hasPrefix(#"[Software\\SolidWorks\\SOLIDWORKS "#)
                    && text.contains(#"\\General]"#)
            } else if general, text.hasPrefix("\"Toolbox Data Location\"=\""), text.hasSuffix("\"") {
                let value = String(text.dropFirst("\"Toolbox Data Location\"=\"".count).dropLast())
                    .replacingOccurrences(of: "\\\\", with: "\\")
                if value.count > 3, WineService.parsedWindowsPath(value) != nil { paths.insert(value) }
            }
        }
        return paths.sorted()
    }

    private final class StandardsParser: NSObject, XMLParserDelegate {
        var element = ""
        var values: [String: String] = [:]
        var standards: [Standard] = []
        var rootElement: String?
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            if rootElement == nil { rootElement = name }
            element = name
            if name == "Standard" { values = [:] }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { values[element, default: ""] += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "Standard", values["Install"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "yes" {
                standards.append(Standard(name: values["Name", default: ""].trimmingCharacters(in: .whitespacesAndNewlines),
                                          source: values["Source", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            element = ""
        }
    }

    static func selectedStandards(in root: URL) throws -> [Standard] {
        let parser = XMLParser(data: try Data(contentsOf: root.appendingPathComponent("ToolboxStandards.xml")))
        let delegate = StandardsParser()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.rootElement == "ToolboxStandards",
              delegate.standards.allSatisfy({ safeName($0.name) && safeName($0.source) && $0.source.lowercased().hasSuffix(".zip") }) else {
            throw failure("Toolbox 标准件配置无效，拒绝部署。")
        }
        return delegate.standards
    }

    private static func safeName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.contains(":")
    }

    static func validate(root: URL, standards: [Standard]) throws -> Int {
        let fm = FileManager.default
        let browser = root.appendingPathComponent("browser")
        let index = browser.appendingPathComponent("ToolboxFiles.index")
        guard ((try? index.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0 else {
            throw failure("Toolbox 更新工具已退出，但官方标准件索引缺失。")
        }
        var total = 0
        for standard in standards {
            try Task.checkCancellation()
            let folder = browser.appendingPathComponent(standard.name)
            var count = 0
            if let files = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                for case let file as URL in files where file.pathExtension.lowercased() == "sldprt" {
                    try Task.checkCancellation()
                    if (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { count += 1 }
                }
            }
            guard count > 0 else { throw failure("Toolbox 的 \(standard.name) 标准件模型缺失。") }
            total += count
        }
        return total
    }

    private static func failure(_ message: String) -> NSError { MacSWError.make(message, domain: "MacSW.Toolbox") }
}
