import Foundation

struct AmbientAudioPreset: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let fileName: String
    let fileExtension: String = "mp3"

    var url: URL? {
        Bundle.main.url(forResource: fileName, withExtension: fileExtension, subdirectory: "AmbientAudio")
            ?? Bundle.main.url(forResource: fileName, withExtension: fileExtension, subdirectory: "Resources/AmbientAudio")
            ?? Bundle.main.url(forResource: fileName, withExtension: fileExtension)
    }
}

enum AmbientAudioPresets {
    static let all: [AmbientAudioPreset] = [
        AmbientAudioPreset(
            id: "rainfall",
            title: "Rainfall",
            subtitle: "Steady rain bed for focus listening.",
            systemImage: "cloud.rain.fill",
            fileName: "ambient-rainfall"
        ),
        AmbientAudioPreset(
            id: "fireplace",
            title: "Fireplace",
            subtitle: "Soft fire bed with small crackles.",
            systemImage: "flame.fill",
            fileName: "ambient-fireplace"
        ),
        AmbientAudioPreset(
            id: "rainforest",
            title: "Rainforest",
            subtitle: "Light canopy, insects, and distant birds.",
            systemImage: "leaf.fill",
            fileName: "ambient-rainforest"
        ),
        AmbientAudioPreset(
            id: "ocean-waves",
            title: "Ocean Waves",
            subtitle: "Slow surf and low wave movement.",
            systemImage: "water.waves",
            fileName: "ambient-ocean-waves"
        ),
    ]

    static func preset(id: String) -> AmbientAudioPreset? {
        all.first { $0.id == id }
    }
}
