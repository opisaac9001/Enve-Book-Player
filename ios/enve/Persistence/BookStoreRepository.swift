import Foundation

struct BookProgressSnapshot: Sendable {
    let bookUniqueId: String
    let stableId: String
    let currentTime: TimeInterval
    let duration: TimeInterval
    let ebookProgress: Double?
    let epubLocator: String?
    let isFinished: Bool
    let lastUpdate: Date
    let hideFromContinue: Bool
}

struct AuthoritativeProgressUpdate: Sendable {
    let bookUniqueId: String
    let stableId: String
    let currentTime: TimeInterval
    let duration: TimeInterval
    let ebookProgress: Double?
    let epubLocator: String?
    let isFinished: Bool
    let lastUpdate: Date
    let hideFromContinue: Bool
    let serverReadStatus: String?

    init(
        bookUniqueId: String,
        stableId: String,
        currentTime: TimeInterval,
        duration: TimeInterval,
        ebookProgress: Double? = nil,
        epubLocator: String? = nil,
        isFinished: Bool,
        lastUpdate: Date,
        hideFromContinue: Bool = false,
        serverReadStatus: String? = nil
    ) {
        self.bookUniqueId = bookUniqueId
        self.stableId = stableId
        self.currentTime = currentTime
        self.duration = duration
        self.ebookProgress = ebookProgress
        self.epubLocator = epubLocator
        self.isFinished = isFinished
        self.lastUpdate = lastUpdate
        self.hideFromContinue = hideFromContinue
        self.serverReadStatus = serverReadStatus
    }
}

struct BookBrowseSlice: Sendable {
    let id: String
    let mediaType: String
    let author: String?
    let narrator: String?
    let series: String?
    let genres: [String]?
    let thumb: String?
}

struct BookPresence: Sendable {
    let libraryKeys: Set<String>
    let smbBackendIds: Set<String>
    let hasReadAloud: Bool
}

struct FinishedBookSummary: Sendable, Equatable {
    let stableId: String
    let mediaType: AppMediaType
    let lastUpdate: Date
}

struct BookStatisticsSlice: Sendable, Equatable {
    let id: String
    let title: String
    let mediaType: AppMediaType
    let author: String?
    let narrator: String?
    let series: String?
    let publisher: String?
    let genres: [String]?
    let language: String?
    let isbn: String?
    let thumb: String?
    let publishedYear: Int?
    let addedAt: Date?
    let duration: TimeInterval?
    let isFinished: Bool
    let progress: Double
}

struct BrowseAuthorAggregate: Sendable, Hashable {
    let name: String
    let bookCount: Int
    let representativeThumb: String?
    let matchingNames: [String]

    nonisolated init(name: String, bookCount: Int, representativeThumb: String?, matchingNames: [String]? = nil) {
        self.name = name
        self.bookCount = bookCount
        self.representativeThumb = representativeThumb
        self.matchingNames = matchingNames ?? [name]
    }
}

struct BrowseNarratorAggregate: Sendable, Hashable {
    let name: String
    let bookCount: Int
    let representativeThumb: String?
}

struct BrowseSeriesAggregate: Sendable, Hashable {
    let name: String
    let bookCount: Int
    let completedBookCount: Int
    let representativeThumb: String?
    let matchingNames: [String]

    nonisolated init(
        name: String,
        bookCount: Int,
        completedBookCount: Int = 0,
        representativeThumb: String?,
        matchingNames: [String]? = nil
    ) {
        self.name = name
        self.bookCount = bookCount
        self.completedBookCount = min(max(completedBookCount, 0), bookCount)
        self.representativeThumb = representativeThumb
        self.matchingNames = matchingNames ?? [name]
    }

    nonisolated var unreadBookCount: Int {
        max(0, bookCount - completedBookCount)
    }

    nonisolated var readingStatusText: String {
        unreadBookCount == 0 ? "All read" : "\(unreadBookCount) unread"
    }
}

struct BrowseGenreAggregate: Sendable, Hashable {
    let name: String
    let bookCount: Int
    let matchingGenres: [String]

    nonisolated init(name: String, bookCount: Int, matchingGenres: [String]? = nil) {
        self.name = name
        self.bookCount = bookCount
        self.matchingGenres = matchingGenres ?? [name]
    }
}

struct ReconciliationStart: Sendable {
    let generation: Int
    let existingCount: Int
}

enum ReconciliationOutcome: Sendable {

