import Foundation
import Logging

actor HardcoverSyncService {
    static let shared = HardcoverSyncService()

    private var syncedBookStarts: Set<String> = []
    private var syncedBookCompletions: Set<String> = []

    private var bookIdCache: [String: Int] = [:]
    private var userBookIdCache: [String: Int] = [:]
    private var readSessionCache: [String: Int] = [:]
    private var pageCountCache: [String: Int] = [:]

    private init() {}

    func syncBookStarted(book: Book) async {
        guard await isEnabled() else { return }

        let bookId = book.stableId
        guard !syncedBookStarts.contains(bookId) else { return }

        let currentProgress: TimeInterval =
            book.mediaType == .ebook
            ? (book.ebookProgress ?? 0)
            : book.currentTime
        guard currentProgress == 0 || currentProgress < 1 else { return }

        let diagnosticID = DiagnosticLogSanitizer.identifier(for: bookId)
        AppLogger.sync.debug("[Hardcover Sync] Book started bookId=\(diagnosticID)")

        do {
            let hardcoverBookId = try await resolveHardcoverBookId(for: book)

            let userBookId = try await ensureInLibrary(
                hardcoverBookId: hardcoverBookId,
                localBookId: bookId,
                asReading: true
            )

            _ = try await ensureReadSession(
                userBookId: userBookId,
                localBookId: bookId,
                book: book
            )

            AppLogger.sync.debug("[Hardcover Sync] Book start synced bookId=\(diagnosticID)")
            syncedBookStarts.insert(bookId)
        } catch {
            AppLogger.sync.error("[Hardcover Sync] Start sync failed bookId=\(diagnosticID): \(error.localizedDescription)")
        }
    }

    func syncProgress(book: Book, progress: Double) async {
        guard await isEnabled() else { return }
        guard progress > 0, progress <= 1 else { return }

        let bookId = book.stableId

        do {
            let userBookId = try await resolveUserBookId(for: book)
            let readId = try await resolveReadSessionId(for: book, userBookId: userBookId)

            guard let pageCount = resolvePageCount(for: bookId), pageCount > 0 else {
                try await fetchAndCachePageCount(for: book, userBookId: userBookId)
                guard let pc = resolvePageCount(for: bookId), pc > 0 else {
                    AppLogger.sync.warning(
                        "[Hardcover Sync] No page count bookId=\(DiagnosticLogSanitizer.identifier(for: bookId)), skipping progress"
                    )
                    return
                }
                let currentPage = max(1, min(pc, Int(Double(pc) * progress)))
                let isFinished = progress >= 0.99
                let edId = await resolveEditionId(for: bookId)
                _ = try await HardcoverService.shared.upsertReadingProgress(
                    userBookId: userBookId,
                    existingReadId: readId > 0 ? readId : nil,
                    progressPages: currentPage,
                    isFinished: isFinished,
                    editionId: edId
                )
                AppLogger.sync.info("[Hardcover Sync] Progress: \(Int(progress * 100))% -> page \(currentPage)/\(pc)")
                return
            }

            let currentPage = max(1, min(pageCount, Int(Double(pageCount) * progress)))
            let isFinished = progress >= 0.99
            let edId = await resolveEditionId(for: bookId)

            let resultReadId = try await HardcoverService.shared.upsertReadingProgress(
                userBookId: userBookId,
                existingReadId: readId > 0 ? readId : nil,
                progressPages: currentPage,
                isFinished: isFinished,
                editionId: edId
            )

            if resultReadId > 0 {
                readSessionCache[bookId] = resultReadId
            }

            AppLogger.sync.info("[Hardcover Sync] Progress: \(Int(progress * 100))% -> page \(currentPage)/\(pageCount)")
        } catch {
            AppLogger.sync.error("[Hardcover Sync] Progress sync failed: \(error.localizedDescription)")
        }
    }

    func syncBookFinished(book: Book) async {
        guard await isEnabled() else { return }

        let bookId = book.stableId
        guard !syncedBookCompletions.contains(bookId) else { return }

        let diagnosticID = DiagnosticLogSanitizer.identifier(for: bookId)
        AppLogger.sync.debug("[Hardcover Sync] Book finished bookId=\(diagnosticID)")

        do {
            let userBookId: Int
            if let cached = userBookIdCache[bookId] {
                userBookId = cached
            } else {
                let hardcoverBookId = try await resolveHardcoverBookId(for: book)
                userBookId = try await ensureInLibrary(
                    hardcoverBookId: hardcoverBookId,
                    localBookId: bookId,
                    asReading: false
                )
            }

            try await HardcoverService.shared.markBookAsFinished(userBookId: userBookId)

            if let readId = readSessionCache[bookId], readId > 0,
                let pageCount = resolvePageCount(for: bookId), pageCount > 0
            {
                _ = try? await HardcoverService.shared.upsertReadingProgress(
                    userBookId: userBookId,
                    existingReadId: readId,
                    progressPages: pageCount,
                    isFinished: true,
                    editionId: resolveEditionId(for: bookId)
                )
            }

            AppLogger.sync.debug("[Hardcover Sync] Finish synced bookId=\(diagnosticID)")
            syncedBookCompletions.insert(bookId)
        } catch {
            AppLogger.sync.error("[Hardcover Sync] Finish sync failed bookId=\(diagnosticID): \(error.localizedDescription)")
        }
    }

    func clearSyncTracking() {
        syncedBookStarts.removeAll()
        syncedBookCompletions.removeAll()
        bookIdCache.removeAll()
        userBookIdCache.removeAll()
        readSessionCache.removeAll()
        pageCountCache.removeAll()
    }

    func getSyncStats() -> (started: Int, completed: Int) {
        return (syncedBookStarts.count, syncedBookCompletions.count)
    }

    private func isEnabled() async -> Bool {
        await MainActor.run {
            let apiKey = SettingsManager.shared.hardcoverApiKey
            let autoSync = SettingsManager.shared.hardcoverAutoSyncEnabled
            return apiKey != nil && !(apiKey!.isEmpty) && autoSync
        }
    }

    private func resolveHardcoverBookId(for book: Book) async throws -> Int {
        let bookId = book.stableId

        if let cached = bookIdCache[bookId] {
            return cached
        }

        let localId = await MainActor.run { book.uniqueId }
        if let match = await MainActor.run(body: { SettingsManager.shared.getHardcoverMatch(forLocalBookId: localId) }) {
            bookIdCache[bookId] = match.hardcoverBookId
            if let ubId = match.hardcoverUserBookId {
                userBookIdCache[bookId] = ubId
            }
            if let pages = match.editionPageCount {
                pageCountCache[bookId] = pages
            }
            return match.hardcoverBookId
        }

        let title = book.title
        let author = book.author
        let searchQuery: String
        if let author, !author.isEmpty {
            searchQuery = "\(title) \(author)"
        } else {
            searchQuery = title
        }

        let results = try await HardcoverService.shared.searchBooks(query: searchQuery, limit: 10)

        guard let match = findBestMatch(localBook: book, hardcoverResults: results) else {
            throw HardcoverSyncError.bookNotFound(title: title)
        }

        bookIdCache[bookId] = match.id
        return match.id
    }

    private func ensureInLibrary(
        hardcoverBookId: Int,
        localBookId: String,
        asReading: Bool
    ) async throws -> Int {
        if let cached = userBookIdCache[localBookId] {
            if asReading {
                try? await HardcoverService.shared.markBookAsStarted(userBookId: cached)
            }
            return cached
        }

        do {
            let userBookId = try await HardcoverService.shared.addBookToLibrary(
                bookId: hardcoverBookId,
                startReading: asReading
            )
            userBookIdCache[localBookId] = userBookId
            return userBookId
        } catch {
            AppLogger.sync.error("[Hardcover Sync] Insert failed, searching library: \(error.localizedDescription)")
        }

        let userBooks = try await HardcoverService.shared.getUserBooks(limit: 200)
        if let existing = userBooks.first(where: { $0.book.id == hardcoverBookId }) {
            userBookIdCache[localBookId] = existing.id

            let readSession = await MainActor.run { existing.currentReadSession }
            if let readSession {
                readSessionCache[localBookId] = readSession.id
            }

            let state = await MainActor.run { existing.readingState }
            if asReading, state != .currentlyReading {
                try? await HardcoverService.shared.markBookAsStarted(userBookId: existing.id)
            }
            return existing.id
        }

        throw HardcoverSyncError.bookNotFound(title: "library lookup failed")
    }

    private func ensureReadSession(
        userBookId: Int,
        localBookId: String,
        book: Book
    ) async throws -> Int {
        if let cached = readSessionCache[localBookId], cached > 0 {
            return cached
        }

        let editionId = await resolveEditionId(for: localBookId)

        let readId = try await HardcoverService.shared.createReadingSession(
            userBookId: userBookId,
            editionId: editionId
        )

        if readId > 0 {
            readSessionCache[localBookId] = readId
        }

        try? await fetchAndCachePageCount(for: book, userBookId: userBookId)

        return readId
    }

    private func resolveUserBookId(for book: Book) async throws -> Int {
        let bookId = book.stableId
        if let cached = userBookIdCache[bookId] {
            return cached
        }

        let hardcoverBookId = try await resolveHardcoverBookId(for: book)
        return try await ensureInLibrary(
            hardcoverBookId: hardcoverBookId,
            localBookId: bookId,
            asReading: true
        )
    }

    private func resolveReadSessionId(for book: Book, userBookId: Int) async throws -> Int {
        let bookId = book.stableId
        if let cached = readSessionCache[bookId], cached > 0 {
            return cached
        }
        return try await ensureReadSession(
            userBookId: userBookId,
            localBookId: bookId,
            book: book
        )
    }

    private func resolvePageCount(for localBookId: String) -> Int? {
        pageCountCache[localBookId]
    }

    private func resolveEditionId(for localBookId: String) async -> Int? {
        let hcBookId = bookIdCache[localBookId]
        let allMatches = await MainActor.run { SettingsManager.shared.getAllHardcoverMatches() }
        return allMatches.first(where: { $0.hardcoverBookId == hcBookId })?.hardcoverEditionId
    }

    private func fetchAndCachePageCount(for book: Book, userBookId: Int) async throws {
        let bookId = book.stableId

        if let editionId = await resolveEditionId(for: bookId) {
            let details = try await HardcoverService.shared.getEditionDetails(editionId: editionId)
            if let pages = details.pages, pages > 0 {
                pageCountCache[bookId] = pages

                let localId = await MainActor.run { book.uniqueId }
                await MainActor.run {
                    if let existingMatch = SettingsManager.shared.getHardcoverMatch(forLocalBookId: localId) {
                        let updatedMatch = HardcoverBookMatch(
                            id: existingMatch.id,
                            localBookId: existingMatch.localBookId,
                            hardcoverBookId: existingMatch.hardcoverBookId,
                            hardcoverUserBookId: userBookId,
                            hardcoverEditionId: editionId,
                            editionPageCount: pages,
                            matchedAt: existingMatch.matchedAt,
                            matchType: existingMatch.matchType,
                            localBookTitle: existingMatch.localBookTitle,
                            hardcoverBookTitle: existingMatch.hardcoverBookTitle
                        )
                        SettingsManager.shared.addHardcoverMatch(updatedMatch)
                    }
                }
                return
            }
        }

        let userBooks = try await HardcoverService.shared.getUserBooks(limit: 200)
        guard let ub = userBooks.first(where: { $0.book.id == bookIdCache[bookId] }),
            let editionId = ub.editionId
        else {
            return
        }
        let details = try await HardcoverService.shared.getEditionDetails(editionId: editionId)
        if let pages = details.pages, pages > 0 {
            pageCountCache[bookId] = pages
        }
    }

    nonisolated private func findBestMatch(
        localBook: Book,
        hardcoverResults: [HardcoverService.Book]
    ) -> HardcoverService.Book? {
        let normalizedLocalTitle = normalizeTitle(localBook.title)
        let localAuthor = localBook.author?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        for result in hardcoverResults {
            let normalizedResultTitle = normalizeTitle(result.title)
            if normalizedResultTitle == normalizedLocalTitle {
                let hcAuthor = (result.cachedContributors?.value ?? "").lowercased()
                if let localAuthor, !hcAuthor.isEmpty {
                    if authorMatches(hcAuthor, localAuthor) {
                        return result
                    }
                } else {
                    return result
                }
            }
        }

        for result in hardcoverResults {
            let normalizedResultTitle = normalizeTitle(result.title)
            if titlesSimilar(normalizedLocalTitle, normalizedResultTitle) {
                let hcAuthor = (result.cachedContributors?.value ?? "").lowercased()
                if let localAuthor, !hcAuthor.isEmpty {
                    if authorMatches(hcAuthor, localAuthor) {
                        return result
                    }
                } else {
                    return result
                }
            }
        }

        return nil
    }

    nonisolated private func authorMatches(_ hardcoverName: String, _ localAuthor: String) -> Bool {
        let hc = hardcoverName.lowercased()
        return hc.contains(localAuthor) || localAuthor.contains(hc)
    }

    nonisolated private func normalizeTitle(_ title: String) -> String {
        title
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    nonisolated private func titlesSimilar(_ title1: String, _ title2: String) -> Bool {
        if title1 == title2 { return true }
        if title1.contains(title2) || title2.contains(title1) { return true }
        let distance = levenshteinDistance(title1, title2)
        let maxLength = max(title1.count, title2.count)
        guard maxLength > 0 else { return true }
        return 1.0 - (Double(distance) / Double(maxLength)) >= 0.85
    }

    nonisolated private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1)
        let b = Array(s2)
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                d[i][j] =
                    a[i - 1] == b[j - 1]
                    ? d[i - 1][j - 1]
                    : min(d[i - 1][j], d[i][j - 1], d[i - 1][j - 1]) + 1
            }
        }
        return d[a.count][b.count]
    }
}

enum HardcoverSyncError: LocalizedError {
    case bookNotFound(title: String)
    case syncDisabled
    case noApiKey

    var errorDescription: String? {
        switch self {
        case .bookNotFound(let title):
            return "Could not find '\(title)' on Hardcover"
        case .syncDisabled:
            return "Hardcover sync is disabled"
        case .noApiKey:
            return "Hardcover API key not configured"
        }
    }
}
