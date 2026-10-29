import Foundation

/// Updating replaces the whole runtime. Never kill a CAD session to install it.
public enum AppUpdatePolicy {
    public static let feedURL = "https://github.com/YJBeetle/MacSW/releases/latest/download/appcast.xml"

    public static func blockingReason(maintenance: Bool, processes: [WineProcess]) -> String? {
        if maintenance { return "安装、迁移或服务操作尚未结束，请完成后再安装更新。" }
        if ProcessInventory.isSolidWorksRunning(processes) {
            return "请先保存文档并退出 SOLIDWORKS，再安装更新。辅助进程会自动收尾。"
        }
        return nil
    }

    public static func validPublicKey(_ value: String) -> Bool {
        Data(base64Encoded: value)?.count == 32
    }
}