    case completed(deleted: Int, kept: Int)

    case refusedSparseResponse(existing: Int, incoming: Int)
}

enum BookStoreWriteError: Error {
    case invalidBookIdentity
}

enum BookStoreSortField: Sendable, Hashable {
    case recent
    case recentlyRead
    case title
    case authorGiven
    case authorSurname
    case narratorGiven
    case narratorSurname
    case series
    case progress
    case duration
    case year
    case goodreadsRating
}

enum BookStoreSortDirection: Sendable, Hashable {
    case ascending
    case descending
}

struct BookStoreSortDescriptor: Sendable, Hashable {
    var field: BookStoreSortField
    var direction: BookStoreSortDirection
}

protocol BookQuerying: Sendable {
    func allBooks() async -> [Book]
    func downloadedAudiobooks(storageKeys: Set<String>) async -> [Book]
    func readerArtifactBookStableIds() async -> Set<String>
    func finishedBookSummaries() async -> [FinishedBookSummary]
    func bookStatisticsSlices() async -> [BookStatisticsSlice]
    func activeBooks(excludingSource: String, minProgressThreshold: Double) async -> [Book]
    func browseSlices(source: String) async -> [BookBrowseSlice]
    func browseSlices(mediaType: String) async -> [BookBrowseSlice]
    func books(inSeries seriesName: String) async -> [Book]
    func books(workKey key: String) async -> [Book]
    func books(editionKey key: String) async -> [Book]
    func booksWithIdentifiers(limit: Int) async -> [Book]
    func workSlices() async -> [WorkSlice]
    func firstBooks(libraryId: String, providerId: UUID, limit: Int) async -> [Book]
    func books(withIds ids: [String]) async -> [Book]
    func firstBooks(source: String, mediaType: String, limit: Int) async -> [Book]
    func firstBooks(mediaType: String, limit: Int) async -> [Book]
    func bookCount(mediaType: String) async -> Int
    func book(byBookId id: String) async -> Book?
    func book(byAnyId id: String) async -> Book?
    func books(source: String, providerId: UUID) async -> [Book]
    func books(source: String, providerId: UUID, mediaType: String) async -> [Book]
    func booksWithProgress(providerId: UUID) async -> [Book]
    func books(backendId: String, source: String?) async -> [Book]
    func firstBooksWithReadAloudSource(limit: Int) async -> [Book]
    func firstBooksWithoutReadAloudSource(limit: Int) async -> [Book]
    func bookCountWithReadAloudSource() async -> Int
    func hasBook(stableId: String, requiresWithoutReadAloudSource: Bool) async -> Bool
    func bookPresence() async -> BookPresence
    func allBookUniqueIds() async -> Set<String>
    func allBookIds() async -> Set<String>
    func bookCountsBySource() async -> [(source: String, count: Int)]
    func bookCountsBySection(source: String) async -> [(libraryId: String, providerId: String, count: Int)]
    func titleAuthorPairs() async -> [(title: String, author: String)]
    func book(uniqueId: String) async -> Book?
    func book(stableId: String) async -> Book?
    func absorbedStableIds() async -> Set<String>
    func booksByUniqueIds(_ ids: Set<String>) async -> [String: Book]
    func booksByIds(_ ids: Set<String>) async -> [String: Book]
    func booksByAnyIds(_ ids: Set<String>) async -> [String: Book]
    func booksByStableIds(_ ids: Set<String>) async -> [String: Book]
    func existingAudiobookStableIds(from candidates: Set<String>) async -> Set<String>
    func booksMatching(_ collection: SmartCollection, limit: Int?) async -> [Book]
    func bookCountMatching(_ collection: SmartCollection) async -> Int

