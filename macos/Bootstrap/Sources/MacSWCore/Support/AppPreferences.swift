import Foundation

/// 应用级偏好的单一来源：键名与默认值只在这里定义一次。
public enum AppPreferences {
    public static let autoLaunchSolidWorksKey = "MacSW.autoLaunchSolidWorks"

    /// 打开 MacSW 只为了看状态和改设置，因此默认不自动拉起 SOLIDWORKS。
    public static let autoLaunchSolidWorksDefault = false

    public static func autoLaunchSolidWorks(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: autoLaunchSolidWorksKey) != nil else {
            return autoLaunchSolidWorksDefault
        }
        return defaults.bool(forKey: autoLaunchSolidWorksKey)
    }
}

public enum BootstrapWindowIdentity {
    /// 用于在 13/14 上精确关闭引导窗口，避免按标题字符串匹配。
    public static let identifier = "MacSW.bootstrap"
}
