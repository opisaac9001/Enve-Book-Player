import Foundation

enum ProductionType: String, Codable, Sendable, CaseIterable {
    case standard
    case graphicAudio
    case dramatized
    case multiCast
    case radioDrama
    case audioDrama

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .graphicAudio: return "GraphicAudio"
        case .dramatized: return "Dramatized"
        case .multiCast: return "Full Cast"
        case .radioDrama: return "Radio Adaptation"
        case .audioDrama: return "Audio Drama"
        }
    }
}

enum AbridgedState: String, Codable, Sendable {
    case abridged
    case unabridged
    case unknown
}
