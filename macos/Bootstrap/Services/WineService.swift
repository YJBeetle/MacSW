import Foundation

class WineService {
    static let shared = WineService()

    func getWineBinary() -> String {
        // 优先使用 App 包内自带的定制 Wine Runtime
        let bundleWine = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/wine/bin/wine").path
        if FileManager.default.fileExists(atPath: bundleWine) {
            return bundleWine
        }
        // 回退到系统 PATH 或 CrossOver
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
            task.arguments = ["-c", "export WINEPREFIX='\(winePrefix)'; export LC_ALL='zh_CN.UTF-8'; '\(wine)' '\(setupExe)'"]
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
        export LC_ALL="zh_CN.UTF-8"
        export WINEDLLOVERRIDES="concrt140=n,b;msvcp140=n,b;vcruntime140=n,b;d3d11=n,b;dxgi=n,b"
        nohup "\(wine)" "\(exePath)" >/dev/null 2>&1 &
        """
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", script]
        task.launch()
    }
}
