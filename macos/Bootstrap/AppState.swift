import Foundation
import SwiftUI

class AppState: ObservableObject {
    @Published var isInstalled: Bool = false
    @Published var isLicenseRunning: Bool = false
    @Published var isLaunching: Bool = false
    @Published var logMessage: String = ""

    // 安装向导状态
    @Published var selectedIsoPath: URL? = nil
    @Published var selectedLicenseDir: URL? = nil
    @Published var isExtractingOrMounting: Bool = false
    @Published var mountedVolumePath: String? = nil

    let bottlePath: URL
    let sldworksExePath: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.bottlePath = appSupport.appendingPathComponent("MacSW/bottle")
        self.sldworksExePath = self.bottlePath.appendingPathComponent("drive_c/Program Files/SOLIDWORKS Corp/SOLIDWORKS/SLDWORKS.exe")
        self.isInstalled = FileManager.default.fileExists(atPath: self.sldworksExePath.path)
    }

    func checkInstallation() {
        self.isInstalled = FileManager.default.fileExists(atPath: sldworksExePath.path)
    }

    func checkLicenseStatus() {
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", "nc -z -w 1 127.0.0.1 25734 >/dev/null 2>&1"]
        task.launch()
        task.waitUntilExit()
        DispatchQueue.main.async {
            self.isLicenseRunning = (task.terminationStatus == 0)
        }
    }
}
