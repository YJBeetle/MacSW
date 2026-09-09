import Foundation

class WineService {
    static let shared = WineService()

    func getWineBinary() -> String {
        // 检查包内自带 Wine
        let bundleWine = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/wine/bin/wine").path
        if FileManager.default.fileExists(atPath: bundleWine) {
            // 校验包内 Wine 架构，若为 x86_64 则直接使用
            let task = Process()
            task.launchPath = "/usr/bin/file"
            task.arguments = [bundleWine]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.launch()
            task.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if output.contains("x86_64") {
                return bundleWine
            }
        }

        // 回退到系统 CrossOver x86_64 Wine (通过 Rosetta 2 极速转译 Windows x86/x64 代码)
        if FileManager.default.fileExists(atPath: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine") {
            return "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine"
        }
        return "/usr/local/bin/wine"
    }

    func launchInstaller(setupExe: String, winePrefix: String, completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let wine = self.getWineBinary()
            let task = Process()
            task.launchPath = "/bin/bash"
            let runCmd = setupExe.hasSuffix(".msi") ? "msiexec /i \"\(setupExe)\"" : "\"\(setupExe)\""
            let script = """
            export WINEPREFIX='\(winePrefix)'
            export CX_BOTTLE='SolidWorks2025'
            export LC_ALL='zh_CN.UTF-8'
            /usr/bin/arch -x86_64 '\(wine)' \(runCmd)
            """
            task.arguments = ["-c", script]
            task.launch()
            task.waitUntilExit()
            DispatchQueue.main.async {
                completion()
            }
        }
    }

    func launchSolidWorks(exePath: String, winePrefix: String) {
        let wine = self.getWineBinary()
        let script = """
        export WINEPREFIX="\(winePrefix)"
        export CX_BOTTLE="SolidWorks2025"
        export LC_ALL="zh_CN.UTF-8"
        export WINEDLLOVERRIDES="concrt140=n,b;msvcp140=n,b;vcruntime140=n,b;d3d11=n,b;dxgi=n,b"
        nohup /usr/bin/arch -x86_64 "\(wine)" "\(exePath)" >/dev/null 2>&1 &
        """
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", script]
        task.launch()
    }
}
