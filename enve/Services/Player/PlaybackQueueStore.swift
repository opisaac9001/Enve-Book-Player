import Foundation
import Logging

enum PlaybackQueueOrigin: String, Codable, Sendable {
    case manual = "MANUAL"
    case playAll = "PLAY_ALL"
    case podcastAuto = "PODCAST_AUTO"
}

struct PlaybackQueueEntry: Identifiable, Codable, Equatable, Sendable {
    let book: Book
    let origin: PlaybackQueueOrigin
    let groupKey: String?
    let enqueuedAt: Date

    var id: String { book.uniqueId }
}

@MainActor
@Observable
final class PlaybackQueueStore {
    static let shared = PlaybackQueueStore()

    private(set) var entries: [PlaybackQueueEntry]

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let fileManager: FileManager

    init(
        fileURL: URL = PlaybackQueueStore.defaultFileURL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.entries = Self.load(from: fileURL)
    }

    func replace(
        with books: [Book],
        origin: PlaybackQueueOrigin,
        groupKey: String? = nil
    ) {
        let now = Date()
        entries = Self.unique(books).enumerated().map { index, book in
            PlaybackQueueEntry(
                book: book,
                origin: origin,
                groupKey: groupKey,
                enqueuedAt: now.addingTimeInterval(Double(index) / 1_000)
            )
        }
        persist()
    }

    func addNext(
        _ book: Book,
        origin: PlaybackQueueOrigin = .manual,
        groupKey: String? = nil
    ) {
        entries.removeAll { $0.id == book.uniqueId }
        entries.insert(entry(for: book, origin: origin, groupKey: groupKey), at: 0)
        persist()
    }

    func addLast(
        _ book: Book,
        origin: PlaybackQueueOrigin = .manual,
        groupKey: String? = nil
    ) {
        entries.removeAll { $0.id == book.uniqueId }
        entries.append(entry(for: book, origin: origin, groupKey: groupKey))
        persist()
    }

    @discardableResult
    func takeNext() -> PlaybackQueueEntry? {
        guard !entries.isEmpty else { return nil }
        let next = entries.removeFirst()
        persist()
        return next
    }

    func remove(bookID: String) {
        let previousCount = entries.count
        entries.removeAll { $0.id == bookID }
        if entries.count != previousCount { persist() }
    }

    func move(bookID: String, by delta: Int) {
        guard let source = entries.firstIndex(where: { $0.id == bookID }) else { return }
        let destination = source + delta
        guard entries.indices.contains(destination) else { return }
        let entry = entries.remove(at: source)
        entries.insert(entry, at: destination)
        persist()
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard !offsets.isEmpty else { return }
        let moving = offsets.sorted().map { entries[$0] }
        let remaining = entries.enumerated()
            .filter { !offsets.contains($0.offset) }
            .map(\.element)
        let adjustedDestination = max(
            0,
            min(destination - offsets.filter { $0 < destination }.count, remaining.count)
        )
        var reordered = remaining
        reordered.insert(contentsOf: moving, at: adjustedDestination)
        entries = reordered
        persist()
    }

    func clear() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        persist()
    }

    private func entry(
        for book: Book,
        origin: PlaybackQueueOrigin,
        groupKey: String?
    ) -> PlaybackQueueEntry {
        PlaybackQueueEntry(book: book, origin: origin, groupKey: groupKey, enqueuedAt: Date())
    }

    private func persist() {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLogger.player.error("Couldn't persist Up Next: \(error.localizedDescription)")
        }
    }

    private static func load(from url: URL) -> [PlaybackQueueEntry] {
        guard let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([PlaybackQueueEntry].self, from: data)
        else {
            return []
        }
        var seen = Set<String>()
        return decoded.filter { seen.insert($0.id).inserted }
    }

    private static func unique(_ books: [Book]) -> [Book] {
        var seen = Set<String>()
        return books.filter { seen.insert($0.uniqueId).inserted }
    }

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Enve", isDirectory: true)
            .appendingPathComponent("playback-queue.json", isDirectory: false)
    }
}
