import Foundation

struct JournalMarginaliaEntry: Identifiable {
    let book: Book
    let annotations: [ReaderAnnotation]
    var id: String { book.stableId }
}

struct JournalQuote: Identifiable {
    let book: Book
    let annotation: ReaderAnnotation
    var id: String { annotation.id }
}

struct JournalGrimmoryStatsPayload {
    let books: [GrimmoryRecentBook]
    let sessions: [GrimmoryReadingSessionEntry]
    let insights: GrimmoryStatsSnapshot
}

struct JournalCompletionEntry: Identifiable {
    let book: Book
    let completedAt: Date
    var id: String { book.stableId }
}

struct JournalCompletionSnapshot {
    let almostFinished: [Book]
    let recentlyFinished: [JournalCompletionEntry]

    static let empty = JournalCompletionSnapshot(almostFinished: [], recentlyFinished: [])
}

@MainActor
@Observable
final class JournalEngine {
    private let appState: AppState

    init(appState: AppState = .shared) {
        self.appState = appState
    }

    func marginaliaEntries(limit: Int = 5000) async -> [JournalMarginaliaEntry] {
        let ebooks = await appState.bookStore.firstBooks(mediaType: "ebook", limit: limit)
        var result: [(entry: JournalMarginaliaEntry, lastUpdated: Date)] = []

        for book in ebooks {
            var annotations = ReaderArtifactsStore.shared.loadAnnotations(bookId: book.stableId)
            if book.stableId != book.id {
                let legacy = ReaderArtifactsStore.shared.loadAnnotations(bookId: book.id)
                if !legacy.isEmpty {
                    let existing = Set(annotations.map(\.id))
                    annotations += legacy.filter { !existing.contains($0.id) }
                }
            }
            annotations = annotations.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !annotations.isEmpty else { continue }

            let lastUpdated = annotations.map(\.updatedAt).max() ?? .distantPast
            let entry = JournalMarginaliaEntry(
                book: book,
                annotations: annotations.sorted { $0.position < $1.position }
            )
            result.append((entry, lastUpdated))
        }

        return
            result
            .sorted { $0.lastUpdated > $1.lastUpdated }
            .map(\.entry)
    }

    func recentQuotes(limit: Int) async -> [JournalQuote] {
        await marginaliaEntries()
            .flatMap { entry in entry.annotations.map { JournalQuote(book: entry.book, annotation: $0) } }
            .sorted { $0.annotation.updatedAt > $1.annotation.updatedAt }
            .prefix(limit)
            .map { $0 }
    }

    func recentlyFinishedBooks(limit: Int) async -> [Book] {
        let collection = SmartCollection(
            id: "journal.finished",
            name: "Finished",
            description: nil,
            rules: SmartCollectionRuleGroup(
                logicOperator: .and,
                rules: [SmartCollectionRule(field: .isFinished, operator: .isTrue, value: "")]
            ),
            iconName: "checkmark",
            color: "",
            isSystem: true,
            sortOrder: 0
        )

        return await appState.bookStore.booksMatching(collection, limit: max(limit * 8, 500))
            .filter { $0.mediaType != .podcast }
            .sorted { $0.lastUpdate > $1.lastUpdate }
            .prefix(limit)
            .map { $0 }
    }

    func completionSnapshot(almostFinishedLimit: Int = 12, recentlyFinishedLimit: Int = 60) async -> JournalCompletionSnapshot {
        async let listening = appState.bookStore.continueListeningBooks(limit: 500)
        async let reading = appState.bookStore.continueReadingBooks(limit: 500)

        var seen = Set<String>()
        let almostFinished = await (listening + reading)
            .filter { book in
                let progress = Self.completionProgress(for: book)
                return book.mediaType != .podcast
                    && !book.isFinished
                    && progress >= 0.75
                    && progress < 0.99
                    && seen.insert(book.stableId).inserted
            }
            .sorted { left, right in
                let leftProgress = Self.completionProgress(for: left)
                let rightProgress = Self.completionProgress(for: right)
                return leftProgress == rightProgress
                    ? left.lastUpdate > right.lastUpdate
                    : leftProgress > rightProgress
            }
            .prefix(almostFinishedLimit)
            .map { $0 }

        let recentlyFinished = await recentlyFinishedBooks(limit: recentlyFinishedLimit)
            .map { JournalCompletionEntry(book: $0, completedAt: $0.lastUpdate) }

        return JournalCompletionSnapshot(
            almostFinished: almostFinished,
            recentlyFinished: recentlyFinished
        )
    }

