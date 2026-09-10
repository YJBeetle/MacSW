import Foundation
import SwiftUI
import AppKit

class AppState: ObservableObject {
    @Published var isInstalled: Bool = false
    @Published var isLicenseRunning: Bool = false
    @Published var isOperating: Bool = false
    @Published var isSolidWorksRunning: Bool = false
    @Published var statusMessage: String = ""
    @Published var selectedTab: Int = 0

    private var runningMonitorTimer: Timer?

    // 许可设置
    @Published var licenseServerAddress: String = "25734@localhost"
    @Published var licenseTestResult: String = ""

    // 安装维护状态（完全由用户指定，零私有硬编码）
    @Published var selectedRegPath: URL? = nil
    @Published var selectedIsoPath: URL? = nil
    @Published var selectedPatchDir: URL? = nil
    @Published var selectedLicenseDir: URL? = nil
    @Published var isExtractingOrMounting: Bool = false
    @Published var mountedVolumePath: String? = nil
    @Published var patchStatusMessage: String = ""

    let bottlePath: URL
    var sldworksExePath: URL
    let appSupportDir: URL

    var hasInstalledExecutable: Bool {
        return FileManager.default.fileExists(atPath: sldworksExePath.path)
    }

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.appSupportDir = appSupport.appendingPathComponent("MacSW")
        self.bottlePath = AppState.resolveBottlePath(appSupportDir: self.appSupportDir)
        
        self.sldworksExePath = AppState.resolveSldworksPath(bottlePath: self.bottlePath)

        if ProcessInfo.processInfo.environment["MACSW_FORCE_WIZARD"] == "1" {
            self.isInstalled = false
        } else {
            self.isInstalled = FileManager.default.fileExists(atPath: self.sldworksExePath.path)
        }

