import Foundation

@main
struct TestE2EExtraction {
    static func main() {
        print("==> 开始端到端介质提取与路径验证测试...")
        
        let mediaPath = "/Volumes/Solidworks1"
        guard FileManager.default.fileExists(atPath: mediaPath) else {
            print("[SKIP] /Volumes/Solidworks1 未挂载，跳过测试")
            exit(0)
        }
        
        let testPrefix = "/tmp/macsw_e2e_test_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: testPrefix, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: testPrefix)
        }
        
        let profile = MediaInspectorService.shared.inspect(mediaPath: mediaPath)
        print("介质包含 \(profile.languages.count) 种语言，\(profile.components.count) 个组件")
        
        // 选取核心主程序 + 简体中文 + Toolbox 进行快速验证
        let selectedComps = profile.components.filter { $0.id == "swwi" || $0.id == "Toolbox" }
        
        let sema = DispatchSemaphore(value: 0)
        var extractionSuccess = false
        var extractionError: String? = nil
        
        InstallExtractorService.shared.performFullExtraction(
            mediaPath: mediaPath,
            winePrefix: testPrefix,
            selectedLanguageLcid: "0x0804",
            selectedComponents: selectedComps,
            wineBinPath: nil, // 测试模式不拉起 wineboot
            progressHandler: { progress, msg in
                if Int(progress * 100) % 20 == 0 {
                    print(String(format: "[进度: %d%%] %@", Int(progress * 100), msg))
                }
            },
            completion: { ok, err in
                extractionSuccess = ok
                extractionError = err
                sema.signal()
            }
        )
        
        _ = sema.wait(timeout: .now() + 180)
        
        assert(extractionSuccess, "提取操作必须成功: \(extractionError ?? "")")
        
        let fm = FileManager.default
        let sldworksExe = "\(testPrefix)/drive_c/Program Files/SOLIDWORKS Corp/SOLIDWORKS/sldworks.exe"
        assert(fm.fileExists(atPath: sldworksExe), "目标路径必须包含: \(sldworksExe)")
        
        let zhLangDir = "\(testPrefix)/drive_c/Program Files/SOLIDWORKS Corp/SOLIDWORKS/lang/chinese-simplified"
        assert(fm.fileExists(atPath: zhLangDir), "必须包含简体中文目录: \(zhLangDir)")
        
        let regFile = "\(testPrefix)/install_settings.reg"
        assert(fm.fileExists(atPath: regFile), "必须生成注册表配置文件")
        let regContent = (try? String(contentsOfFile: regFile, encoding: .utf8)) ?? ""
        assert(regContent.contains("C:\\\\Program Files\\\\SOLIDWORKS Corp\\\\SOLIDWORKS"), "注册表路径必须指向 Program Files\\\\SOLIDWORKS Corp\\\\SOLIDWORKS")
        assert(regContent.contains("\"Current Language\"=\"Chinese Simplified\""), "注册表语言必须为 Chinese Simplified")
        
        print("==> [PASS] 端到端介质提取与路径验证全部通过！")
        print("    核心程序: \(sldworksExe)")
        print("    中文语言包: \(zhLangDir)")
        print("    注册表配置已就绪")
        exit(0)
    }
}
