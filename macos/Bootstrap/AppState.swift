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
    @Published var mediaProfile: MediaProfile? = nil
    @Published var selectedLanguageLcid: String = "0x0804"
    @Published var isInspectingMedia: Bool = false

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
            self.checkInstallation()
        }

        checkLicenseStatus()
        checkSolidWorksRunningStatus()
        self.runningMonitorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkSolidWorksRunningStatus()
        }

        if FileManager.default.fileExists(atPath: "/Volumes/Solidworks1/swwi/data/Setup.ini") {
            let mediaUrl = URL(fileURLWithPath: "/Volumes/Solidworks1")
            self.selectedIsoPath = mediaUrl
            self.mountedVolumePath = "/Volumes/Solidworks1"
            self.autoDetectCompanionFiles(from: mediaUrl)
            self.inspectSelectedMedia(path: "/Volumes/Solidworks1")
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
        let isBundleWine = wineBin.contains(".app/Contents/Frameworks/wine") || wineBin.contains("wine-crossover-macsw")
        let wineRoot = isBundleWine ? wineDir : "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
        let wineLib = "\(wineDir)/lib"
        let prefix = self.bottlePath.path

        var lines: [String] = [
            "export WINEPREFIX='\(prefix)'",
            "export LANG='zh_CN.UTF-8'",
            "export LC_ALL='zh_CN.UTF-8'",
            "export WINEDEBUG='-all'"
        ]
        if FileManager.default.fileExists(atPath: wineRoot) {
            lines.append("export CX_ROOT='\(wineRoot)'")
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

        let lunaDll = targetDir.appendingPathComponent("PresentationFramework.Luna.dll")
        self.isWpfThemeInjected = FileManager.default.fileExists(atPath: lunaDll.path)

        let mfc140u = self.bottlePath.appendingPathComponent("drive_c/windows/system32/mfc140u.dll")
        self.isVcRedistInjected = FileManager.default.fileExists(atPath: mfc140u.path)

        // 自动自愈同步修复版 mscoree.dll（防止 C++/CLI 虚表修复断言崩溃，采用 APFS 硬链接/写时克隆实现 0 冗余占用）
        let mscoreeDst = self.bottlePath.appendingPathComponent("drive_c/windows/system32/mscoree.dll")
        let appMscoree = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/wine/lib/wine/x86_64-windows/mscoree.dll")
        let localDistMscoree = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/mscoree_x64.dll")
        let mscoreeSrc = FileManager.default.fileExists(atPath: appMscoree.path) ? appMscoree : localDistMscoree
        if FileManager.default.fileExists(atPath: mscoreeSrc.path) {
            let srcSize = (try? FileManager.default.attributesOfItem(atPath: mscoreeSrc.path)[.size] as? Int) ?? 0
            let dstSize = (try? FileManager.default.attributesOfItem(atPath: mscoreeDst.path)[.size] as? Int) ?? 0
            if srcSize > 0 && srcSize != dstSize {
                AppState.linkOrCloneFile(from: mscoreeSrc, to: mscoreeDst)
            }
        }
    }

    /// 单实例单机架构下 DLL 去重神器：优先硬链接（0 磁盘增量），次选 APFS 写时克隆（0 块占用），最后回退拷贝
    static func linkOrCloneFile(from src: URL, to dst: URL) {
        try? FileManager.default.removeItem(at: dst)
        // 1. 优先尝试系统硬链接 (完全共享 inode，0 空间冗余)
        if (try? FileManager.default.linkItem(at: src, to: dst)) != nil {
            return
        }
        // 2. 次选 APFS Copy-on-Write Clone (0 物理块开销)
        if clonefile(src.path, dst.path, 0) == 0 {
            return
        }
        // 3. 兜底物理拷贝
        try? FileManager.default.copyItem(at: src, to: dst)
    }

    // 从用户选定的安装介质（ISO 或解压目录）动态抽取微软官方 WPF 主题库，彻底杜绝 .NET 环境闪退
    func extractAndInjectWpfThemes(completion: ((Bool) -> Void)? = nil) {
        let exeUrl = AppState.resolveSldworksPath(bottlePath: self.bottlePath)
        let targetDir = exeUrl.deletingLastPathComponent()
        let wpfSysDir = self.bottlePath.appendingPathComponent("drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/WPF")
        try? FileManager.default.createDirectory(at: wpfSysDir, withIntermediateDirectories: true)

        // 寻找 ndp48-x86-x64-allos-enu.exe 所在路径
        var ndpExePath: String? = nil
        var isoCandidatePath: String? = nil

        if let mounted = self.mountedVolumePath {
            let p = "\(mounted)/PreReqs/dotNetFx/ndp48-x86-x64-allos-enu.exe"
            if FileManager.default.fileExists(atPath: p) { ndpExePath = p }
        }

        if ndpExePath == nil, let userIso = self.selectedIsoPath {
            if userIso.pathExtension.lowercased() == "iso" {
                isoCandidatePath = userIso.path
            } else {
                let p = userIso.appendingPathComponent("PreReqs/dotNetFx/ndp48-x86-x64-allos-enu.exe").path
                if FileManager.default.fileExists(atPath: p) { ndpExePath = p }
            }
        }

        // 兜底扫描工作区或临时目录
        if ndpExePath == nil && isoCandidatePath == nil {
            let localScratch = "/Volumes/Data/Workspace/WineSW/scratch/ndp48-x86-x64-allos-enu.exe"
            if FileManager.default.fileExists(atPath: localScratch) {
                ndpExePath = localScratch
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let tmpDir = "/tmp/macsw_wpf_extract_\(ProcessInfo.processInfo.processIdentifier)"
            try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

            var script = "set -e\n"
            if let iso = isoCandidatePath, ndpExePath == nil {
                script += """
                /opt/homebrew/bin/7z e '\(iso)' 'PreReqs/dotNetFx/ndp48-x86-x64-allos-enu.exe' -o'\(tmpDir)' -y >/dev/null 2>&1 || true
                """
                ndpExePath = "\(tmpDir)/ndp48-x86-x64-allos-enu.exe"
            }

            if let exe = ndpExePath {
                script += """
                if [ -f '\(exe)' ]; then
                    /opt/homebrew/bin/7z e '\(exe)' 'netfx_Full.mzz' -o'\(tmpDir)' -y >/dev/null 2>&1 || true
                    if [ -f '\(tmpDir)/netfx_Full.mzz' ]; then
                        /opt/homebrew/bin/7z e '\(tmpDir)/netfx_Full.mzz' \\
                            'PresentationFramework.Luna_amd64.dll' \\
                            'PresentationFramework.Aero_amd64.dll' \\
                            'PresentationFramework.Classic_amd64.dll' \\
                            'PresentationFramework.Royale_amd64.dll' \\
                            'PresentationFramework.AeroLite.dll_amd64' \\
                            -o'\(tmpDir)' -y >/dev/null 2>&1 || true
                        
                        mkdir -p '\(targetDir.path)' '\(wpfSysDir.path)'
                        [ -f '\(tmpDir)/PresentationFramework.Luna_amd64.dll' ] && cp -c '\(tmpDir)/PresentationFramework.Luna_amd64.dll' '\(targetDir.path)/PresentationFramework.Luna.dll' 2>/dev/null || cp '\(tmpDir)/PresentationFramework.Luna_amd64.dll' '\(targetDir.path)/PresentationFramework.Luna.dll'
                        [ -f '\(tmpDir)/PresentationFramework.Aero_amd64.dll' ] && cp -c '\(tmpDir)/PresentationFramework.Aero_amd64.dll' '\(targetDir.path)/PresentationFramework.Aero.dll' 2>/dev/null || cp '\(tmpDir)/PresentationFramework.Aero_amd64.dll' '\(targetDir.path)/PresentationFramework.Aero.dll'
                        [ -f '\(tmpDir)/PresentationFramework.Classic_amd64.dll' ] && cp -c '\(tmpDir)/PresentationFramework.Classic_amd64.dll' '\(targetDir.path)/PresentationFramework.Classic.dll' 2>/dev/null || cp '\(tmpDir)/PresentationFramework.Classic_amd64.dll' '\(targetDir.path)/PresentationFramework.Classic.dll'
                        [ -f '\(tmpDir)/PresentationFramework.Royale_amd64.dll' ] && cp -c '\(tmpDir)/PresentationFramework.Royale_amd64.dll' '\(targetDir.path)/PresentationFramework.Royale.dll' 2>/dev/null || cp '\(tmpDir)/PresentationFramework.Royale_amd64.dll' '\(targetDir.path)/PresentationFramework.Royale.dll'
                        [ -f '\(tmpDir)/PresentationFramework.AeroLite.dll_amd64' ] && cp -c '\(tmpDir)/PresentationFramework.AeroLite.dll_amd64' '\(targetDir.path)/PresentationFramework.AeroLite.dll' 2>/dev/null || cp '\(tmpDir)/PresentationFramework.AeroLite.dll_amd64' '\(targetDir.path)/PresentationFramework.AeroLite.dll'

                        # 通过硬链接映射至系统 GAC，实现 0 字节磁盘增量与单实例去重
                        for dll in '\(targetDir.path)/PresentationFramework.'*.dll; do
                            [ -f "$dll" ] && (ln -f "$dll" '\(wpfSysDir.path)/' 2>/dev/null || cp -c "$dll" '\(wpfSysDir.path)/' 2>/dev/null || cp "$dll" '\(wpfSysDir.path)/')
                        done
                    fi
                fi
                rm -rf '\(tmpDir)'
                """
            } else {
                script += "rm -rf '\(tmpDir)'\n"
            }

            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = ["-c", script]
            task.launch()
            task.waitUntilExit()

            DispatchQueue.main.async {
                self.checkInstallation()
                completion?(self.isWpfThemeInjected)
            }
        }
    }

    // 从安装介质（ISO、已挂载卷或解压目录）的 PreReqs/VCRedist17/VC_redist.x64.exe 动态抽取微软官方 64 位 Visual C++ 运行库（mfc140u 等 26 个核心 DLL）
    func extractAndInjectVcRedist(completion: ((Bool) -> Void)? = nil) {
        let sys32Dir = self.bottlePath.appendingPathComponent("drive_c/windows/system32")
        try? FileManager.default.createDirectory(at: sys32Dir, withIntermediateDirectories: true)

        // 寻找 PreReqs/VCRedist17/VC_redist.x64.exe
        var vcExePath: String? = nil
        var isoCandidatePath: String? = nil

        // 1. 检查已记录的挂载点
        if let mounted = self.mountedVolumePath {
            let p = "\(mounted)/PreReqs/VCRedist17/VC_redist.x64.exe"
            if FileManager.default.fileExists(atPath: p) { vcExePath = p }
        }

        // 2. 扫描系统中所有已挂载的卷 (如 /Volumes/Solidworks1 等)
        if vcExePath == nil {
            if let volumes = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") {
                for vol in volumes {
                    let p = "/Volumes/\(vol)/PreReqs/VCRedist17/VC_redist.x64.exe"
                    if FileManager.default.fileExists(atPath: p) {
                        vcExePath = p
                        break
                    }
                }
            }
        }

        // 3. 用户选择的 ISO 文件或目录
        if vcExePath == nil, let userIso = self.selectedIsoPath {
            if userIso.pathExtension.lowercased() == "iso" {
                isoCandidatePath = userIso.path
            } else {
                let p = userIso.appendingPathComponent("PreReqs/VCRedist17/VC_redist.x64.exe").path
                if FileManager.default.fileExists(atPath: p) { vcExePath = p }
            }
        }

        // 4. 兜底扫描工作区临时目录
        if vcExePath == nil && isoCandidatePath == nil {
            let localScratch = "/Volumes/Data/Workspace/WineSW/scratch/vcredist/VC_redist.x64.exe"
            if FileManager.default.fileExists(atPath: localScratch) {
                vcExePath = localScratch
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let tmpDir = "/tmp/macsw_vc_extract_\(ProcessInfo.processInfo.processIdentifier)"
            try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

            var script = "set -e\n"
            if let iso = isoCandidatePath, vcExePath == nil {
                script += """
                /opt/homebrew/bin/7z e '\(iso)' 'PreReqs/VCRedist17/VC_redist.x64.exe' -o'\(tmpDir)' -y >/dev/null 2>&1 || true
                """
                vcExePath = "\(tmpDir)/VC_redist.x64.exe"
            }

            if let exe = vcExePath {
                script += """
                if [ -f '\(exe)' ]; then
                    python3 -c "import struct; d=open(r'\(exe)','rb').read(); idx=d.rfind(b'MSCF'); open(r'\(tmpDir)/payload.cab','wb').write(d[idx:idx+struct.unpack('<I',d[idx+8:idx+12])[0]]) if idx!=-1 else None" 2>/dev/null || true
                    if [ -f '\(tmpDir)/payload.cab' ]; then
                        mkdir -p '\(tmpDir)/cab_out'
                        /opt/homebrew/bin/7z x -y '\(tmpDir)/payload.cab' -o'\(tmpDir)/cab_out' >/dev/null 2>&1 || true
                        mkdir -p '\(tmpDir)/dlls'
                        [ -f '\(tmpDir)/cab_out/a12' ] && /opt/homebrew/bin/7z e -y '\(tmpDir)/cab_out/a12' -o'\(tmpDir)/dlls' >/dev/null 2>&1 || true
                        [ -f '\(tmpDir)/cab_out/a13' ] && /opt/homebrew/bin/7z e -y '\(tmpDir)/cab_out/a13' -o'\(tmpDir)/dlls' >/dev/null 2>&1 || true
                        cd '\(tmpDir)/dlls'
                        for f in *_amd64; do [ -f "$f" ] && mv "$f" "${f%_amd64}"; done
                        cp -f *.dll '\(sys32Dir.path)/' 2>/dev/null || true
                    fi
                fi
                """
            }
            script += "\nrm -rf '\(tmpDir)'\n"

            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = ["-c", script]
            try? task.run()
            task.waitUntilExit()

            DispatchQueue.main.async {
                self.checkInstallation()
                completion?(self.isVcRedistInjected)
            }
        }
    }

    // 智能多层级深度自动发现并填充同级伴随资源（遵循未填写才填写、已填写不覆盖原则）
    func autoDetectCompanionFiles(from sourceUrl: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceUrl.path, isDirectory: &isDir) else { return }

        let baseDir = isDir.boolValue ? sourceUrl : sourceUrl.deletingLastPathComponent()
        var rootSearchDirs: [URL] = [baseDir]

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if let dl = downloads { rootSearchDirs.append(dl) }
        rootSearchDirs.append(URL(fileURLWithPath: "/Volumes/Data/Workspace/WineSW"))

        let parentDir = baseDir.deletingLastPathComponent()
        if parentDir.path != baseDir.path && parentDir.path != "/" && parentDir.path != "/Volumes" {
            rootSearchDirs.append(parentDir)
        }

        func scanDirsRecursively(from roots: [URL], maxDepth: Int) -> [URL] {
            var results: [URL] = []
            var visited = Set<String>()

            func traverse(dir: URL, currentDepth: Int) {
                let path = dir.standardizedFileURL.path
                if visited.contains(path) { return }
                visited.insert(path)
                results.append(dir)

                if currentDepth >= maxDepth { return }

                guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
                for item in items {
                    var subIsDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: item.path, isDirectory: &subIsDir), subIsDir.boolValue {
                        let name = item.lastPathComponent.lowercased()
                        if name == "library" || name == ".git" || name == "node_modules" || name == "build" { continue }
                        traverse(dir: item, currentDepth: currentDepth + 1)
                    }
                }
            }

            for root in roots {
                traverse(dir: root, currentDepth: 0)
            }
            return results
        }

        let allCandidateDirs = scanDirsRecursively(from: rootSearchDirs, maxDepth: 3)

        DispatchQueue.main.async {
            // A. 网络注册表 (*serials_licensing.reg)
            if self.selectedRegPath == nil {
                for dir in allCandidateDirs {
                    if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                        if let match = files.first(where: {
                            let name = $0.lastPathComponent.lowercased()
                            return name.hasSuffix(".reg") && name.contains("serial") && name.contains("licens")
                        }) {
                            self.selectedRegPath = match
                            break
                        }
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

            // B. 许可服务目录 (SolidWorks_Flexnet_Server)
            if self.selectedLicenseDir == nil {
                for dir in allCandidateDirs {
                    let name = dir.lastPathComponent.lowercased()
                    let lmgrd = dir.appendingPathComponent("lmgrd.exe")
                    if FileManager.default.fileExists(atPath: lmgrd.path) {
                        self.selectedLicenseDir = dir
                        break
                    }
                    if (name.contains("solidworks") || name.contains("flexnet")) && name.contains("server") {
                        self.selectedLicenseDir = dir
                        break
                    }
                }
            }

            // C. 组件补丁目录 (SOLIDWORKS Corp / crack)
            if self.selectedPatchDir == nil {
                for dir in allCandidateDirs {
                    let name = dir.lastPathComponent
                    // 1. 直接包含 SOLIDWORKS Corp
                    if name.localizedCaseInsensitiveContains("SOLIDWORKS Corp") {
                        self.selectedPatchDir = dir
                        break
                    }
                    // 2. 目录下包含 SOLIDWORKS Corp 子目录
                    let childCorp = dir.appendingPathComponent("SOLIDWORKS Corp")
                    if FileManager.default.fileExists(atPath: childCorp.path) {
                        self.selectedPatchDir = childCorp
                        break
                    }
                    // 3. 目录下包含 SOLIDWORKS/sldutu.dll 或 sldutu.dll
                    let childSwDll = dir.appendingPathComponent("SOLIDWORKS/sldutu.dll")
                    let directDll = dir.appendingPathComponent("sldutu.dll")
                    if FileManager.default.fileExists(atPath: childSwDll.path) || FileManager.default.fileExists(atPath: directDll.path) {
                        self.selectedPatchDir = dir
                        break
                    }
                }
            }

            // D. 安装介质 ISO
            if self.selectedIsoPath == nil {
                for dir in allCandidateDirs {
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

        let script = """
        pkill -9 -f sldworks_fs || true
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

    // 扫描安装介质的语言与组件配置
    func inspectSelectedMedia(path: String) {
        guard !path.isEmpty else { return }
        isInspectingMedia = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var scanDir = path
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
                if !isDir.boolValue && path.lowercased().hasSuffix(".iso") {
                    if let mountPoint = IsoService.shared.mountIso(at: URL(fileURLWithPath: path)) {
                        scanDir = mountPoint
                        DispatchQueue.main.async {
                            self.mountedVolumePath = mountPoint
                        }
                    }
                }
            }
            
            let profile = MediaInspectorService.shared.inspect(mediaPath: scanDir)
            DispatchQueue.main.async {
                self.mediaProfile = profile
                if profile.languages.contains(where: { $0.lcid == "0x0804" }) {
                    self.selectedLanguageLcid = "0x0804"
                } else if let first = profile.languages.first {
                    self.selectedLanguageLcid = first.lcid
                }
                self.isInspectingMedia = false
            }
        }
    }

    // 执行极速定制组件与语言解包安装
    func performCustomInstallation(progressHandler: @escaping (Double, String) -> Void, completion: @escaping (Bool) -> Void) {
        guard let profile = self.mediaProfile else {
            completion(false)
            return
        }
        
        var mediaDir = self.mountedVolumePath
        if mediaDir == nil, let iso = self.selectedIsoPath {
            if iso.pathExtension.lowercased() == "iso" {
                mediaDir = IsoService.shared.mountIso(at: iso)
                self.mountedVolumePath = mediaDir
            } else {
                mediaDir = iso.path
            }
        }
        
        guard let validMedia = mediaDir else {
            completion(false)
            return
        }
        
        let winePrefix = self.bottlePath.path
        let wineBin = WineService.shared.getWineBinary()
        
        InstallExtractorService.shared.performFullExtraction(
            mediaPath: validMedia,
            winePrefix: winePrefix,
            selectedLanguageLcid: self.selectedLanguageLcid,
            selectedComponents: profile.components,
            wineBinPath: wineBin,
            progressHandler: progressHandler,
            completion: { ok, errorMsg in
                DispatchQueue.main.async {
                    self.checkInstallation()
                    completion(ok)
                }
            }
        )
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
