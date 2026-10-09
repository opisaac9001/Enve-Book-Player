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

struct JournalAudiobookshelfStatsPayload {
    let stats: AudiobookshelfListeningStats
    let sessions: [AudiobookshelfListeningStats.AudiobookshelfSession]
    let progress: [UserMediaProgress]
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

    private unowned let profileSession: ProfileSession?

    init(profileSession: ProfileSession? = nil, appState: AppState = .shared) {
        self.profileSession = profileSession
        self.appState = appState
    }

    func marginaliaEntries(limit: Int = 5000) async -> [JournalMarginaliaEntry] {
        let ebooks = await appState.bookStore.firstBooks(mediaType: "ebook", limit: limit)
        var result: [(entry: JournalMarginaliaEntry, lastUpdated: Date)] = []

        for book in ebooks {
            var annotations = (profileSession?.readerArtifacts ?? ReaderArtifactsStore.shared).loadAnnotations(bookId: book.stableId)
            if book.stableId != book.id {
                let legacy = (profileSession?.readerArtifacts ?? ReaderArtifactsStore.shared).loadAnnotations(bookId: book.id)
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
                    && progress < Book.finishedProgressThreshold
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
        async let sessions = (try? await provider.fetchReadingSessions(limit: 2_000, recentBooks: 100)) ?? []
        async let insights = provider.fetchGrimmoryStats()
        return await JournalGrimmoryStatsPayload(books: books, sessions: sessions, insights: insights)
    }

    static func isThisDevice(_ session: AudiobookshelfListeningStats.AudiobookshelfSession) -> Bool {
        guard let deviceId = session.deviceInfo?.deviceId else { return false }
        return deviceId == AudiobookshelfProvider.clientDeviceId || deviceId == AudiobookshelfService.persistedDeviceId
    }

    private var audiobookshelfProvider: AudiobookshelfProvider? {
        appState.providerConnections.connections
            .first { $0.type == .audiobookshelf && !$0.isArchived }
            .flatMap { appState.getProvider($0.id) as? AudiobookshelfProvider }
    }

    func audiobookshelfListeningStats() async throws -> JournalAudiobookshelfStatsPayload? {
        guard let provider = audiobookshelfProvider else { return nil }
        async let stats = provider.fetchListeningStats()
        async let sessions = provider.fetchAllListeningSessions()
        async let progress = (try? provider.fetchUserMediaProgress(libraryId: "")) ?? []
        return try await JournalAudiobookshelfStatsPayload(stats: stats, sessions: sessions, progress: progress)
    }

    // Grimmory does not record the device, so match both the book and the time when removing Enve uploads.
    static func isCoveredByLocal(start: Date, end: Date, bookId: Int, local: [HistorySession]) -> Bool {
        local.contains {
            $0.bookId.hasPrefix("grimmory:")
                && ($0.bookId.hasSuffix(":\(bookId)") || $0.bookId.hasSuffix(":grimmory-ab-\(bookId)"))
                && start >= $0.startTime.addingTimeInterval(-60)
                && end <= $0.endTime.addingTimeInterval(60)
        }
    }

    func remoteHistorySessions(excludingCoveredBy local: [HistorySession]) async -> [HistorySession] {
        var remote: [HistorySession] = []

        if let connection = appState.providerConnections.connections.first(where: { $0.type == .booklore && !$0.isArchived }),
            let provider = appState.getProvider(connection.id) as? BookloreProvider,
            let sessions = try? await provider.fetchReadingSessions(limit: 2_000, recentBooks: 100)
        {
            remote += sessions.compactMap { entry -> HistorySession? in
                let start = ISO8601Timestamp.parse(entry.startTime) ?? Date()
                let fallbackEnd = start.addingTimeInterval(TimeInterval(entry.durationSeconds ?? 0))
                let end = ISO8601Timestamp.parse(entry.endTime) ?? fallbackEnd
                guard !Self.isCoveredByLocal(start: start, end: end, bookId: entry.bookId, local: local) else { return nil }
                // Grimmory reports progress as 0-100.
                return HistorySession(
                    id: entry.id,
                    bookId: String(entry.bookId),
                    mediaType: entry.bookType?.lowercased() == "audiobook" ? "audiobook" : "ebook",
                    startTime: start,
                    endTime: end,
                    durationSeconds: entry.durationSeconds ?? 0,
                    startProgress: entry.startProgress.map { $0 / 100 },
                    endProgress: entry.endProgress.map { $0 / 100 },
                    progressDelta: entry.progressDelta.map { $0 / 100 },
                    startLocation: nil,
                    endLocation: nil,
                    pagesRead: nil,
                    source: .grimmory
                )
            }
        }

        if let provider = audiobookshelfProvider {
            if let sessions = try? await provider.fetchListeningSessions(page: 0, itemsPerPage: 100) {
                // This device's ABS sessions already exist locally.
                remote += sessions.filter { !Self.isThisDevice($0) }.compactMap { session -> HistorySession? in
                    let duration = Int(session.timeListening)
                    guard duration > 0 else { return nil }
                    let start = session.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
                    return HistorySession(
                        id: session.id,
                        bookId: session.libraryItemId ?? "",
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
        let stableIds = await appState.bookStore.readerArtifactBookStableIds()
        let books = Array(await appState.bookStore.booksByStableIds(stableIds).values)
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
}