    func continueListeningBooks(limit: Int) async -> [Book]
    func continueReadingBooks(limit: Int) async -> [Book]
    func recentBooks(limit: Int) async -> [Book]
    func recentEbooks(limit: Int) async -> [Book]
    func downloadedEbooks(limit: Int) async -> [Book]
    func pagedBooks(offset: Int, limit: Int, mediaType: String?) async -> [Book]
    func pagedBooks(libraryId: String, providerId: UUID, offset: Int, limit: Int) async -> [Book]
    func booksAfterUniqueId(_ cursor: String?, limit: Int) async -> [Book]
    func pagedBooks(after cursor: Book?, limit: Int, mediaType: String?) async -> [Book]
    func pagedBooks(libraryId: String, providerId: UUID, after cursor: Book?, limit: Int) async -> [Book]
    func pagedBooks(providerId: UUID, after cursor: Book?, limit: Int, mediaType: String?) async -> [Book]
    func sortedPagedBooks(offset: Int, limit: Int, mediaType: String?, sort: [BookStoreSortDescriptor]) async -> [Book]
    func sortedPagedBooks(providerId: UUID, offset: Int, limit: Int, mediaType: String?, sort: [BookStoreSortDescriptor]) async -> [Book]
    func sortedPagedBooks(
        libraryId: String,
        providerId: UUID,
        offset: Int,
        limit: Int,
        mediaType: String?,
        sort: [BookStoreSortDescriptor]
    ) async -> [Book]
    func searchBooks(query: String, limit: Int) async -> [Book]
    func searchBooks(query: String, mediaType: String, limit: Int) async -> [Book]
    func browseAuthorAggregates(mediaType: String) async -> [BrowseAuthorAggregate]
    func browseNarratorAggregates(mediaType: String) async -> [BrowseNarratorAggregate]
    func browseSeriesAggregates(mediaType: String) async -> [BrowseSeriesAggregate]
    func books(byAuthor author: String, mediaType: String, limit: Int) async -> [Book]
    func books(byAuthorNames authorNames: [String], mediaType: String, limit: Int) async -> [Book]
    func books(byNarrator narrator: String, mediaType: String, limit: Int) async -> [Book]
    func books(bySeries series: String, mediaType: String, limit: Int) async -> [Book]
    func books(bySeriesNames seriesNames: [String], mediaType: String, limit: Int) async -> [Book]
    func books(inSeriesNames seriesNames: [String]) async -> [Book]
    func bookCount() async -> Int
    func bookCount(libraryId: String, providerId: UUID) async -> Int
    func bookCount(providerId: UUID, mediaType: String?) async -> Int
    func hasData() async -> Bool
    func searchBooks(query: String, libraryId: String?, providerId: UUID?, limit: Int) async -> [Book]
}

protocol BookWriting: Sendable {
    func upsertBooks(_ books: [Book]) async
    func replaceLibrary(books: [Book], libraryId: String, providerId: UUID, allowSparseResult: Bool) async
    @discardableResult
    func deleteBooksFromUnknownProviders(validProviderIds: Set<String>) async -> Int
    @discardableResult
    func deleteBooksFromInactiveLibraries(
        validProviderIds: Set<String>,
        restrictedLibraryIds: [String: Set<String>]
    ) async -> Int
    func updateEbookFileURL(uniqueId: String, url: URL?) async
    func setHidden(_ hidden: Bool, stableId: String) async
    func setDeleted(_ deleted: Bool, stableId: String) async
    func deleteBooks(uniqueIds: Set<String>) async
    func importLegacyBooks(_ books: [Book], hiddenStableIds: Set<String>, deletedStableIds: Set<String>) async
    func clearAllData() async
}

protocol CatalogReconciling: Sendable {
    func beginReconciliation(libraryId: String, providerId: UUID) async -> ReconciliationStart
    func upsertReconciledPage(books: [Book], generation: Int, notifyChange: Bool) async throws
    func endReconciliation(
        libraryId: String,
        providerId: UUID,
        generation: Int,
        existingCountBefore: Int
    ) async throws -> ReconciliationOutcome
    func applyDelta(books: [Book], libraryId: String, providerId: UUID, cursor: Date) async
    func loadCursor(providerId: UUID, libraryId: String) async -> LibrarySyncCursorSnapshot?
    func markFullReconciled(providerId: UUID, libraryId: String, at date: Date) async
}

protocol ProgressRepository: Sendable {
    func updateProgress(uniqueId: String, currentTime: TimeInterval, isFinished: Bool, lastUpdate: Date) async
    func applyAuthoritativeProgress(_ updates: [AuthoritativeProgressUpdate]) async
    func updateEbookProgress(uniqueId: String, ebookProgress: Double?, epubLocator: String?, isFinished: Bool, lastUpdate: Date) async
    func upsertProgress(
        bookUniqueId: String,
        stableId: String,
        currentTime: TimeInterval,
        duration: TimeInterval,
        ebookProgress: Double?,
        epubLocator: String?,
        isFinished: Bool,
        lastUpdate: Date,
        hideFromContinue: Bool,
        preserveEbookPosition: Bool
    ) async
    func progress(forBookUniqueId: String) async -> BookProgressSnapshot?
    func importLegacyProgress(
        _ entries: [(
            bookUniqueId: String, stableId: String, currentTime: TimeInterval,
            duration: TimeInterval, isFinished: Bool, lastUpdate: Date
        )]
    ) async
}