    nonisolated static func completionProgress(for book: Book) -> Double {
        if book.mediaType == .ebook {
            return max(book.canonicalEbookProgress, book.progressPercentage)
        }
        return book.progressPercentage
    }

    func grimmoryStatsPayload() async throws -> JournalGrimmoryStatsPayload? {
        guard let connection = appState.providerConnections.connections.first(where: { $0.type == .booklore && !$0.isArchived }),
            let provider = appState.getProvider(connection.id) as? BookloreProvider
        else {
            return nil
        }

        _ = try await provider.validateConnection()
        async let books = (try? await provider.fetchAllBooksForStats()) ?? []
        async let sessions = (try? await provider.fetchReadingSessions(limit: 200)) ?? []
        async let insights = provider.fetchGrimmoryStats()
        return await JournalGrimmoryStatsPayload(books: books, sessions: sessions, insights: insights)
    }

    func audiobookshelfListeningStats() async throws -> AudiobookshelfListeningStats? {
        let backends = appState.providerConnections.allBackends()
            .filter { $0.type == .audiobookshelf && $0.enabled }
        guard !backends.isEmpty else { return nil }

        return try await AudiobookshelfProgressSync().fetchListeningStats()
    }

    func remoteHistorySessions() async -> [HistorySession] {
        var remote: [HistorySession] = []

        if let connection = appState.providerConnections.connections.first(where: { $0.type == .booklore && !$0.isArchived }),
            let provider = appState.getProvider(connection.id) as? BookloreProvider,
            let sessions = try? await provider.fetchReadingSessions(limit: 200)
        {
            remote += sessions.map { entry in
                let start = Self.parseISO8601(entry.startTime) ?? Date()
                let fallbackEnd = start.addingTimeInterval(TimeInterval(entry.durationSeconds ?? 0))
                return HistorySession(
                    id: entry.id,
                    bookId: String(entry.bookId),
                    mediaType: entry.bookType?.lowercased() == "audiobook" ? "audiobook" : "ebook",
                    startTime: start,
                    endTime: entry.endTime.flatMap(Self.parseISO8601) ?? fallbackEnd,
                    durationSeconds: entry.durationSeconds ?? 0,
                    startProgress: entry.startProgress,
                    endProgress: entry.endProgress,
                    progressDelta: entry.progressDelta,
                    startLocation: nil,
                    endLocation: nil,
                    pagesRead: nil,
                    source: .grimmory
                )
            }
        }

        if let backend = appState.providerConnections.allBackends()
            .first(where: { $0.type == .audiobookshelf && $0.enabled })
        {
            let syncer = AudiobookshelfProgressSync()
            syncer.backend = backend
            if let sessions = try? await syncer.fetchListeningSessions(page: 0, itemsPerPage: 100) {
                remote += sessions.compactMap { session -> HistorySession? in
                    let duration = Int(session.timeListening)
                    guard duration > 0 else { return nil }
                    let start = session.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
                    return HistorySession(
                        id: session.id,
                        bookId: "",
                        mediaType: "audiobook",
                        startTime: start,
                        endTime: session.updatedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
                            ?? start.addingTimeInterval(TimeInterval(duration)),
                        durationSeconds: duration,
                        startProgress: nil,
                        endProgress: nil,
                        progressDelta: nil,
                        startLocation: nil,
                        endLocation: nil,
                        pagesRead: nil,
                        source: .audiobookshelf
                    )
                }
            }
        }

        return remote
    }

    func renderObsidianManualExport(preferences: UserPreferences) async -> String {
        let books = await appState.bookStore.allBooks()
        var output = ""

        for book in books {
            let stableId = book.stableId
            let annotations = await appState.bookStore.annotations(forBookStableId: stableId)
            let bookmarks = await appState.bookStore.bookmarks(forBookStableId: stableId)

            let hasAnnotations = annotations.contains { !$0.isRemotePlaceholder }
            let hasBookmarkNotes = bookmarks.contains { !$0.isRemotePlaceholder && ($0.note?.isEmpty == false) }
            guard hasAnnotations || hasBookmarkNotes else { continue }

            let payload = BookNotesPayloadBuilder.build(
                book: book,
                annotations: annotations,
                bookmarks: bookmarks,
                lastSyncedAt: preferences.obsidianLastSyncDates[stableId]
            )
            let rendered = NotesTemplateEngine.render(template: preferences.obsidianTemplateBody, payload: payload)
            if !output.isEmpty { output += "\n\n---\n\n" }
            output += rendered
        }

        if output.isEmpty {
            output = "# No notes yet\n\nMake some highlights or bookmarks while reading, then come back to export them."
        }
        return output
    }

    private static func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
