import Foundation
import Network

@MainActor
@Observable
final class HardcoverSyncService {
    static let shared = HardcoverSyncService()

    private(set) var lastError: String?

    private let serialQueue = PerBookSerialQueue()
    private var syncedBookStarts: Set<String> = []
    private var syncedBookCompletions: Set<String> = []

    private let store: HardcoverPendingStore
    private var worker: Task<Void, Never>?
    private var inFlight: UUID?
    private var waitingForRetry = false
    private let monitor = NWPathMonitor()

    private init() {
        store = HardcoverPendingStore(url: ProfileStorageLocations.owner.applicationSupportDirectory
            .appendingPathComponent("Enve/Hardcover/pending.json"))
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied {
                Task { @MainActor in self?.resume() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.enve.hardcover.connectivity"))
    }

    static var hasProfileAccess: Bool {
        let profiles = ProfileSwitchCoordinator.shared
        return profiles.activeSession.isOwner && !profiles.isLocked && !profiles.activeSession.isRetired
    }

    private var account: String? {
        SettingsManager.shared.hardcoverApiKey.map(HardcoverRequestPacer.accountKey)
    }

    var pendingCount: Int { store.updates.filter { $0.account == account }.count }
    var failedCount: Int { store.updates.filter { $0.account == account && $0.failure != nil }.count }

    func resume() {
        guard Self.hasProfileAccess, SettingsManager.shared.hardcoverAutoSyncEnabled, account != nil else {
            worker?.cancel()
            return
        }
        if let error = store.loadError { lastError = error; return }
        if waitingForRetry { worker?.cancel() }
        guard worker == nil else { return }
        worker = Task { await self.drain() }
    }

    func configurationChanged() {
        worker?.cancel()
        if worker == nil { resume() }
    }

    func retryPending() {
        guard let account else { return }
        do { try store.retry(account: account); lastError = nil; configurationChanged() }
        catch { lastError = error.localizedDescription }
    }

    func discardPending() {
        guard let account else { return }
        worker?.cancel()
        do { try store.discard(account: account) }
        catch { lastError = "Hardcover updates could not be removed: \(error.localizedDescription)" }
    }

    @discardableResult
    func syncBookStarted(book: Book) async -> Bool {
        let duration = book.duration ?? 0
        let progress = book.mediaType == .ebook ? book.canonicalEbookProgress : (duration > 0 ? book.currentTime / duration : 0)
        guard progress < Book.finishedProgressThreshold else { return false }
        return enqueue(book: book, progress: nil, finished: false)
    }

    @discardableResult
    func syncProgress(book: Book, progress: Double) async -> Bool {
        guard progress.isFinite, progress > 0, progress <= 1 else { return false }
        return enqueue(book: book, progress: progress, finished: progress >= Book.finishedProgressThreshold)
    }

    @discardableResult
    func syncBookFinished(book: Book) async -> Bool { enqueue(book: book, progress: 1, finished: true) }

    private func enqueue(book: Book, progress: Double?, finished: Bool) -> Bool {
        guard Self.hasProfileAccess, SettingsManager.shared.hardcoverAutoSyncEnabled, let account else { return false }
        let date = HardcoverDateFormatter.todayString()
        let update = HardcoverPendingUpdate(id: UUID(), account: account, book: HardcoverBookSnapshot(book: book),
            progress: progress, finished: finished, occurredAt: Date(), startDate: date, eventDate: date,
            match: SettingsManager.shared.getHardcoverMatch(for: book))
        do {
            try store.enqueue(update, inFlight: inFlight)
            resume()
            return true
        } catch {
            lastError = "Hardcover progress could not be saved for sync: \(error.localizedDescription)"
            return false
        }
    }

    private func drain() async {
        defer {
            inFlight = nil
            worker = nil
            if Task.isCancelled { resume() }
        }
        while !Task.isCancelled, Self.hasProfileAccess, SettingsManager.shared.hardcoverAutoSyncEnabled,
              let token = SettingsManager.shared.hardcoverApiKey, let account {
            let heads = store.heads(account: account).filter { $0.failure == nil }
            guard var update = heads.min(by: { $0.nextAttempt < $1.nextAttempt }) else { return }
            let delay = update.nextAttempt.timeIntervalSinceNow
            if delay > 0 {
                waitingForRetry = true
                do { try await Task.sleep(for: .seconds(delay)) } catch { waitingForRetry = false; return }
                waitingForRetry = false
                continue
            }
            inFlight = update.id
            do {
                try await HardcoverService.$syncToken.withValue(token) {
                    let match = SettingsManager.shared.getHardcoverMatch(forLocalBookId: update.book.stableId)
                        ?? update.match
                    if let match { update.match = match }
                    else { update.match = try await resolveMatch(for: update.book) }
                    try Task.checkCancellation()
                    guard let match = update.match else { throw HardcoverError.noMatchFound }
                    try store.replace(update)
                    let pending = update
                    var failure: Error?
                    await serialQueue.enqueue(bookId: "hardcover:\(match.hardcoverBookId)") {
                        do { try await self.push(update: pending, match: match) }
                        catch { failure = error }
                    }
                    if let failure { throw failure }
                }
                try Task.checkCancellation()
                try store.remove(id: update.id)
                lastError = nil
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                update.attempts += 1
                lastError = error.localizedDescription
                if Self.isTransient(error) {
                    let backoff = Date().addingTimeInterval(min(900, pow(2, Double(min(update.attempts, 8))) * 5))
                    if case HardcoverError.rateLimited(let until) = error { update.nextAttempt = max(backoff, until) }
                    else { update.nextAttempt = backoff }
                } else { update.failure = error.localizedDescription }
                do { try store.replace(update) }
                catch { lastError = "Hardcover queue could not be saved: \(error.localizedDescription)"; return }
            }
            inFlight = nil
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                    .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable].contains(urlError.code)
        }
        switch error {
        case HardcoverError.rateLimited: return true
        case HardcoverError.networkError: return true
        case HardcoverError.httpError(let code, _): return code == 408 || code == 429 || (500...599).contains(code)
        default: return false
        }
    }

    private func push(update: HardcoverPendingUpdate, match: HardcoverBookMatch) async throws {
        let book = update.book
        let progress = update.progress
        let finished = update.finished
        let service = HardcoverService.shared
        let settings = SettingsManager.shared
        var entry = try await service.getUserBook(bookId: match.hardcoverBookId)
        if entry == nil {
            _ = try await service.addBookToLibrary(bookId: match.hardcoverBookId, startReading: !finished, eventDate: finished ? update.eventDate : update.startDate)
            entry = try await service.getUserBook(bookId: match.hardcoverBookId)
        }
        guard let userBook = entry else { throw HardcoverError.invalidResponse }
        if finished, userBook.statusId == HardcoverReadingStatus.finished.rawValue,
            userBook.currentRead?.finishedAt != nil {
            syncedBookCompletions.insert(book.stableId)
            return
        }
        if !finished, userBook.statusId != HardcoverReadingStatus.currentlyReading.rawValue {
            try await service.markBookAsStarted(userBookId: userBook.id, eventDate: update.startDate)
            syncedBookCompletions.remove(book.stableId)
        }

        let edition = try await resolveEdition(for: book, match: match, userBook: userBook)
        // Changing status can create a read on the server; fetch it before inserting one.
        let latest = try await service.latestRead(userBookId: userBook.id)
        let readId = latest.flatMap { $0.isFinished ? nil : $0.id }
        if finished, latest?.isFinished == true {
            try await service.markBookAsFinished(userBookId: userBook.id, eventDate: update.eventDate)
            syncedBookCompletions.insert(book.stableId)
            return
        }
        if let progress {
            let fraction = finished ? 1 : progress
            let seconds = edition?.audioSeconds.flatMap { $0 > 0 ? Int((Double($0) * fraction).rounded()) : nil }
            let pages = edition?.pages.flatMap { $0 > 0 ? Int((Double($0) * fraction).rounded()) : nil }
            guard finished || seconds != nil || pages != nil else { throw HardcoverSyncError.missingEdition }
            _ = try await service.upsertReadingProgress(
                userBookId: userBook.id,
                existingReadId: readId,
                progressPages: pages ?? 0,
                progressSeconds: seconds,
                isFinished: finished,
                editionId: edition?.id, eventDate: update.eventDate, startDate: update.startDate, actionAt: update.occurredAt
            )
        } else if readId == nil {
            _ = try await service.createReadingSession(userBookId: userBook.id, editionId: edition?.id, eventDate: update.startDate)
        }
        if finished {
            try await service.markBookAsFinished(userBookId: userBook.id, eventDate: update.eventDate)
            syncedBookCompletions.insert(book.stableId)
        } else {
            syncedBookStarts.insert(book.stableId)
        }
        settings.addHardcoverMatch(HardcoverBookMatch(
            id: match.id,
            localBookId: book.stableId,
            hardcoverBookId: match.hardcoverBookId,
            hardcoverUserBookId: userBook.id,
            hardcoverEditionId: edition?.id,
            editionPageCount: edition?.pages,
            matchedAt: match.matchedAt,
            matchType: match.matchType,
            localBookTitle: book.title,
            hardcoverBookTitle: match.hardcoverBookTitle
        ))
    }

    func resolveMatch(for book: Book) async throws -> HardcoverBookMatch {
        if let match = SettingsManager.shared.getHardcoverMatch(for: book) { return match }
        return try await resolveMatch(for: HardcoverBookSnapshot(book: book))
    }

    private func resolveMatch(for book: HardcoverBookSnapshot) async throws -> HardcoverBookMatch {
        let identifiers = HardcoverIdentifiers(isbn: book.isbn, asin: book.asin)
        if let edition = try await HardcoverService.shared.findEdition(identifiers: identifiers) {
            return HardcoverBookMatch(localBookId: book.stableId, hardcoverBookId: edition.bookId,
                hardcoverEditionId: edition.id, editionPageCount: edition.pages, matchType: .automatic,
                localBookTitle: book.title, hardcoverBookTitle: edition.book.title)
        }
        let results = try await HardcoverService.shared.searchBooks(query: book.title, limit: 10)
        guard let matched = Self.bestMatch(title: book.title, author: book.author, results: results) else {
            throw HardcoverSyncError.bookNotFound(title: book.title)
        }
        return HardcoverBookMatch(
            localBookId: book.stableId,
            hardcoverBookId: matched.id,
            matchType: .automatic,
            localBookTitle: book.title,
            hardcoverBookTitle: matched.title
        )
    }

    private func resolveEdition(for book: HardcoverBookSnapshot, match: HardcoverBookMatch, userBook: HardcoverUserBook) async throws -> HardcoverEdition? {
        if let edition = userBook.currentRead?.edition ?? userBook.edition,
            match.hardcoverEditionId == nil || match.hardcoverEditionId == edition.id {
            if (edition.pages ?? 0) > 0 || (edition.audioSeconds ?? 0) > 0 { return edition }
        }
        let editions = try await HardcoverService.shared.getEditionsForBook(bookId: match.hardcoverBookId)
        if let selectedId = match.hardcoverEditionId {
            guard let selected = editions.first(where: { $0.id == selectedId }) else { throw HardcoverSyncError.missingEdition }
            return selected
        }
        let usable = editions.filter { ($0.pages ?? 0) > 0 || ($0.audioSeconds ?? 0) > 0 }
        return usable.first(where: { $0.isAudiobook == !book.isEbook }) ?? usable.first
    }

    nonisolated static func bestMatch(title: String, author: String?, results: [HardcoverBook]) -> HardcoverBook? {
        guard let author, !normalize(author).isEmpty, !normalize(title).isEmpty else { return nil }
        let matches = results.filter {
            $0.id > 0 && normalize($0.title) == normalize(title)
                && normalize($0.cachedContributors?.value ?? "") == normalize(author)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    nonisolated private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    func clearSyncTracking() {
        lastError = nil
        syncedBookStarts.removeAll()
        syncedBookCompletions.removeAll()
    }

    func getSyncStats() -> (started: Int, completed: Int) {
        (syncedBookStarts.count, syncedBookCompletions.count)
    }
}

enum HardcoverSyncError: LocalizedError {
    case bookNotFound(title: String)
    case missingEdition
    case conflictingIdentifiers

    var errorDescription: String? {
        switch self {
        case .bookNotFound(let title): "Match '\(title)' to your Hardcover shelf before syncing."
        case .conflictingIdentifiers: "The identifiers match different Hardcover editions. Choose an edition manually."
        case .missingEdition: "Choose a Hardcover edition with a page count or audio duration."
        }
    }
}
