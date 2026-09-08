import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum IntelligenceAvailabilityState: String, CaseIterable, Sendable {
    case checking
    case available
    case appleIntelligenceNotEnabled
    case deviceNotEligible
    case modelNotReady
    case systemTooOld
    case unknown

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    init(_ availability: SystemLanguageModel.Availability) {
        switch availability {
        case .available:
            self = .available
        case .unavailable(.appleIntelligenceNotEnabled):
            self = .appleIntelligenceNotEnabled
        case .unavailable(.deviceNotEligible):
            self = .deviceNotEligible
        case .unavailable(.modelNotReady):
            self = .modelNotReady
        @unknown default:
            self = .unknown
        }
    }
    #endif

    var isReady: Bool { self == .available }

    var title: String {
        switch self {
        case .checking: "正在检查 Apple Intelligence…"
        case .available: "Apple Intelligence 已就绪"
        case .appleIntelligenceNotEnabled: "Apple Intelligence 未开启"
        case .deviceNotEligible: "这台 Mac 不支持"
        case .modelNotReady: "端侧模型尚未就绪"
        case .systemTooOld: "智能内容需要 macOS 26"
        case .unknown: "Apple Intelligence 不可用"
        }
    }

    var detail: String {
        switch self {
        case .checking:
            "FileMorrow 正在检查本机的 Foundation Model。"
        case .available:
            "智能内容可以使用本机 Foundation Model。文件证据只会留在这台 Mac 上。"
        case .appleIntelligenceNotEnabled:
            "请在系统设置中打开 Apple Intelligence，或继续使用更稳妥的格式模式。"
        case .deviceNotEligible:
            "智能内容需要 macOS 26 以及支持 Apple Intelligence 的 Mac。格式模式仍然完全可用。"
        case .modelNotReady:
            "模型可能仍在下载，或暂时不可用。格式模式仍然完全可用。"
        case .systemTooOld:
            "这台 Mac 的系统版本较旧，没有端侧模型。格式模式会按文件类型整理，不需要模型。"
        case .unknown:
            "FileMorrow 无法确认模型是否可用。格式模式仍然完全可用。"
        }
    }
}
