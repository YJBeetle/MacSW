import Combine
import Foundation

@MainActor
public final class SolidWorksResourceMonitorStore: ObservableObject {
    @Published public private(set) var state: SolidWorksResourceMonitorState = .unavailable
    @Published public private(set) var statusMessage = ""

    private let paths: AppPaths
    private let service: SolidWorksResourceMonitorService

    public init(
        paths: AppPaths,
        service: SolidWorksResourceMonitorService = SolidWorksResourceMonitorService()
    ) {
        self.paths = paths
        self.service = service
        refresh()
    }

    public var isDisabled: Bool { state == .disabled }
    public var canChange: Bool { state == .enabled || state == .disabled }

    public func refresh() {
        state = service.state(paths: paths)
        switch state {
        case .enabled, .disabled:
            statusMessage = ""
        case .unavailable:
            statusMessage = "未找到 \(SolidWorksResourceMonitorService.executableName)。"
        }
    }

    public func setDisabled(_ disabled: Bool) {
        do {
            try service.setDisabled(disabled, paths: paths)
            refresh()
            statusMessage = disabled
                ? "已禁用；下次启动 SOLIDWORKS 生效。"
                : "已恢复；下次启动 SOLIDWORKS 会再次加载资源监视器。"
        } catch {
            refresh()
            statusMessage = error.localizedDescription
        }
    }
}
