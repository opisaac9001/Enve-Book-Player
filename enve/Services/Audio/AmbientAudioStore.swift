import Foundation

@MainActor
final class AmbientAudioStore {
    static let shared = AmbientAudioStore()

    private static let keyPrefix = "ambientAudioSelection_"
    private static let volumeKey = "ambientAudioVolume"
    private static let defaultVolume = 0.35
    private let userDefaults = UserDefaults.standard

    private init() {}

    func save(_ selection: AmbientAudioSelection) {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        userDefaults.set(data, forKey: Self.keyPrefix + selection.bookId)
    }

    func loadSelection(bookId: String) -> AmbientAudioSelection? {
        guard let data = userDefaults.data(forKey: Self.keyPrefix + bookId),
            let selection = try? JSONDecoder().decode(AmbientAudioSelection.self, from: data)
        else {
            return nil
        }
        return selection
    }

    func clearSelection(bookId: String) {
        userDefaults.removeObject(forKey: Self.keyPrefix + bookId)
    }

    func loadVolume(fallback: Double? = nil) -> Double {
        if userDefaults.object(forKey: Self.volumeKey) != nil {
            return clamped(userDefaults.double(forKey: Self.volumeKey))
        }
        return clamped(fallback ?? Self.defaultVolume)
    }

    func saveVolume(_ volume: Double) {
        userDefaults.set(clamped(volume), forKey: Self.volumeKey)
    }

    private func clamped(_ volume: Double) -> Double {
        max(0, min(volume, 1))
    }
}
