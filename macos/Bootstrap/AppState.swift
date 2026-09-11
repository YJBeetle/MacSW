import Foundation
import SwiftUI
import AppKit
import Darwin

class AppState: ObservableObject {
    @Published var isInstalled: Bool = false
    @Published var isLicenseRunning: Bool = false
    @Published var isOperating: Bool = false
    @Published var isSolidWorksRunning: Bool = false
    @Published var statusMessage: String = ""
    @Published var selectedTab: Int = 0
    @Published var showDeploymentProgress = false
    @Published var deploymentStates: [DeploymentStep: DeploymentStatus] = [:]
    @Published var deploymentDetails: [DeploymentStep: String] = [:]

    func reportDeployment(_ step: DeploymentStep, _ status: DeploymentStatus, _ detail: String) {
        DispatchQueue.main.async {
            self.deploymentStates[step] = status
            self.deploymentDetails[step] = detail
        }
    }

    private var runningMonitorTimer: Timer?

    // 许可设置
    @Published var licenseServerAddress: String = "25734@localhost"
    @Published var licenseTestResult: String = ""

    // 安装维护状态（完全由用户指定，零私有硬编码）
    @Published var selectedRegPath: URL? = nil
    @Published var selectedIsoPath: URL? = nil
    @Published var selectedPatchDir: URL? = nil
    @Published var selectedLicenseDir: URL? = nil
    @Published var isPatchApplied: Bool = false
    @Published var isWpfThemeInjected: Bool = false
    @Published var isVcRedistInjected: Bool = false
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
        let initialBottle = AppState.resolveBottlePath(appSupportDir: self.appSupportDir)
        self.bottlePath = initialBottle
        self.sldworksExePath = AppState.resolveSldworksPath(bottlePath: initialBottle)

        if ProcessInfo.processInfo.environment["MACSW_FORCE_WIZARD"] == "1" {
            self.isInstalled = false
        } else {
            self.checkInstallation()
        }

