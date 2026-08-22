import Foundation

enum VolumeLevelingStrength: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case low
    case medium
    case high

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .off: "Off"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    nonisolated var parameters: VolumeLevelingParameters? {
        switch self {
        case .off:
            nil
        case .low:
            VolumeLevelingParameters(thresholdDB: -18, ratio: 2, attack: 0.001, release: 0.2, makeupGainDB: 4)
        case .medium:
            VolumeLevelingParameters(thresholdDB: -24, ratio: 3, attack: 0.001, release: 0.2, makeupGainDB: 7)
        case .high:
            VolumeLevelingParameters(thresholdDB: -30, ratio: 4, attack: 0.001, release: 0.2, makeupGainDB: 10)
        }
    }
}

nonisolated struct VolumeLevelingParameters: Sendable, Equatable {
    let thresholdDB: Float
    let ratio: Float
    let attack: Float
    let release: Float
    let makeupGainDB: Float
}
