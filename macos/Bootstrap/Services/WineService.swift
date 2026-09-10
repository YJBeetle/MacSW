import Foundation
import AppKit

class WineService {
    static let shared = WineService()

    func killWineProcesses() {
        let script = "killall -9 wineserver wineloader wine64-preloader wine-preloader msiexec.exe setup.exe sldworks.exe 2>/dev/null || true"
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", script]
        try? task.run()
        task.waitUntilExit()
    }

    func getWineBinary() -> String {
        // 1. 最高优先级：检查 App Bundle 内置的定制 Wine Runtime (Contents/Frameworks/wine)
        let bundleFrameworks = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/wine")
        let candidates = [
            bundleFrameworks.appendingPathComponent("bin/wine64").path,
            bundleFrameworks.appendingPathComponent("bin/wineloader").path,
            bundleFrameworks.appendingPathComponent("bin/wine").path
        ]
        for c in candidates {
            if FileManager.default.isExecutableFile(atPath: c) {
                return c
            }
        }

        // 2. 次优：CrossOver 官方环境 (系统安装，作为备用)
        let cxLoader = "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wineloader"
        if FileManager.default.isExecutableFile(atPath: cxLoader) {
            return cxLoader
        }

        // 3. 检查系统其他 x86_64/WoW64 Wine
        for sysWine in ["/opt/homebrew/bin/wine64", "/usr/local/bin/wine", "/opt/homebrew/bin/wine"] {
            if FileManager.default.isExecutableFile(atPath: sysWine) {
                return sysWine
            }
        }

        if FileManager.default.isExecutableFile(atPath: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine") {
            return "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine"
        }
        return "/usr/local/bin/wine"
    }

    private func buildEnvironmentScript(winePrefix: String) -> String {
        let wineBin = self.getWineBinary()
        let wineDir = URL(fileURLWithPath: wineBin).deletingLastPathComponent().deletingLastPathComponent().path
        let wineLib = "\(wineDir)/lib"
        let isBundleWine = wineBin.contains("Contents/Frameworks/wine")
        let cxRoot = isBundleWine ? wineDir : "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
        
        return """
        export WINEPREFIX='\(winePrefix)'
        export LANG='zh_CN.UTF-8'
        export LC_ALL='zh_CN.UTF-8'
        export WINEDEBUG='-all'
        if [ -d '\(cxRoot)' ]; then
            export CX_ROOT='\(cxRoot)'
        fi
        if [ -d '\(wineLib)' ]; then
            export DYLD_FALLBACK_LIBRARY_PATH='\(wineLib)':$DYLD_FALLBACK_LIBRARY_PATH
        fi
        """
    }

    func launchInstaller(setupExe: String, winePrefix: String, completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let wine = self.getWineBinary()
            let envHeader = self.buildEnvironmentScript(winePrefix: winePrefix)
            let logFile = "\(winePrefix)/../logs/install_msi.log"
            try? FileManager.default.createDirectory(atPath: "\(winePrefix)/../logs", withIntermediateDirectories: true)

            let runCmd: String
            if setupExe.hasSuffix(".msi") {
                runCmd = "\"\(wine)\" msiexec /i \"\(setupExe)\" DISABLEROLLBACK=1 /l*v \"\(logFile)\""
            } else {
                runCmd = "\"\(wine)\" \"\(setupExe)\""
            }

            let script = """
            \(envHeader)
            \(runCmd)
            """
            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = ["-c", script]
            task.launch()
            task.waitUntilExit()
            DispatchQueue.main.async {
                completion()
            }
        }
    }

    func launchSolidWorks(exePath: String, winePrefix: String) {
        let runScriptPath = "/Volumes/Data/Workspace/WineSW/run_sw.sh"
        let logDir = URL(fileURLWithPath: winePrefix).deletingLastPathComponent().appendingPathComponent("logs").path
        let logFile = "\(logDir)/sw_launch.log"
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)

        let appDaemon = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/sw_ui_daemon.exe")
        let wsDaemon = URL(fileURLWithPath: "/Volumes/Data/Workspace/WineSW/scripts/sw_ui_daemon.exe")
        let daemonPath = FileManager.default.fileExists(atPath: appDaemon.path) ? appDaemon.path : wsDaemon.path

        let script: String
        if FileManager.default.fileExists(atPath: runScriptPath) {
            script = "export WINEPREFIX='\(winePrefix)'; nohup \"\(runScriptPath)\" \"\(exePath)\" >> \"\(logFile)\" 2>&1 &"
        } else {
            let wine = self.getWineBinary()
            let envHeader = self.buildEnvironmentScript(winePrefix: winePrefix)
            let exeDir = URL(fileURLWithPath: exePath).deletingLastPathComponent().path
            script = """
            \(envHeader)
            export SOLIDWORKS_LICENSE_FILE="25734@127.0.0.1;25734@localhost"
            export SW_D_LICENSE_FILE="25734@127.0.0.1;25734@localhost"
            export WINEDLLOVERRIDES="mscoree=n,b;concrt140=n,b;msvcp140=n,b;msvcp140_1=n,b;msvcp140_2=n,b;msvcp140_atomic_wait=n,b;msvcp140_codecvt_ids=n,b;vcruntime140=n,b;vcruntime140_1=n,b;vcomp140=n,b;mfc140u=n,b;d3dcompiler_47=n,b;d3d11=n,b;dxgi=n,b"
            if [ -f "\(daemonPath)" ]; then
                nohup "\(wine)" "\(daemonPath)" --watch >/dev/null 2>&1 &
            fi
            cd "\(exeDir)"
            nohup "\(wine)" "\(exePath)" >> "\(logFile)" 2>&1 &
            """
        }
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", script]
        task.launch()
    }

    func runWineCommand(command: String, winePrefix: String, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let wine = self.getWineBinary()
            let envHeader = self.buildEnvironmentScript(winePrefix: winePrefix)
            let script = """
            \(envHeader)
            "\(wine)" \(command)
            """
            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = ["-c", script]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            task.launch()
            task.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let success = (task.terminationStatus == 0)
            DispatchQueue.main.async {
                completion(success, output)
            }
        }
    }
}
