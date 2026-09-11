import Foundation

@main
struct TestInstallExtractor {
    static func main() {
        print("==> 测试 InstallExtractorService...")
        
        let extractor = InstallExtractorService.shared
        guard let sevenZip = extractor.find7zPath() else {
            fatalError("系统未找到 7z 工具，请先 brew install p7zip")
        }
        print("发现 7z: \(sevenZip)")
        
        // 测试文件名规范化 (修复 MSI 数字后缀)
        let sample1 = "sldmfcu.dll1"
        let norm1 = extractor.normalizeFileName(sample1)
        assert(norm1 == "sldmfcu.dll", "sldmfcu.dll1 应还原为 sldmfcu.dll")
        
        let sample2 = "swscheduler.exe1"
        let norm2 = extractor.normalizeFileName(sample2)
        assert(norm2 == "swscheduler.exe", "swscheduler.exe1 应还原为 swscheduler.exe")
        
        let sample3 = "normal_file.dll"
        let norm3 = extractor.normalizeFileName(sample3)
        assert(norm3 == "normal_file.dll", "普通文件不应被误改")
        
        // 测试注册表内容生成
        let regContent = extractor.generateRegistryContent(language: "Chinese Simplified")
        assert(regContent.contains("Windows Registry Editor Version 5.00"), "必须包含注册表文件头")
        assert(regContent.contains("\"Current Language\"=\"Chinese Simplified\""), "必须包含语言配置项")
        
        // 测试小包解压验证
        let testCab = "/Volumes/Solidworks1/swwi/data/BOData.cab"
        if FileManager.default.fileExists(atPath: testCab) {
            let tmpDir = "/tmp/test_sw_extractor_\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmpDir) }
            
            let success = extractor.extractSingleArchive(archivePath: testCab, destinationDir: tmpDir)
            assert(success, "解压 BOData.cab 应该成功")
            
            let files = (try? FileManager.default.contentsOfDirectory(atPath: tmpDir)) ?? []
            assert(!files.isEmpty, "解压后目录不应为空")
            print("解压成功，文件列表: \(files)")
        } else {
            print("[SKIP] 介质未挂载，跳过解包实际执行")
        }
        
        print("[PASS] InstallExtractorService 单元测试通过！")
    }
}
