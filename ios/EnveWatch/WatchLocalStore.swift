import Foundation
import Observation

struct WatchLocalBook: Codable, Identifiable, Sendable {
    var descriptor: WatchPlaybackDescriptor
    var completedTracks: [Int: String]
    var savedPosition: TimeInterval
    var savedAt: Date

    var id: String { descriptor.stableId }
    var isComplete: Bool { completedTracks.count == descriptor.tracks.count }
}

@MainActor
@Observable
final class WatchLocalStore {
    static let shared = WatchLocalStore()

    private(set) var books: [WatchLocalBook] = []

    private let root = URL.documentsDirectory.appendingPathComponent("Audiobooks", isDirectory: true)

    private init() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    func directory(for stableId: String) -> URL {
        root.appendingPathComponent(WatchCoverStore.sanitized(stableId), isDirectory: true)
    }

    func trackFileURL(stableId: String, fileName: String) -> URL {
        directory(for: stableId).appendingPathComponent(fileName)
    }

    func book(stableId: String) -> WatchLocalBook? {
        books.first { $0.descriptor.stableId == stableId }
    }

    func upsert(_ book: WatchLocalBook) {
        let directory = directory(for: book.descriptor.stableId)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(book) {
            try? data.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        }
        if let index = books.firstIndex(where: { $0.id == book.id }) {
            books[index] = book
        } else {
            books.append(book)
        }
    }

    func savePosition(stableId: String, position: TimeInterval) {
        guard var book = book(stableId: stableId) else { return }
        book.savedPosition = position
        book.savedAt = Date()
        upsert(book)
    }

    func markTrackComplete(stableId: String, trackIndex: Int, fileName: String) {
        guard var book = book(stableId: stableId) else { return }
        book.completedTracks[trackIndex] = fileName
        upsert(book)
    }

    func delete(stableId: String) {
        if WatchPlayerModel.shared.isCurrent(stableId) {
            WatchPlayerModel.shared.stopCurrent()
        }
        try? FileManager.default.removeItem(at: directory(for: stableId))
        books.removeAll { $0.descriptor.stableId == stableId }
        WatchCoverStore.shared.removeCover(for: stableId)
    }

    func sizeBytes(stableId: String) -> Int64 {
        let directory = directory(for: stableId)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        return files.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    func totalSizeBytes() -> Int64 {
        books.reduce(0) { $0 + sizeBytes(stableId: $1.descriptor.stableId) }
    }

    private func reload() {
        guard let directories = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        books = directories.compactMap { directory in
            if let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
                let book = try? JSONDecoder().decode(WatchLocalBook.self, from: data)
            {
                return book
            }

            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }
}
