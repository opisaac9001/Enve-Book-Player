import Foundation

@MainActor
final class AudiobookClipStore {
    static let shared = AudiobookClipStore()

    private static let keyPrefix = "audiobookClips_"
    private let userDefaults = UserDefaults.standard

    private init() {}

    func loadClips(bookId: String) -> [AudiobookClip] {
        guard let data = userDefaults.data(forKey: Self.keyPrefix + bookId),
            let clips = try? JSONDecoder().decode([AudiobookClip].self, from: data)
        else {
            return []
        }
        return clips.sorted { $0.startTime < $1.startTime }
    }

    func clip(bookId: String, clipId: String) -> AudiobookClip? {
        loadClips(bookId: bookId).first { $0.id == clipId }
    }

    func upsertClip(_ clip: AudiobookClip) {
        var clips = loadClips(bookId: clip.bookId)
        if let index = clips.firstIndex(where: { $0.id == clip.id }) {
            clips[index] = clip
        } else {
            clips.append(clip)
        }
        save(clips, bookId: clip.bookId)
    }

    func deleteClip(bookId: String, clipId: String) {
        var clips = loadClips(bookId: bookId)
        clips.removeAll { $0.id == clipId }
        save(clips, bookId: bookId)
    }

    private func save(_ clips: [AudiobookClip], bookId: String) {
        guard let data = try? JSONEncoder().encode(clips.sorted { $0.startTime < $1.startTime }) else { return }
        userDefaults.set(data, forKey: Self.keyPrefix + bookId)
    }
}
