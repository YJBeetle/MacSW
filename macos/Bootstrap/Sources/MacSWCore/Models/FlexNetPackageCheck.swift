import Foundation

/// 选中的 FlexNet 目录是否满足托管安装的结构要求。
public enum FlexNetPackageCheck: Equatable {
    case empty
    case checking
    case ready(ManagedFlexNetInstallation)
    case rejected(String)
    /// 压缩包要等安装时解包后才能校验。
    case archiveNotChecked
}
