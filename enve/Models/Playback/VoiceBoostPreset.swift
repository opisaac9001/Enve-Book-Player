import AVFoundation
import Foundation

public enum BasicVoiceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case enhanced
    case strong

    public var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .enhanced: return "Enhanced Speech"
        case .strong: return "Strong Voice Focus"
        }
    }

    var description: String {
        switch self {
        case .off:
            return "Standard playback"
        case .enhanced:
            return "Balanced clarity for audiobooks (Recommended)"
        case .strong:
            return "Maximum voice focus for noisy environments"
        }
    }

    var iconName: String {
        switch self {
        case .off: return "speaker.wave.2"
        case .enhanced: return "waveform"
        case .strong: return "waveform.badge.plus"
        }
    }

    #if canImport(AVFAudio) && os(iOS)
    var audioSessionMode: AVAudioSession.Mode {
        switch self {
        case .off: return .default
        case .enhanced: return .spokenAudio
        case .strong: return .voicePrompt
        }
    }
    #endif

    var isActive: Bool {
        self != .off
    }
}

struct EQBandConfig: Codable, Equatable, Sendable {
    let frequency: Float
    let gain: Float
    let bandwidth: Float
    let filterType: FilterType

    enum FilterType: String, Codable, Sendable {
        case parametric
        case lowShelf
        case highShelf
        case lowPass
        case highPass
    }
}

public enum VoiceBoostPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case neutral
    case bright
    case warm
    case voiceBoost

    public var id: String { rawValue }

    var displayName: String {
        switch self {
        case .neutral:
            return "Neutral"
        case .bright:
            return "Bright"
        case .warm:
            return "Warm"
        case .voiceBoost:
            return "Voice Boost"
        }
    }

    var description: String {
        switch self {
        case .neutral:
            return "Original audio, no enhancement"
        case .bright:
            return "Crisp and clear, great for quiet environments"
        case .warm:
            return "Rich and full, easier on the ears"
        case .voiceBoost:
            return "Maximum clarity, ideal for noisy environments"
        }
    }

    var iconName: String {
        switch self {
        case .neutral:
            return "waveform"
        case .bright:
            return "sun.max"
        case .warm:
            return "flame"
        case .voiceBoost:
            return "arrow.up.circle"
        }
    }

    var eqBands: [EQBandConfig] {
        switch self {
        case .neutral:
            return []

        case .warm:
            return [
                EQBandConfig(frequency: 80, gain: 2.0, bandwidth: 1.4, filterType: .lowShelf),
                EQBandConfig(frequency: 150, gain: 3.0, bandwidth: 1.0, filterType: .parametric),
                EQBandConfig(frequency: 500, gain: 1.0, bandwidth: 0.83, filterType: .parametric),
                EQBandConfig(frequency: 2500, gain: -1.0, bandwidth: 0.67, filterType: .parametric),
                EQBandConfig(frequency: 8000, gain: 1.5, bandwidth: 1.0, filterType: .highShelf),
            ]

        case .bright:
            return [
                EQBandConfig(frequency: 200, gain: -1.5, bandwidth: 1.0, filterType: .parametric),
                EQBandConfig(frequency: 3000, gain: 3.0, bandwidth: 0.83, filterType: .parametric),
                EQBandConfig(frequency: 6000, gain: 4.0, bandwidth: 1.0, filterType: .parametric),
                EQBandConfig(frequency: 12000, gain: 3.0, bandwidth: 1.0, filterType: .highShelf),
            ]

        case .voiceBoost:
            return [
                EQBandConfig(frequency: 100, gain: -6.0, bandwidth: 1.4, filterType: .lowShelf),
                EQBandConfig(frequency: 350, gain: -4.0, bandwidth: 0.83, filterType: .parametric),
                EQBandConfig(frequency: 1000, gain: 8.0, bandwidth: 0.67, filterType: .parametric),
                EQBandConfig(frequency: 3000, gain: 8.0, bandwidth: 0.83, filterType: .parametric),
                EQBandConfig(frequency: 5000, gain: 6.0, bandwidth: 1.0, filterType: .parametric),
                EQBandConfig(frequency: 10000, gain: 4.0, bandwidth: 1.0, filterType: .highShelf),
            ]
        }
    }

    var numberOfBands: Int {
        max(eqBands.count, 1)
    }

}
