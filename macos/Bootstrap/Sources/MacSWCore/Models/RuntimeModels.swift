import Foundation

public enum SolidWorksRuntimeState: Equatable, Sendable {
    case unavailable
    /// 尚未探测过进程状态；只有用户主动查看或需要启动时才探测。
    case unknown
    case stopped
    case starting
    case running
    case stopping
    case failed(String)
}

public enum FlexNetRuntimeState: Equatable, Sendable {
    case notInstalled
    case stopped
    case starting
    case running(UInt16)
    case stopping
    case failed(String)
}