protocol ReaderArtifactRepository: Sendable {
    func upsertLink(ebookStableId: String, audiobookStableId: String, chapterOffset: Int) async
    func removeLink(ebookStableId: String) async
    func linkedAudiobookStableId(forEbookStableId: String) async -> String?
    func linkedEbookStableId(forAudiobookStableId: String) async -> String?
    func allLinks() async -> [(ebookStableId: String, audiobookStableId: String, chapterOffset: Int)]
    func importLegacyLinks(_ links: [(ebookStableId: String, audiobookStableId: String, chapterOffset: Int)]) async

    func bookmarkedBookStableIds() async -> Set<String>
    func bookmarks(forBookStableId: String) async -> [Bookmark]
    func upsertBookmark(_ bookmark: Bookmark, bookStableId: String) async
    func deleteBookmark(id: String) async
    func replaceBookmarks(forBookStableId: String, bookmarks: [Bookmark]) async
    func importLegacyBookmarks(_ bookmarks: [Bookmark], bookStableId: String) async

    func annotations(forBookStableId: String) async -> [ReaderAnnotation]
    func upsertAnnotation(_ annotation: ReaderAnnotation, bookStableId: String) async
    func deleteAnnotation(id: String) async
    func replaceAnnotations(forBookStableId: String, annotations: [ReaderAnnotation]) async
    func importLegacyAnnotations(_ annotations: [ReaderAnnotation], bookStableId: String) async

    func vocabEntries(forBookStableId: String) async -> [VocabEntry]
    func allVocabEntries() async -> [VocabEntry]
    func upsertVocabEntry(_ entry: VocabEntry) async
    func deleteVocabEntry(id: String) async

    func cachedChapters(forBookStableId: String) async -> [Chapter]?
    func cacheChapters(_ chapters: [Chapter], forBookStableId: String) async
}

protocol BookStoreRepository: BookQuerying, BookWriting, CatalogReconciling, ProgressRepository,
    ReaderArtifactRepository
{}

extension BookStoreRepository {

    func upsertReconciledPage(books: [Book], generation: Int) async throws {
        try await upsertReconciledPage(books: books, generation: generation, notifyChange: true)
    }

    func observe(_ query: BookQuery) -> AsyncStream<[Book]> {
        observe { [self] in await self.fetch(query) }
    }

    func observe<T: Sendable>(_ fetch: @Sendable @escaping () async -> T) -> AsyncStream<T> {
        AsyncStream { continuation in
            let task = Task {
                continuation.yield(await fetch())
                let stream = NotificationCenter.default.notifications(named: .bookStoreDidChange)
                var lastEmit = Date.distantPast
                for await _ in stream {
                    if Task.isCancelled { break }
                    let elapsed = Date().timeIntervalSince(lastEmit)

                    if elapsed < 1.5 {
                        try? await Task.sleep(nanoseconds: UInt64((1.5 - elapsed) * 1_000_000_000))
                        if Task.isCancelled { break }
                    }
                    lastEmit = Date()
                    continuation.yield(await fetch())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func fetch(_ query: BookQuery) async -> [Book] {
        switch query {
        case .matching(_, let collection):
            return await booksMatching(collection, limit: nil)
        case .inSeries(let name):
            return await books(inSeries: name)
        case .mediaType(let mt):
            return await firstBooks(mediaType: mt, limit: 5000)
        case .sourceMediaType(let source, let mt):
            return await firstBooks(source: source, mediaType: mt, limit: 5000)
        case .library(let libraryId, let providerId):
            return await firstBooks(libraryId: libraryId, providerId: providerId, limit: 5000)
        case .continueListening(let limit):
            return await continueListeningBooks(limit: limit)
        case .continueReading(let limit):
            return await continueReadingBooks(limit: limit)
        case .recent(let limit):
            return await recentBooks(limit: limit)
        case .recentEbooks(let limit):
            return await recentEbooks(limit: limit)
        case .downloadedEbooks(let limit):
            return await downloadedEbooks(limit: limit)
        case .search(let q, let limit):
            return await searchBooks(query: q, limit: limit)
        }
    }
}
