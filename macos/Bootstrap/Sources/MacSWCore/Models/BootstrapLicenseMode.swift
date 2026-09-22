import Foundation

/// 安装界面的许可单选：一次安装只启用一种许可来源，避免"填了却不生效"的假状态。
public enum BootstrapLicenseMode: String, CaseIterable, Identifiable, Sendable {
    case unconfigured
    case remoteServer
    case managedFlexNet

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .unconfigured: return "不配置"
        case .remoteServer: return "使用指定地址"
        case .managedFlexNet: return "托管 FlexNet 服务器"
        }
    }

    public var detail: String {
        switch self {
        case .unconfigured: return "不写入许可服务器地址；SOLIDWORKS 启动时会询问激活方式。"
        case .remoteServer: return "把地址写入容器注册表，许可服务由别的机器运行。"
        case .managedFlexNet: return "把 FlexNet 装进容器 \(AppPaths.managedFlexNetWindowsPath) 并启动，停止与卸载由 MacSW 接管。"
        }
    }

    /// 选定模式后该模式的输入不能再留空或无效，否则许可步骤会静默跳过。
    public func missingInputMessage(address: String, flexNetSource: URL?) -> String? {
        switch self {
        case .unconfigured:
            return nil
        case .remoteServer:
            let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "已选择使用指定地址，请填写许可服务器地址。" }
            guard (try? LicenseServerAddressService.parse(trimmed)) != nil else {
                return "许可服务器地址格式应为“端口@主机”，多个地址用分号分隔。"
            }
            return nil
        case .managedFlexNet:
            return flexNetSource == nil ? "已选择托管 FlexNet，请选择随附的 FlexNet 服务器目录。" : nil
        }
    }
}
