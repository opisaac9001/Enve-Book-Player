import Foundation

struct EqualizerBand: Identifiable, Codable, Hashable {
    let id: Int
    let frequency: Int
    var gain: Float
    let label: String
}

struct EqualizerPreset: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    var bands: [EqualizerBand]

    static let flat = EqualizerPreset(
        id: "flat",
        name: "Flat",
        bands: [
            EqualizerBand(id: 0, frequency: 60, gain: 0, label: "60Hz"),
            EqualizerBand(id: 1, frequency: 250, gain: 0, label: "250Hz"),
            EqualizerBand(id: 2, frequency: 1000, gain: 0, label: "1kHz"),
            EqualizerBand(id: 3, frequency: 4000, gain: 0, label: "4kHz"),
            EqualizerBand(id: 4, frequency: 16000, gain: 0, label: "16kHz"),
        ]
    )

    static let voiceBoost = EqualizerPreset(
        id: "voice_boost",
        name: "Voice Boost",
        bands: [
            EqualizerBand(id: 0, frequency: 60, gain: -3, label: "60Hz"),
            EqualizerBand(id: 1, frequency: 250, gain: 1, label: "250Hz"),
            EqualizerBand(id: 2, frequency: 1000, gain: 4, label: "1kHz"),
            EqualizerBand(id: 3, frequency: 4000, gain: 6, label: "4kHz"),
            EqualizerBand(id: 4, frequency: 16000, gain: 2, label: "16kHz"),
        ]
    )

    static let bassBoost = EqualizerPreset(
        id: "bass_boost",
        name: "Bass Boost",
        bands: [
            EqualizerBand(id: 0, frequency: 60, gain: 6, label: "60Hz"),
            EqualizerBand(id: 1, frequency: 250, gain: 3, label: "250Hz"),
            EqualizerBand(id: 2, frequency: 1000, gain: 0, label: "1kHz"),
            EqualizerBand(id: 3, frequency: 4000, gain: 0, label: "4kHz"),
            EqualizerBand(id: 4, frequency: 16000, gain: 0, label: "16kHz"),
        ]
    )

    static let trebleBoost = EqualizerPreset(
        id: "treble_boost",
        name: "Treble Boost",
        bands: [
            EqualizerBand(id: 0, frequency: 60, gain: 0, label: "60Hz"),
            EqualizerBand(id: 1, frequency: 250, gain: 0, label: "250Hz"),
            EqualizerBand(id: 2, frequency: 1000, gain: 1, label: "1kHz"),
            EqualizerBand(id: 3, frequency: 4000, gain: 4, label: "4kHz"),
            EqualizerBand(id: 4, frequency: 16000, gain: 8, label: "16kHz"),
        ]
    )

    static var allPresets: [EqualizerPreset] {
        [.flat, .voiceBoost, .bassBoost, .trebleBoost]
    }
}

enum VoiceBoostMode: String, Codable, CaseIterable {
    case off
    case low
    case medium
    case high

    var gainMultiplier: Float {
        switch self {
        case .off: return 1.0
        case .low: return 1.1
        case .medium: return 1.25
        case .high: return 1.41
        }
    }

    var label: String {
        self.rawValue.capitalized
    }
}
