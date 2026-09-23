import Foundation

public enum SolidWorksProduct: String, CaseIterable, Sendable {
    case solidWorks = "SolidWorks"
    case cosmosWorks = "COSMOSWorks"
    case cosmosMotion = "COSMOSMotion"
    case cosmosFloWorks = "COSMOSFloWorks"
    case composer = "Composer"
    case composerPlayer = "ComposerPlayer"
    case inspection = "Inspection"
    case mbd = "MBD"
    case plastics = "Plastics"
    case electrical2D = "Electrical 2D"
    case electrical3D = "Electrical 3D"
    case pcb = "PCB"
    case visualize = "Visualize"
    case visualizeBoost = "Visualize Boost"
    case cam = "CAM"
    case solidNetworkLicense = "SolidNetWork License"

    public static var longestNamesFirst: [SolidWorksProduct] {
        allCases.sorted { $0.rawValue.count > $1.rawValue.count }
    }
}

public struct ParsedSerialNumbers: Equatable, Sendable {
    public let values: [SolidWorksProduct: String]

    public init(values: [SolidWorksProduct: String]) {
        self.values = values
    }
}

public enum SerialNumberError: LocalizedError, Equatable {
    case noSerialNumber
    case multipleUnlabelledSerialNumbers
    case conflictingSerialNumbers(SolidWorksProduct)

    public var errorDescription: String? {
        switch self {
        case .noSerialNumber: return "没有找到符合六组四字符格式的序列号。"
        case .multipleUnlabelledSerialNumbers: return "发现多个无产品标题的序列号，无法判断对应产品。"
        case .conflictingSerialNumbers(let product): return "\(product.rawValue) 出现了多个不同的序列号。"
        }
    }
}