        checkLicenseStatus()
        checkSolidWorksRunningStatus()
        self.runningMonitorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkSolidWorksRunningStatus()
        }
    }

    func checkSolidWorksRunningStatus() {
        DispatchQueue.global(qos: .background).async {
            let task = Process()
            task.launchPath = "/usr/bin/pgrep"
            task.arguments = ["-i", "sldworks.exe"]
            try? task.run()
            task.waitUntilExit()
            let isRunning = (task.terminationStatus == 0)
            DispatchQueue.main.async {
                self.isSolidWorksRunning = isRunning
            }
        }
    }

    func terminateSolidWorks() {
        DispatchQueue.global(qos: .userInitiated).async {
            let script = "pkill -9 -i sldworks.exe 2>/dev/null || true"
            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = ["-c", script]
            try? task.run()
            task.waitUntilExit()
            DispatchQueue.main.async {
                self.isSolidWorksRunning = false
                self.statusMessage = "已终止 SolidWorks 进程"
            }
        }
    }

    static func resolveBottlePath(appSupportDir: URL) -> URL {
        let bottle = appSupportDir.appendingPathComponent("bottle")
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        return bottle
    }

    func buildWineScript(command: String, isBackground: Bool = false) -> String {
        let wineBin = WineService.shared.getWineBinary()
        let wineDir = URL(fileURLWithPath: wineBin).deletingLastPathComponent().deletingLastPathComponent().path
        let wineLib = "\(wineDir)/lib"
        let cxRoot = "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
        let prefix = self.bottlePath.path

        var lines: [String] = [
            "export WINEPREFIX='\(prefix)'",
            "export LANG='zh_CN.UTF-8'",
            "export LC_ALL='zh_CN.UTF-8'",
            "export WINEDEBUG='-all'"
        ]
        if FileManager.default.fileExists(atPath: cxRoot) {
            lines.append("export CX_ROOT='\(cxRoot)'")
        }
        if FileManager.default.fileExists(atPath: wineLib) {
            lines.append("export DYLD_FALLBACK_LIBRARY_PATH='\(wineLib)':$DYLD_FALLBACK_LIBRARY_PATH")
        }
        if isBackground {
            lines.append("nohup \"\(wineBin)\" \(command) >/dev/null 2>&1 &")
        } else {
            lines.append("\"\(wineBin)\" \(command)")
        }
        return lines.joined(separator: "\n")
    }

    func ensureBottleInitialized(forceClean: Bool = false, completion: @escaping (Bool) -> Void) {
        let driveC = self.bottlePath.appendingPathComponent("drive_c")
        if !forceClean && FileManager.default.fileExists(atPath: driveC.path) {
            completion(true)
            return
        }

        isOperating = true
        statusMessage = forceClean ? "正在清理旧容器并初始化全新环境..." : "正在初始化全新 MacSW 独立运行环境..."
        DispatchQueue.global(qos: .userInitiated).async {
            if forceClean {
                WineService.shared.killWineProcesses()
                Thread.sleep(forTimeInterval: 0.5)
                try? FileManager.default.removeItem(at: self.bottlePath)
            }
            try? FileManager.default.createDirectory(at: self.bottlePath, withIntermediateDirectories: true)
            let wine = WineService.shared.getWineBinary()
            let wineDir = URL(fileURLWithPath: wine).deletingLastPathComponent().deletingLastPathComponent().path
            let wineboot = "\(wineDir)/bin/wineboot"
            let wineLib = "\(wineDir)/lib"

            let script = """
            export WINEPREFIX='\(self.bottlePath.path)'
            export LANG='zh_CN.UTF-8'
            export LC_ALL='zh_CN.UTF-8'
            export WINEDEBUG='-all'
            if [ -d '\(wineLib)' ]; then
                export DYLD_FALLBACK_LIBRARY_PATH='\(wineLib)':$DYLD_FALLBACK_LIBRARY_PATH
            fi
            if [ -x '\(wineboot)' ]; then
                "\(wineboot)" -u
            else
                "\(wine)" wineboot -u
            fi
            """
            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = ["-c", script]
            task.launch()
            task.waitUntilExit()
            let ok = (task.terminationStatus == 0)

            DispatchQueue.main.async {
                self.isOperating = false
                self.statusMessage = ok ? "MacSW 独立环境初始化完成" : "初始化环境出现问题"
                self.checkInstallation()
                completion(ok)
            }
        }
    }

    func checkInstallation() {
        if ProcessInfo.processInfo.environment["MACSW_FORCE_WIZARD"] == "1" {
            self.isInstalled = false
            return
        }
        self.sldworksExePath = AppState.resolveSldworksPath(bottlePath: self.bottlePath)
        self.isInstalled = FileManager.default.fileExists(atPath: self.sldworksExePath.path)
    }

    // 智能自动发现并填充同级伴随资源（遵循未填写才填写、已填写不覆盖原则）
    func autoDetectCompanionFiles(from sourceUrl: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceUrl.path, isDirectory: &isDir) else { return }

        let baseDir = isDir.boolValue ? sourceUrl : sourceUrl.deletingLastPathComponent()
        var searchDirs: [URL] = [baseDir]

        // 1. 加入父目录（若存在）
        let parentDir = baseDir.deletingLastPathComponent()
        if parentDir.path != baseDir.path && parentDir.path != "/" {
            searchDirs.append(parentDir)
        }

        // 2. 加入 baseDir 和 parentDir 下的直接子文件夹（如 crack、_SolidSQUAD_ 等常见目录）
        var candidateDirs = searchDirs
        for dir in searchDirs {
            if let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for item in items {
                    var subDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: item.path, isDirectory: &subDir), subDir.boolValue {
                        candidateDirs.append(item)
                    }
                }
            }
        }

        // 去除重复路径
        var seen = Set<String>()
        let finalSearchDirs = candidateDirs.filter { seen.insert($0.standardizedFileURL.path).inserted }

        DispatchQueue.main.async {
            // A. 网络注册表 (*serials_licensing.reg) - 未填写时才填写，已存在绝不覆盖
            if self.selectedRegPath == nil {
                for dir in finalSearchDirs {
                    if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                        // 优先精准匹配包含 serial 与 licens 的 .reg 文件
                        if let match = files.first(where: {
                            let name = $0.lastPathComponent.lowercased()
                            return name.hasSuffix(".reg") && name.contains("serial") && name.contains("licens")
                        }) {
                            self.selectedRegPath = match
                            break
                        }
                        // 次优匹配任意 serial*.reg (排除 loader)
                        if let match = files.first(where: {
                            let name = $0.lastPathComponent.lowercased()
                            return name.hasSuffix(".reg") && name.contains("serial") && !name.contains("loader")
                        }) {
                            self.selectedRegPath = match
                            break
                        }
                    }
                }
            }

            // B. 许可服务目录 (SolidWorks_Flexnet_Server) - 未填写时才填写，已存在绝不覆盖
            if self.selectedLicenseDir == nil {
                for dir in finalSearchDirs {
                    if let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                        for item in items {
                            var itemIsDir: ObjCBool = false
                            if FileManager.default.fileExists(atPath: item.path, isDirectory: &itemIsDir), itemIsDir.boolValue {
                                let name = item.lastPathComponent.lowercased()
                                if name.contains("solidworks") && name.contains("flexnet") && name.contains("server") {
                                    self.selectedLicenseDir = item
                                    break
                                } else if name.contains("flexnet") && name.contains("server") {
                                    self.selectedLicenseDir = item
                                    break
                                } else if FileManager.default.fileExists(atPath: item.appendingPathComponent("lmgrd.exe").path) {
                                    self.selectedLicenseDir = item
                                    break
                                }
                            }
                        }
                        if self.selectedLicenseDir != nil { break }
                    }
                }
            }

            // C. 组件补丁目录 (SOLIDWORKS Corp) - 未填写时才填写，已存在绝不覆盖
            if self.selectedPatchDir == nil {
                for dir in finalSearchDirs {
                    if let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                        for item in items {
                            var itemIsDir: ObjCBool = false
                            if FileManager.default.fileExists(atPath: item.path, isDirectory: &itemIsDir), itemIsDir.boolValue {
                                let name = item.lastPathComponent
                                if name.localizedCaseInsensitiveContains("SOLIDWORKS Corp") {
                                    self.selectedPatchDir = item
                                    break
                                }
                            }
                        }
                        if self.selectedPatchDir != nil { break }
                    }
                }
            }

            // D. 安装介质 (如果当前尚未选择 ISO 或安装目录) - 未填写时才填写，已存在绝不覆盖
            if self.selectedIsoPath == nil {
                for dir in finalSearchDirs {
                    if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                        if let isoMatch = files.first(where: {
                            let ext = $0.pathExtension.lowercased()
                            let name = $0.lastPathComponent.lowercased()
                            return (ext == "iso" || ext == "dmg") && name.contains("solidworks")
                        }) {
                            self.selectedIsoPath = isoMatch
                            break
                        }
                    }
                }
            }
        }
    }

    static func resolveSldworksPath(bottlePath: URL) -> URL {
        // 1. 优先从容器注册表 system.reg 动态解析真实的安装绝对路径
        let systemReg = bottlePath.appendingPathComponent("system.reg")
        if let content = try? String(contentsOf: systemReg, encoding: .utf8) {
            for line in content.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("\"SolidWorks Folder\"=") {
                    let parts = trimmed.components(separatedBy: "=")
                    if parts.count >= 2 {
                        var rawPath = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" \r\n"))
                        rawPath = rawPath.replacingOccurrences(of: "\\\\", with: "/")
                        rawPath = rawPath.replacingOccurrences(of: "\\", with: "/")
                        if rawPath.lowercased().hasPrefix("c:/") {
                            let relPath = String(rawPath.dropFirst(3)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                            let exeCandidate = bottlePath.appendingPathComponent("drive_c").appendingPathComponent(relPath).appendingPathComponent("SLDWORKS.exe")
                            if FileManager.default.fileExists(atPath: exeCandidate.path) {
                                return exeCandidate
                            }
                        }
                    }
                }
            }
        }

        // 2. 兜底探测常见安装路径
        let p1 = bottlePath.appendingPathComponent("drive_c/Program Files/SOLIDWORKS Corp/SOLIDWORKS/SLDWORKS.exe")
        let p2 = bottlePath.appendingPathComponent("drive_c/Program Files/SOLIDWORKS/SLDWORKS.exe")
        if FileManager.default.fileExists(atPath: p1.path) { return p1 }
        if FileManager.default.fileExists(atPath: p2.path) { return p2 }

        // 3. 动态枚举 drive_c/Program Files 下任意安装子目录
        let programFiles = bottlePath.appendingPathComponent("drive_c/Program Files")
        if let enumerator = FileManager.default.enumerator(at: programFiles, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let fileUrl as URL in enumerator {
                if fileUrl.lastPathComponent.lowercased() == "sldworks.exe" {
                    return fileUrl
                }
            }
        }

        return p1
    }

    func checkLicenseStatus(completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = ["-c", "nc -z -w 1 127.0.0.1 25734 >/dev/null 2>&1"]
            task.launch()
            task.waitUntilExit()
            let running = (task.terminationStatus == 0)
            DispatchQueue.main.async {
                self.isLicenseRunning = running
                completion?(running)
            }
        }
    }

    func startLicenseServer() {
        isOperating = true
        statusMessage = "正在启动 FlexNet 许可服务..."
        DispatchQueue.global(qos: .userInitiated).async {
            let wine = WineService.shared.getWineBinary()
            let flexDir: String
            if let customLic = self.selectedLicenseDir?.path, FileManager.default.fileExists(atPath: "\(customLic)/lmgrd.exe") {
                flexDir = customLic
            } else {
                flexDir = self.bottlePath.appendingPathComponent("drive_c/opt/SolidWorks_Flexnet_Server").path
            }

            let logDir = self.appSupportDir.appendingPathComponent("logs").path
            let logPath = "\(logDir)/flexnet.log"
            try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
            
            let envHeader = self.buildWineScript(command: "")
            let script = """
            pkill -9 -f lmgrd || true
            pkill -9 -f SW_D || true
            \(envHeader)
            cd '\(flexDir)'
            LIC_FILE="$(ls *.lic 2>/dev/null | head -n 1 || echo 'sw_d.lic')"
            nohup "\(wine)" '\(flexDir)/lmgrd.exe' -c "\(flexDir)/$LIC_FILE" -l '\(logPath)' >/dev/null 2>&1 &
            sleep 2
            nc -z -w 2 127.0.0.1 25734
            """
            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = ["-c", script]
            task.launch()
            task.waitUntilExit()
            _ = (task.terminationStatus == 0)

            DispatchQueue.main.async {
                self.isOperating = false
                self.checkLicenseStatus { running in
                    self.statusMessage = running ? "FlexNet 许可服务已启动 (端口 25734)" : "启动完成，等待端口监听..."
                }
            }
        }
    }

    func stopLicenseServer() {
        isOperating = true
        statusMessage = "正在停止 FlexNet 许可服务..."
        DispatchQueue.global(qos: .userInitiated).async {
            let script = "pkill -9 -f lmgrd || true; pkill -9 -f SW_D || true; pkill -9 -f flex_proxy.py || true"
            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = ["-c", script]
            task.launch()
            task.waitUntilExit()

            DispatchQueue.main.async {
                self.isOperating = false
                self.checkLicenseStatus()
                self.statusMessage = "FlexNet 许可服务已停止"
            }
        }
    }

    func restartLicenseServer() {
        stopLicenseServer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.startLicenseServer()
        }
    }

    // 保存许可服务器地址到 Windows 注册表
    func saveLicenseServerAddress(address: String) {
        let addr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addr.isEmpty else { return }
        isOperating = true
        statusMessage = "正在将许可服务器 [\(addr)] 写入注册表..."

        let envHeader = self.buildWineScript(command: "")
        let wine = WineService.shared.getWineBinary()
        let script = """
        \(envHeader)
        "\(wine)" reg add "HKLM\\Software\\FLEXlm License Manager" /v SOLIDWORKS_LICENSE_FILE /t REG_SZ /d "\(addr)" /f
        "\(wine)" reg add "HKCU\\Software\\FLEXlm License Manager" /v SOLIDWORKS_LICENSE_FILE /t REG_SZ /d "\(addr)" /f
        "\(wine)" reg add "HKLM\\Software\\FLEXlm License Manager" /v SW_D_LICENSE_FILE /t REG_SZ /d "\(addr)" /f
        "\(wine)" reg add "HKCU\\Software\\FLEXlm License Manager" /v SW_D_LICENSE_FILE /t REG_SZ /d "\(addr)" /f
        """

        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = ["-c", script]
            task.launch()
            task.waitUntilExit()

            DispatchQueue.main.async {
                self.isOperating = false
                self.statusMessage = (task.terminationStatus == 0) ? "许可服务器地址已成功写入注册表！" : "写入注册表失败"
            }
        }
    }

    // 测试许可服务端口连通性
    func testLicenseConnection() {
        licenseTestResult = "正在测试连接..."
        DispatchQueue.global(qos: .userInitiated).async {
            var host = "127.0.0.1"
            var port = "25734"
            if self.licenseServerAddress.contains("@") {
                let parts = self.licenseServerAddress.components(separatedBy: "@")
                if parts.count >= 2 {
                    port = parts[0]
                    host = parts[1]
                    if host == "localhost" { host = "127.0.0.1" }
                }
            }

            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = ["-c", "nc -z -w 2 \(host) \(port) >/dev/null 2>&1"]
            task.launch()
            task.waitUntilExit()
            let ok = (task.terminationStatus == 0)

            DispatchQueue.main.async {
                if ok {
                    self.licenseTestResult = "🟢 连通成功: \(host):\(port) 响应正常"
                } else {
                    self.licenseTestResult = "🔴 连通失败: 无法连接至 \(host):\(port)"
                }
            }
        }
    }

    // 导入网络序列号（从用户指定注册表路径、补丁路径或让用户选择 .reg 文件）
    func importNetworkSerials(customRegPath: URL? = nil, interactive: Bool = true, completion: ((Bool) -> Void)? = nil) {
        var regPath = customRegPath?.path

        // 1. 优先使用用户在步骤 1 显式指定的 selectedRegPath
        if regPath == nil, let userReg = selectedRegPath {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: userReg.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    if let items = try? FileManager.default.contentsOfDirectory(at: userReg, includingPropertiesForKeys: nil) {
                        let regFiles = items.filter { $0.pathExtension.lowercased() == "reg" }
                        if let match = regFiles.first(where: {
                            let name = $0.lastPathComponent.lowercased()
                            return name.contains("serial") || name.contains("licens")
                        }) ?? regFiles.first {
                            regPath = match.path
                        }
                    }
                } else {
                    regPath = userReg.path
                }
            }
        }

        // 2. 其次在组件补丁目录或其父级动态查找包含 serial 或 license 的 .reg 文件
        if regPath == nil, let patchDir = selectedPatchDir {
            let searchDirs = [patchDir, patchDir.deletingLastPathComponent()]
            for dir in searchDirs {
                if let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                    let regFiles = items.filter { $0.pathExtension.lowercased() == "reg" }
                    if let match = regFiles.first(where: {
                        let name = $0.lastPathComponent.lowercased()
                        return name.contains("serial") || name.contains("licens")
                    }) ?? regFiles.first {
                        regPath = match.path
                        break
                    }
                }
            }
        }

        guard let rPath = regPath, FileManager.default.fileExists(atPath: rPath) else {
            if !interactive {
                completion?(false)
                return
            }
            // 弹出文件选择器由用户指定
            DispatchQueue.main.async {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.message = "请选择网络序列号注册表文件 (.reg)"
                if panel.runModal() == .OK, let file = panel.url {
                    self.selectedRegPath = file
                    self.importNetworkSerials(customRegPath: file, interactive: interactive, completion: completion)
                } else {
                    completion?(false)
                }
            }
            return
        }

        let wine = WineService.shared.getWineBinary()
        let envHeader = self.buildWineScript(command: "")
        let script = """
        \(envHeader)
        "\(wine)" regedit /s '\(rPath)'
        """

        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = ["-c", script]
            task.launch()
            task.waitUntilExit()
            let ok = (task.terminationStatus == 0)

            DispatchQueue.main.async {
                self.isOperating = false
                self.statusMessage = ok ? "网络序列号导入成功！" : "导入序列号失败"
                completion?(ok)
            }
        }
    }

    // 应用组件补丁（从用户指定的 selectedPatchDir 复制到动态解析的实际安装目录）
    func applyComponentPatch(customPatchDir: URL? = nil, completion: ((Bool) -> Void)? = nil) {
        guard let patchUrl = customPatchDir ?? selectedPatchDir else {
            DispatchQueue.main.async {
                self.patchStatusMessage = "请先选择或拖拽 SOLIDWORKS Corp 补丁文件夹"
                completion?(false)
            }
            return
        }

        isOperating = true
        patchStatusMessage = "正在应用组件补丁与运行库环境..."
        let patchDir = patchUrl.path
        
        // 动态定位真实安装主目录（优先通过注册表解析）
        let exeUrl = AppState.resolveSldworksPath(bottlePath: bottlePath)
        let actualTargetDir = exeUrl.deletingLastPathComponent().path
        let wine = WineService.shared.getWineBinary()

        let envHeader = self.buildWineScript(command: "")
        let script = """
        pkill -9 -f sldworks_fs || true
        rm -f '\(actualTargetDir)/netapi32.dll' || true
        
        # 1. 覆盖主程序补丁到实际探测到的安装目录
        if [ -d '\(actualTargetDir)' ]; then
            if [ -d '\(patchDir)/SOLIDWORKS' ]; then
                rsync -av '\(patchDir)/SOLIDWORKS/' '\(actualTargetDir)/'
            else
                rsync -av '\(patchDir)/' '\(actualTargetDir)/'
            fi
        fi

        # 2. 如果补丁包中包含其他同级套件目录（如 eDrawings 等），同步到父级目录
        parentTargetDir="$(dirname '\(actualTargetDir)')"
        if [ -d "$parentTargetDir" ] && [ -d '\(patchDir)/SOLIDWORKS' ]; then
            for sub in '\(patchDir)'/*; do
                if [ -d "$sub" ] && [ "$(basename "$sub")" != "SOLIDWORKS" ]; then
                    rsync -av "$sub" "$parentTargetDir/"
                fi
            done
        fi

        \(envHeader)
        # 查找并导入补丁目录或父级目录中的所有注册表补丁
        for reg in '\(patchDir)'/*.reg '\(patchDir)'/../*.reg; do
            if [ -f "$reg" ]; then
                "\(wine)" regedit /s "$reg" 2>/dev/null || true
            fi
        done
        """

        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = ["-c", script]
            task.launch()
            task.waitUntilExit()
            let ok = (task.terminationStatus == 0)

            DispatchQueue.main.async {
                self.isOperating = false
                self.patchStatusMessage = ok ? "✅ 组件补丁已成功同步应用！" : "❌ 组件补丁应用失败"
                completion?(ok)
            }
        }
    }

    // 唤起 SolidWorks 官方安装程序 setup.exe
    func launchSetupExe() {
        isOperating = true
        statusMessage = "正在检查安装介质并启动安装程序 (setup.exe)..."

        DispatchQueue.global(qos: .userInitiated).async {
            var setupExe: String? = nil

            // 检查用户在向导中选中的介质
            if let userIso = self.selectedIsoPath {
                if userIso.pathExtension.lowercased() == "iso" {
                    if let mountPoint = IsoService.shared.mountIso(at: userIso) {
                        self.mountedVolumePath = mountPoint
                        setupExe = IsoService.shared.findSetupExe(in: mountPoint)
                    }
                } else {
                    setupExe = IsoService.shared.findSetupExe(in: userIso.path)
                }
            }

            guard let exe = setupExe else {
                DispatchQueue.main.async {
                    self.isOperating = false
                    self.statusMessage = "未找到 setup.exe，请在向导中指定或拖拽 SolidWorks 安装镜像！"
                }
                return
            }

            DispatchQueue.main.async {
                self.statusMessage = "正在唤起 setup.exe: \(exe)"
            }

            let wine = WineService.shared.getWineBinary()
            let envHeader = self.buildWineScript(command: "")
            let script = """
            \(envHeader)
            "\(wine)" '\(exe)'
            """
            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = ["-c", script]
            task.launch()
            task.waitUntilExit()

            DispatchQueue.main.async {
                self.isOperating = false
                self.statusMessage = "安装程序已退出。如已完成安装，请点击【应用组件补丁】"
                self.checkInstallation()
            }
        }
    }

    // 查看许可日志
    func openFlexnetLog() {
        let logPath = appSupportDir.appendingPathComponent("logs/flexnet.log").path
        if FileManager.default.fileExists(atPath: logPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
        } else {
            statusMessage = "暂无许可日志文件"
        }
    }

    // 打开注册表编辑器
    func openRegedit() {
        let script = self.buildWineScript(command: "regedit", isBackground: true)
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", script]
        task.launch()
    }

    // 打开 Wine 配置
    func openWinecfg() {
        let script = self.buildWineScript(command: "winecfg", isBackground: true)
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", script]
        task.launch()
    }
}
