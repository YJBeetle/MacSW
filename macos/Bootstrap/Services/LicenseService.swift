import Foundation

class LicenseService {
    static let shared = LicenseService()

    func startLocalServer(serverDir: URL, wineBin: String, winePrefix: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // 检查目录中是否有 server_install.bat 或 lmgrd.exe
            let lmgrdPath = serverDir.appendingPathComponent("lmgrd.exe").path
            guard FileManager.default.fileExists(atPath: lmgrdPath) else {
                completion(false)
                return
            }

            let script = """
            export WINEPREFIX="\(winePrefix)"
            export LC_ALL="zh_CN.UTF-8"
            cd "\(serverDir.path)"
            nohup "\(wineBin)" "\(lmgrdPath)" -c sw_d.lic -l lmgrd.log >/dev/null 2>&1 &
            sleep 2
            nc -z -w 2 127.0.0.1 25734
            """

            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = ["-c", script]
            task.launch()
            task.waitUntilExit()

            DispatchQueue.main.async {
                completion(task.terminationStatus == 0)
            }
        }
    }

    func stopLocalServer() {
        let task = Process()
        task.launchPath = "/usr/bin/pkill"
        task.arguments = ["-f", "lmgrd.exe"]
        task.launch()
        task.waitUntilExit()
    }
}
