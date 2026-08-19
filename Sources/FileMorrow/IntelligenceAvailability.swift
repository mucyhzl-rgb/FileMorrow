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
        case .checking: "Checking Apple Intelligence…"
        case .available: "Apple Intelligence ready"
        case .appleIntelligenceNotEnabled: "Apple Intelligence is off"
        case .deviceNotEligible: "This Mac is not eligible"
        case .modelNotReady: "The on-device model is not ready"
        case .systemTooOld: "Smart Content needs macOS 26"
        case .unknown: "Apple Intelligence is unavailable"
        }
    }

    var detail: String {
        switch self {
        case .checking:
            "FileMorrow is checking the on-device Foundation Model."
        case .available:
            "Smart Content can use the on-device Foundation Model. File evidence stays on this Mac."
        case .appleIntelligenceNotEnabled:
            "Turn on Apple Intelligence in System Settings, or keep using reliable Format mode."
        case .deviceNotEligible:
            "Smart Content requires macOS 26 and an Apple Intelligence-eligible Mac. Format mode remains fully available."
        case .modelNotReady:
            "The model may still be downloading or temporarily unavailable. Format mode remains fully available."
        case .systemTooOld:
            "This Mac runs an earlier macOS, so the on-device model is not present. Format mode organizes everything by file type and needs no model."
        case .unknown:
            "FileMorrow could not confirm model availability. Format mode remains fully available."
        }
    }
}
