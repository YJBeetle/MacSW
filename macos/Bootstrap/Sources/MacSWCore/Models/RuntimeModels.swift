import Foundation

public enum SolidWorksRuntimeState: Equatable, Sendable {
    case unavailable
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
