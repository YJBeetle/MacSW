import Foundation

@main
struct TestMediaInspector {
    static func main() {
        let mediaPath = "/Volumes/Solidworks1"
        guard FileManager.default.fileExists(atPath: mediaPath) else {
            print("[SKIP] /Volumes/Solidworks1 未挂载，跳过挂载点测试")
            exit(0)
        }

        let profile = MediaInspectorService.shared.inspect(mediaPath: mediaPath)
        print("解析到语言: \(profile.languages.map { "\($0.name)(\($0.lcid))" })")
        print("解析到组件: \(profile.components.map { $0.name })")
        print("预估总大小: \(profile.totalEstimatedBytes / 1024 / 1024) MB")
        
        assert(!profile.languages.isEmpty, "必须能够解析出语言列表")
        assert(profile.languages.contains(where: { $0.lcid == "0x0804" }), "必须包含简体中文 0x0804")
        assert(profile.languages.contains(where: { $0.lcid == "0x0409" }), "必须包含英语 0x0409")
        assert(profile.components.contains(where: { $0.id == "swwi" }), "必须包含核心主程序组件")
        assert(profile.components.contains(where: { $0.id == "Toolbox" }), "必须包含 Toolbox 组件")
        print("[PASS] MediaInspectorService 单元测试通过！")
    }
}
