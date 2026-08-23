import Foundation

nonisolated struct SettingsBackupDocument: Codable {
    var version: Int
    var exportedAt: Date
    var preferences: UserPreferences
    var perBookSpeeds: [String: Double]
}

enum SettingsBackupError: LocalizedError {
    case unreadable
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unreadable: return "That file isn't an Enve settings backup."
        case .unsupportedVersion(let version): return "This backup was made by a newer Enve (format \(version))."
        }
    }
}

@MainActor
final class SettingsBackupService {
    static let shared = SettingsBackupService()
    private static let formatVersion = 1

    private init() {}

    func exportBackup() throws -> URL {
        let document = SettingsBackupDocument(
            version: Self.formatVersion,
            exportedAt: Date(),
            preferences: LibraryDisplayPreferencesStore.shared.loadPreferences(),
            perBookSpeeds: PlaybackSpeedMemory.shared.allSpeeds()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Enve Settings.json")
        try encoder.encode(document).write(to: url, options: .atomic)
        return url
    }

    func importBackup(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(SettingsBackupDocument.self, from: data) else {
            throw SettingsBackupError.unreadable
        }
        guard document.version <= Self.formatVersion else {
            throw SettingsBackupError.unsupportedVersion(document.version)
        }

        var preferences = document.preferences

        for key in preferences.podcastAutoQueueSettings.keys {
            preferences.podcastAutoQueueSettings[key]?.baselinePublishedAt = nil
        }
        LibraryDisplayPreferencesStore.shared.savePreferences(preferences)
        Theme.currentPreferences = preferences
        PlaybackSpeedMemory.shared.restore(document.perBookSpeeds)
    }
}
