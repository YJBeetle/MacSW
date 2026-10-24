import Foundation

/// Updating replaces the whole runtime. Never kill a CAD session to install it.
public enum AppUpdatePolicy {
    public static let feedURL = "https://github.com/YJBeetle/MacSW/releases/latest/download/appcast.xml"

    public static func blockingReason(maintenance: Bool, processes: [WineProcess]) -> String? {
        if maintenance { return "安装、迁移或服务操作尚未结束，请完成后再安装更新。" }
        let services: Set<String> = ["wineserver", "lmgrd.exe", "sw_d.exe"]
        if processes.contains(where: { !services.contains($0.name.lowercased()) }) {
            return "请先保存文档并退出 SOLIDWORKS、SWCLI 和其他 Wine 程序，再安装更新。MacSW 不会为更新强制结束这些程序。"
        }
        return nil
    }

    public static func validPublicKey(_ value: String) -> Bool {
        Data(base64Encoded: value)?.count == 32
    }
}
