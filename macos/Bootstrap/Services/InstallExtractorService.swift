import Foundation

public class InstallExtractorService {
    public static let shared = InstallExtractorService()
    
    public init() {}
    
    /// 检测系统 7z 可执行程序路径
    public func find7zPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/7z",
            "/usr/local/bin/7z",
            "/usr/bin/7z"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["7z"]
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        
        if process.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                return output
            }
        }
        return nil
    }
    
    /// 文件名规范化：去除 MSI 打包时追加的数字后缀 (例如 sldmfcu.dll1 -> sldmfcu.dll)
    public func normalizeFileName(_ name: String) -> String {
        let pattern = "^(.*\\.(?:dll|exe|tlb|ocx|sys|ini|bmp|png|xml|config|dat|db|cat|htm|chm|hlp|mst|txt))[0-9]+$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return name
        }
        let range = NSRange(location: 0, length: name.utf16.count)
        if let match = regex.firstMatch(in: name, options: [], range: range) {
            if let targetRange = Range(match.range(at: 1), in: name) {
                return String(name[targetRange])
            }
        }
        return name
    }
    
    /// 生成 Windows 注册表注入脚本
    public func generateRegistryContent(language: String) -> String {
        let cleanLang = language.isEmpty ? "Chinese Simplified" : language
        return """
        Windows Registry Editor Version 5.00

        [HKEY_CURRENT_USER\\Software\\SolidWorks]

        [HKEY_CURRENT_USER\\Software\\SolidWorks\\General]
        "Current Language"="\(cleanLang)"

        [HKEY_CURRENT_USER\\Software\\SolidWorks\\SOLIDWORKS 2024\\General]
        "Current Language"="\(cleanLang)"

        [HKEY_LOCAL_MACHINE\\Software\\SolidWorks]

        [HKEY_LOCAL_MACHINE\\Software\\SolidWorks\\General]
        "Current Language"="\(cleanLang)"
        "SolidWorks Folder"="C:\\\\Program Files\\\\SOLIDWORKS"

        [HKEY_LOCAL_MACHINE\\Software\\SolidWorks\\Setup]
        "SolidWorks Folder"="C:\\\\Program Files\\\\SOLIDWORKS"
        "SolidWorks Language"="\(cleanLang)"
        "Toolbox Folder"="C:\\\\SOLIDWORKS Data"

        """
    }
    
    /// 解压单个压缩包 (CAB / ZIP)
    public func extractSingleArchive(archivePath: String, destinationDir: String) -> Bool {
        guard let sevenZip = find7zPath() else { return false }
        try? FileManager.default.createDirectory(atPath: destinationDir, withIntermediateDirectories: true)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sevenZip)
        process.arguments = ["x", "-y", "-o\(destinationDir)", archivePath]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
    
    /// 递归规范化目录下的 MSI 临时后缀文件
    public func normalizeExtractedDirectory(dirPath: String) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: dirPath) else { return }
        
        var toRename: [(String, String)] = []
        while let relativePath = enumerator.nextObject() as? String {
            let fileName = (relativePath as NSString).lastPathComponent
            let normalized = normalizeFileName(fileName)
            if normalized != fileName {
                let fullOldPath = (dirPath as NSString).appendingPathComponent(relativePath)
                let parentDir = (fullOldPath as NSString).deletingLastPathComponent
                let fullNewPath = (parentDir as NSString).appendingPathComponent(normalized)
                toRename.append((fullOldPath, fullNewPath))
            }
        }
        
        for (oldPath, newPath) in toRename {
            if fm.fileExists(atPath: newPath) {
                try? fm.removeItem(atPath: newPath)
            }
            try? fm.moveItem(atPath: oldPath, toPath: newPath)
        }
    }
    
    /// 批量执行定制介质的高速并发解包与注册表设置
    public func performFullExtraction(
        mediaPath: String,
        winePrefix: String,
        selectedLanguageLcid: String,
        selectedComponents: [ComponentOption],
        wineBinPath: String?,
        progressHandler: @escaping (Double, String) -> Void,
        completion: @escaping (Bool, String?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard self.find7zPath() != nil else {
                DispatchQueue.main.async {
                    completion(false, "系统未找到 7z 解包工具，请确保已安装 p7zip。")
                }
                return
            }
            
            let fm = FileManager.default
            let swInstallDir = (winePrefix as NSString).appendingPathComponent("drive_c/Program Files/SOLIDWORKS")
            let swLangDir = (swInstallDir as NSString).appendingPathComponent("lang")
            let toolboxDir = (winePrefix as NSString).appendingPathComponent("drive_c/SOLIDWORKS Data/browser")
            
            try? fm.createDirectory(atPath: swInstallDir, withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: swLangDir, withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: toolboxDir, withIntermediateDirectories: true)
            
            // 1. 收集解压任务
            struct ExtractTask {
                let archivePath: String
                let destinationDir: String
                let taskName: String
            }
            var tasks: [ExtractTask] = []
            
            // 核心程序 CAB 文件
            let swwiDataDir = (mediaPath as NSString).appendingPathComponent("swwi/data")
            if let files = try? fm.contentsOfDirectory(atPath: swwiDataDir) {
                for file in files where file.lowercased().hasSuffix(".cab") {
                    let archivePath = (swwiDataDir as NSString).appendingPathComponent(file)
                    tasks.append(ExtractTask(archivePath: archivePath, destinationDir: swInstallDir, taskName: file))
                }
            }
            
            // 语言包处理
            if selectedLanguageLcid.lowercased() == "0x0804" {
                // 简体中文语言包
                let zhSimpDir = (mediaPath as NSString).appendingPathComponent("swwi/lang/chinese-simplified")
                let destZhDir = (swLangDir as NSString).appendingPathComponent("chinese-simplified")
                if let zhFiles = try? fm.contentsOfDirectory(atPath: zhSimpDir) {
                    for file in zhFiles where file.lowercased().hasSuffix(".cab") {
                        let archivePath = (zhSimpDir as NSString).appendingPathComponent(file)
                        tasks.append(ExtractTask(archivePath: archivePath, destinationDir: destZhDir, taskName: "中文语言包: \(file)"))
                    }
                }
            } else if selectedLanguageLcid.lowercased() == "0x0409" {
                // 英文语言包
                let engCab = (swwiDataDir as NSString).appendingPathComponent("English.cab")
                if fm.fileExists(atPath: engCab) {
                    let destEngDir = (swLangDir as NSString).appendingPathComponent("english")
                    tasks.append(ExtractTask(archivePath: engCab, destinationDir: destEngDir, taskName: "English.cab"))
                }
            }
            
            // 可选组件处理
            for comp in selectedComponents where comp.isSelected {
                if comp.id == "Toolbox" {
                    let tbDir = (mediaPath as NSString).appendingPathComponent("Toolbox")
                    if let zips = try? fm.contentsOfDirectory(atPath: tbDir) {
                        for zip in zips where zip.lowercased().hasSuffix(".zip") {
                            let archivePath = (tbDir as NSString).appendingPathComponent(zip)
                            tasks.append(ExtractTask(archivePath: archivePath, destinationDir: toolboxDir, taskName: "Toolbox: \(zip)"))
                        }
                    }
                } else if comp.id != "swwi" {
                    let compDir = (mediaPath as NSString).appendingPathComponent(comp.folderName)
                    let destCompDir = (swInstallDir as NSString).appendingPathComponent(comp.folderName)
                    if let compFiles = try? fm.contentsOfDirectory(atPath: compDir) {
                        for file in compFiles where file.lowercased().hasSuffix(".cab") {
                            let archivePath = (compDir as NSString).appendingPathComponent(file)
                            tasks.append(ExtractTask(archivePath: archivePath, destinationDir: destCompDir, taskName: "\(comp.name): \(file)"))
                        }
                    }
                }
            }
            
            guard !tasks.isEmpty else {
                DispatchQueue.main.async {
                    completion(false, "介质中未发现可解压的 SolidWorks 组件数据。")
                }
                return
            }
            
            // 2. 多线程并发解压
            let totalTasks = Double(tasks.count)
            var completedCount = 0
            let lock = NSLock()
            
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount)
            
            for task in tasks {
                queue.addOperation {
                    _ = self.extractSingleArchive(archivePath: task.archivePath, destinationDir: task.destinationDir)
                    lock.lock()
                    completedCount += 1
                    let progress = (Double(completedCount) / totalTasks) * 0.85
                    let currentMsg = "正在解压 [\(completedCount)/\(Int(totalTasks))]: \(task.taskName)"
                    lock.unlock()
                    
                    DispatchQueue.main.async {
                        progressHandler(progress, currentMsg)
                    }
                }
            }
            
            queue.waitUntilAllOperationsAreFinished()
            
            // 3. 规范化文件名 (85% -> 95%)
            DispatchQueue.main.async {
                progressHandler(0.88, "正在重命名与规范化 Windows 组件模块...")
            }
            self.normalizeExtractedDirectory(dirPath: swInstallDir)
            self.normalizeExtractedDirectory(dirPath: toolboxDir)
            
            // 4. 写入语言与安装路径注册表 (95% -> 100%)
            DispatchQueue.main.async {
                progressHandler(0.95, "正在配置语言与运行环境注册表...")
            }
            
            let regLanguage = (selectedLanguageLcid.lowercased() == "0x0804") ? "Chinese Simplified" : "English"
            let regContent = self.generateRegistryContent(language: regLanguage)
            let regFile = (winePrefix as NSString).appendingPathComponent("install_settings.reg")
            try? regContent.write(toFile: regFile, atomically: true, encoding: .utf8)
            
            if let wineBin = wineBinPath, fm.isExecutableFile(atPath: wineBin) {
                let regProcess = Process()
                regProcess.executableURL = URL(fileURLWithPath: wineBin)
                regProcess.arguments = ["regedit", "/s", "C:\\install_settings.reg"]
                var env = ProcessInfo.processInfo.environment
                env["WINEPREFIX"] = winePrefix
                env["WINEDEBUG"] = "-all"
                regProcess.environment = env
                try? regProcess.run()
                regProcess.waitUntilExit()
            }
            
            DispatchQueue.main.async {
                progressHandler(1.0, "SolidWorks 定制组件极速安装完成！")
                completion(true, nil)
            }
        }
    }
}