        checkLicenseStatus()
        checkSolidWorksRunningStatus()
        self.runningMonitorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkSolidWorksRunningStatus()
        }

    }

    func checkSolidWorksRunningStatus() {
        self.isSolidWorksRunning = WineService.shared.isRunning(prefix: bottlePath.path)
    }

    func terminateSolidWorks() {
        DispatchQueue.global(qos: .userInitiated).async {
            let service = WineService.shared
            let task = service.makeProcess(arguments: ["taskkill", "/f", "/im", "SLDWORKS.exe"], prefix: self.bottlePath.path)
            let code = (try? service.run(task)) ?? -1
            DispatchQueue.main.async {
                self.statusMessage = code == 0 ? "已终止当前容器内的 SolidWorks" : "未能终止 SolidWorks（\(code)）"
            }
        }
    }

    static func resolveBottlePath(appSupportDir: URL) -> URL {
        let bottle = appSupportDir.appendingPathComponent("bottle")
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        return bottle
    }

    func buildWineScript(command: String, isBackground: Bool = false) -> String {
        let service = WineService.shared
        let run = "\(WineService.quote(service.getWineBinary())) \(command)"
        return service.buildEnvironmentScript(winePrefix: bottlePath.path) + "\n" +
            (isBackground ? "nohup \(run) >/dev/null 2>&1 &" : run)
    }

    func checkInstallation() {
        if ProcessInfo.processInfo.environment["MACSW_FORCE_WIZARD"] == "1" {
            self.isInstalled = false
            self.isPatchApplied = false
            self.isWpfThemeInjected = false
            return
        }
        self.sldworksExePath = AppState.resolveSldworksPath(bottlePath: self.bottlePath)
        self.isInstalled = FileManager.default.fileExists(atPath: self.sldworksExePath.path)

        let targetDir = self.sldworksExePath.deletingLastPathComponent()
        let swsecwrap = targetDir.appendingPathComponent("swsecwrap.dll")
        let sldutu = targetDir.appendingPathComponent("sldutu.dll")
        let hasSecwrap = FileManager.default.fileExists(atPath: swsecwrap.path) && FileManager.default.fileExists(atPath: sldutu.path)
        self.isPatchApplied = hasSecwrap

        self.isWpfThemeInjected = PrerequisiteService.themes.allSatisfy {
            FileManager.default.fileExists(atPath: targetDir.appendingPathComponent("PresentationFramework.\($0).dll").path)
        }

        self.isVcRedistInjected = WineService.vcLibraries.allSatisfy {
            FileManager.default.fileExists(atPath: bottlePath.appendingPathComponent("drive_c/windows/system32/\($0).dll").path)
        }

        // Keep the mscoree supplied by this Wine runtime; never mix CrossOver DLLs.

    }

    /// Resolve only user-selected media; no workspace/Homebrew fallback.
    func prepareMedia() throws -> URL {
        guard let selected = selectedIsoPath else {
            throw NSError(domain: "MacSW", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先选择官方 ISO 或安装介质目录。"])
        }
        if selected.pathExtension.lowercased() == "iso" {
            guard let mounted = IsoService.shared.mountIso(at: selected) else {
                throw NSError(domain: "MacSW", code: 2, userInfo: [NSLocalizedDescriptionKey: "挂载安装介质失败。"])
            }
            return URL(fileURLWithPath: mounted)
        }
        return selected
    }

    func extractAndInjectWpfThemes(completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let media = try self.prepareMedia()
                try PrerequisiteService.shared.installThemes(media: media, prefix: self.bottlePath,
                    target: AppState.resolveSldworksPath(bottlePath: self.bottlePath).deletingLastPathComponent())
                DispatchQueue.main.async { self.checkInstallation(); completion?(self.isWpfThemeInjected) }
            } catch {
                DispatchQueue.main.async { self.statusMessage = error.localizedDescription; completion?(false) }
            }
        }
    }

    func extractAndInjectVcRedist(completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try PrerequisiteService.shared.installVC(media: self.prepareMedia(), prefix: self.bottlePath)
                DispatchQueue.main.async { self.checkInstallation(); completion?(self.isVcRedistInjected) }
            } catch {
                DispatchQueue.main.async { self.statusMessage = error.localizedDescription; completion?(false) }
            }
        }
    }

    func launchSolidWorks() {
        guard !isOperating && !isSolidWorksRunning else { return }
        checkInstallation()
        guard hasInstalledExecutable else { statusMessage = "未找到 SOLIDWORKS.exe"; return }
        guard FileManager.default.isExecutableFile(atPath: WineService.shared.getWineBinary()),
              FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/sw_ui_daemon.exe").path) else {
            statusMessage = "App 内置运行时或 UI 守护程序缺失，请重新打包。"; return
        }
        isOperating = true
        statusMessage = "正在检查 WPF 与 VC++ 运行库..."
        let start = {
            self.isOperating = false
            self.isSolidWorksRunning = true
            self.statusMessage = "正在启动 SolidWorks（Wine 11.16，UI 避让已启用）..."
            WineService.shared.launchSolidWorks(exePath: self.sldworksExePath.path, winePrefix: self.bottlePath.path) { _, message in
                self.isSolidWorksRunning = false
                self.statusMessage = message
            }
        }
        let prepareVC = {
            if self.isVcRedistInjected { start() }
            else { self.extractAndInjectVcRedist { ok in
                if ok { start() } else { self.isOperating = false }
            } }
        }
        if isWpfThemeInjected { prepareVC() }
        else { extractAndInjectWpfThemes { ok in
            if ok { prepareVC() } else { self.isOperating = false }
        } }
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
            if nc -z -w 1 127.0.0.1 25734; then exit 0; fi
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
            let script = self.buildWineScript(command: "taskkill /f /im lmgrd.exe /im SW_D.exe")
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

        let script = """
        rm -f '\(actualTargetDir)/netapi32.dll' || true
        
        # 1. 覆盖主程序补丁到实际探测到的安装目录（兼容各种层级的补丁包结构）
        if [ -d '\(actualTargetDir)' ]; then
            if [ -d '\(patchDir)/SOLIDWORKS Corp/SOLIDWORKS' ]; then
                rsync -av '\(patchDir)/SOLIDWORKS Corp/SOLIDWORKS/' '\(actualTargetDir)/'
            elif [ -d '\(patchDir)/SOLIDWORKS' ]; then
                rsync -av '\(patchDir)/SOLIDWORKS/' '\(actualTargetDir)/'
            elif [ -f '\(patchDir)/sldutu.dll' ]; then
                rsync -av '\(patchDir)/' '\(actualTargetDir)/'
            else
                rsync -av '\(patchDir)/' '\(actualTargetDir)/'
            fi
        fi

        # 2. 如果补丁包中包含其他同级套件目录（如 eDrawings 等），同步到父级目录
        parentTargetDir="$(dirname '\(actualTargetDir)')"
        if [ -d "$parentTargetDir" ]; then
            corpDir=""
            if [ -d '\(patchDir)/SOLIDWORKS Corp' ]; then
                corpDir='\(patchDir)/SOLIDWORKS Corp'
            elif [ -d '\(patchDir)/SOLIDWORKS' ]; then
                corpDir='\(patchDir)'
            fi
            if [ -n "$corpDir" ]; then
                for sub in "$corpDir"/*; do
                    if [ -d "$sub" ] && [ "$(basename "$sub")" != "SOLIDWORKS" ]; then
                        rsync -av "$sub" "$parentTargetDir/"
                    fi
                done
            fi
        fi
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
                self.checkInstallation()
                self.patchStatusMessage = ok ? "✅ 组件补丁与授权注册表已成功同步应用！" : "❌ 组件补丁应用失败"
                completion?(ok)
            }
        }
    }

    /// Official MSI deployment: prerequisites -> optional registry -> installer -> WPF.
    func launchSetupExe(cleanInstall: Bool = false) {
        guard !isOperating && !isSolidWorksRunning else { return }
        isOperating = true
        showDeploymentProgress = true
        deploymentStates = [.environment: .running]
        deploymentDetails = [.environment: "正在挂载介质并初始化唯一 Wine 容器…"]
        statusMessage = "正在准备官方安装程序..."
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let media = try self.prepareMedia()
                let msi = media.appendingPathComponent("swwi/data/solidworks.msi")
                guard FileManager.default.fileExists(atPath: msi.path) else {
                    throw NSError(domain: "MacSW", code: 3, userInfo: [NSLocalizedDescriptionKey: "介质中未找到 swwi/data/solidworks.msi。"])
                }
                let service = WineService.shared
                if cleanInstall {
                    try self.clearBottleForInstallation(media: media)
                }
                let boot = try service.run(service.makeProcess(arguments: ["wineboot", "-u"], prefix: self.bottlePath.path),
                    log: service.logDirectory(self.bottlePath.path).appendingPathComponent("wineboot.log"))
                guard boot == 0 else { throw NSError(domain: "MacSW", code: Int(boot), userInfo: [NSLocalizedDescriptionKey: "Wine 初始化失败，请查看 wineboot.log。"]) }
                try PrerequisiteService.configureMono(prefix: self.bottlePath)
                try PrerequisiteService.prepareRegAsmCompatibility(runtime: service.runtimeURL, prefix: self.bottlePath)
                self.reportDeployment(.environment, .completed, "运行环境已就绪")
                self.reportDeployment(.vc, .running, "正在运行官方 VC++ x64 安装包…")
                try PrerequisiteService.shared.installVC(media: media, prefix: self.bottlePath)
                self.reportDeployment(.vc, .completed, "VC++ 运行库已检查")
                self.reportDeployment(.registry, .running, "正在准备安装序列号…")
                if let registry = self.selectedRegPath {
                    let code = try service.run(service.makeProcess(arguments: ["regedit", "/S", registry.path], prefix: self.bottlePath.path),
                        log: service.logDirectory(self.bottlePath.path).appendingPathComponent("registry-import.log"))
                    guard code == 0 else { throw NSError(domain: "MacSW", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "安装前注册表导入失败。"]) }
                }
                DispatchQueue.main.async {
                    self.statusMessage = "官方安装器已启动（DISABLEROLLBACK=1），请在安装窗口操作。"
                    self.deploymentStates[.registry] = self.selectedRegPath == nil ? .skipped : .completed
                    self.deploymentDetails[.registry] = self.selectedRegPath == nil ? "未选择 .reg，请在官方安装器中填写" : "已导入所选序列号注册表"
                    self.deploymentStates[.installer] = .running
                    self.deploymentDetails[.installer] = "请在官方安装窗口继续操作"
                    service.launchInstaller(setupExe: msi.path, winePrefix: self.bottlePath.path) { code in
                        let installerOK = [Int32(0), 3010, 194].contains(code)
                        self.deploymentStates[.installer] = installerOK ? .completed : .warning
                        self.deploymentDetails[.installer] = "安装器退出码 \(code)" + (installerOK ? "" : "；安装未完整完成，请查看日志")
                        self.checkInstallation()
                        guard self.hasInstalledExecutable else {
                            self.deploymentStates[.installer] = .failed
                            self.isOperating = false
                            self.statusMessage = "安装器退出（\(code)），未找到主程序。请检查安装日志。"
                            return
                        }
                        self.deploymentStates[.wpf] = .running
                        self.deploymentDetails[.wpf] = "正在从微软安装包提取五个主题库…"
                        self.extractAndInjectWpfThemes { ok in
                            self.deploymentStates[.wpf] = ok ? .completed : .failed
                            self.deploymentDetails[.wpf] = ok ? "五个 WPF 主题库已补齐" : self.statusMessage
                            self.isOperating = false
                            self.checkInstallation()
                            let ready = installerOK && ok && self.isVcRedistInjected
                            self.deploymentStates[.validation] = ready ? .completed : .warning
                            self.deploymentDetails[.validation] = ready ? "基础文件检查通过，可继续验证启动" : "文件已保留，安装或依赖仍需检查"
                            self.statusMessage = "安装器退出码 \(code)；WPF \(ok ? "已补齐" : "补齐失败")。" +
                                (ready ? "可继续验证启动。" : "安装或依赖未完整就绪，请查看日志。")
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isOperating = false
                    self.statusMessage = error.localizedDescription
                    if let step = DeploymentStep.allCases.first(where: { self.deploymentStates[$0] == .running }) {
                        self.deploymentStates[step] = .failed
                        self.deploymentDetails[step] = error.localizedDescription
                    }
                }
            }
        }
    }

    /// Only the fixed application bottle may be removed; inputs must survive cleanup.
    private func clearBottleForInstallation(media: URL) throws {
        let expected = appSupportDir.appendingPathComponent("bottle").standardizedFileURL
        let target = bottlePath.standardizedFileURL
        func failure(_ message: String) -> NSError {
            NSError(domain: "MacSW", code: 4, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard target == expected,
              target.resolvingSymlinksInPath() == target else {
            throw failure("容器路径异常或包含符号链接，已拒绝清理。")
        }
        for input in [selectedIsoPath, selectedRegPath, selectedLicenseDir, selectedPatchDir, media].compactMap({ $0 }) {
            let path = input.resolvingSymlinksInPath().path
            guard path != target.path && !path.hasPrefix(target.path + "/") else {
                throw failure("安装输入位于待删除的容器内，请先移到容器外再进行全新安装。")
            }
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else { return }
        reportDeployment(.environment, .running, "正在停止当前容器并清理旧安装（不备份）…")
        let service = WineService.shared
        for argument in ["-k", "-w"] {
            let process = service.makeProcess(arguments: [argument], prefix: target.path)
            process.executableURL = service.runtimeURL.appendingPathComponent("bin/wineserver")
            guard try service.run(process) == 0 else {
                throw failure("未能停止容器进程，已取消清理。")
            }
        }
        try fm.removeItem(at: target)
        DispatchQueue.main.sync {
            self.isInstalled = false
            self.isLicenseRunning = false
            self.isPatchApplied = false
            self.isWpfThemeInjected = false
            self.isVcRedistInjected = false
            self.checkInstallation()
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
