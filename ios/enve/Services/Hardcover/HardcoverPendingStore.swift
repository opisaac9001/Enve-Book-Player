import Foundation

nonisolated struct HardcoverBookSnapshot: Codable, Sendable {
    let stableId: String
    let title: String
    let author: String?
    let isbn: String?
    let asin: String?
    let isEbook: Bool

    init(book: Book) {
        stableId = book.stableId
        title = book.title
        author = book.author
        isbn = book.isbn
        asin = book.asin
        isEbook = book.mediaType == .ebook
    }
}

struct HardcoverPendingUpdate: Codable, Identifiable {
    let id: UUID
    let account: String
    let book: HardcoverBookSnapshot
    let progress: Double?
    let finished: Bool
    let occurredAt: Date
    let startDate: String
    let eventDate: String
    var match: HardcoverBookMatch?
    var attempts = 0
    var nextAttempt = Date.distantPast
    var failure: String?
}

@MainActor
@Observable
final class HardcoverPendingStore {
    private(set) var updates: [HardcoverPendingUpdate] = []
    private(set) var loadError: String?
    private let url: URL

    init(url: URL) {
        self.url = url
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                updates = try JSONDecoder().decode([HardcoverPendingUpdate].self, from: Data(contentsOf: url))
            }
        } catch { loadError = "Saved Hardcover updates could not be opened. Your queue has been kept." }
    }

    func enqueue(_ update: HardcoverPendingUpdate, inFlight: UUID?) throws {
        var next = updates
        if let index = next.lastIndex(where: { $0.account == update.account && $0.book.stableId == update.book.stableId }),
            next[index].id != inFlight, next[index].finished == update.finished {
            let old = next[index]
            next[index] = HardcoverPendingUpdate(id: update.id, account: update.account, book: update.book,
                progress: update.progress ?? old.progress, finished: update.finished,
                occurredAt: update.finished ? old.occurredAt : update.occurredAt,
                startDate: old.startDate, eventDate: update.finished ? old.eventDate : update.eventDate,
                match: update.match ?? old.match, attempts: old.attempts, nextAttempt: old.nextAttempt, failure: old.failure)
        } else { next.append(update) }
        try persist(next)
    }

    func replace(_ update: HardcoverPendingUpdate) throws {
        guard let index = updates.firstIndex(where: { $0.id == update.id }) else { return }
        var next = updates
        next[index] = update
        try persist(next)
    }

    func remove(id: UUID) throws { try persist(updates.filter { $0.id != id }) }

    func discard(account: String) throws { try persist(updates.filter { $0.account != account }) }

    func retry(account: String) throws {
        var next = updates
        for index in next.indices where next[index].account == account {
            next[index].failure = nil
            next[index].nextAttempt = .distantPast
            next[index].attempts = 0
        }
        try persist(next)
    }

    func heads(account: String) -> [HardcoverPendingUpdate] {
        var seen = Set<String>()
        return updates.filter { $0.account == account && seen.insert($0.book.stableId).inserted }
    }

    private func persist(_ next: [HardcoverPendingUpdate]) throws {
        guard loadError == nil else { throw HardcoverError.invalidResponse }
        let data = try JSONEncoder().encode(next)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        updates = next
    }
}
