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

struct BrowseSeriesAggregate: Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    let bookCount: Int
    let completedBookCount: Int
    let representativeThumb: String?
    let matchingNames: [String]
    let isComic: Bool
    let providerId: UUID?
    let libraryId: String?
    let comicSeriesID: String?
    let resumeBookUniqueID: String?
    let resumeBookLastUpdate: Date?
    let sections: [ComicSeriesSectionSummary]
    let volumes: [ComicVolumeSummary]
    let standaloneBookUniqueID: String?

    // Comic identity is scoped to connection and library; legacy comics without a server series ID use the exact title.
    nonisolated init(
        name: String,
        bookCount: Int,
        completedBookCount: Int = 0,
        representativeThumb: String?,
        matchingNames: [String]? = nil,
        isComic: Bool = false,
        providerId: UUID? = nil,
        libraryId: String? = nil,
        comicSeriesID: String? = nil,
        resumeBookUniqueID: String? = nil,
        resumeBookLastUpdate: Date? = nil,
        sections: [ComicSeriesSectionSummary] = [],
        volumes: [ComicVolumeSummary] = [],
        standaloneBookUniqueID: String? = nil
    ) {
        if isComic {
            let scope = "\(providerId?.uuidString ?? "")|\(libraryId ?? "")"
            id = standaloneBookUniqueID.map { "comic|\(scope)|book:\($0)" }
                ?? comicSeriesID.map { "comic|\(scope)|id:\($0)" } ?? "comic|\(scope)|title:\(name)"
        } else {
            id = "series|\(providerId?.uuidString ?? "")|\(libraryId ?? "")|\(name)"
        }
        self.name = name
        self.bookCount = bookCount
        self.completedBookCount = min(max(completedBookCount, 0), bookCount)
        self.representativeThumb = representativeThumb
        self.matchingNames = matchingNames ?? [name]
        self.isComic = isComic
        self.providerId = providerId
        self.libraryId = libraryId
        self.comicSeriesID = comicSeriesID
        self.resumeBookUniqueID = resumeBookUniqueID
        self.resumeBookLastUpdate = resumeBookLastUpdate
        self.sections = sections
        self.volumes = volumes
        self.standaloneBookUniqueID = standaloneBookUniqueID
    }

    nonisolated var unreadBookCount: Int {
        max(0, bookCount - completedBookCount)
    }

    nonisolated var readingStatusText: String {
        unreadBookCount == 0 ? "All read" : "\(unreadBookCount) unread"
    }

    nonisolated func includes(_ book: Book) -> Bool {
        if let providerId, book.providerId != providerId { return false }
        if let libraryId, book.libraryId != libraryId { return false }
        guard isComic else { return !book.isComic }
        guard book.isComic else { return false }
        if let standaloneBookUniqueID { return book.uniqueId == standaloneBookUniqueID }
        if let comicSeriesID { return book.comicMetadata?.seriesID == comicSeriesID }
        return book.comicMetadata == nil
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
    func ebookLinkedAudiobookIds(source: String) async -> [(ebookStableId: String, audiobookStableId: String)]
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
    func browseSeriesAggregates(mediaType: String, providerId: UUID, libraryId: String?) async -> [BrowseSeriesAggregate]
    func seriesAggregate(for aggregate: BrowseSeriesAggregate) async -> BrowseSeriesAggregate?
    func seriesBooksPage(for aggregate: BrowseSeriesAggregate, mediaScope: [String], offset: Int, limit: Int) async -> [Book]
    func seriesBooksPage(for aggregate: BrowseSeriesAggregate, mediaScope: [String], offset: Int, limit: Int, slice: ComicSeriesSlice) async -> [Book]
    func comicBooksPage(sourceFilter: LibrarySourceFilter, offset: Int, limit: Int) async -> [Book]
    func comicBookCount(sourceFilter: LibrarySourceFilter) async -> Int
    func comicBooksPage(sourceFilter: LibrarySourceFilter, offset: Int, limit: Int, sort: [BookStoreSortDescriptor]) async -> [Book]
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

// In-memory defaults for fakes; SwiftDataBookStore filters, orders and pages in the store.
extension BookQuerying {
    func seriesBooksPage(for aggregate: BrowseSeriesAggregate, mediaScope: [String], offset: Int, limit: Int, slice: ComicSeriesSlice) async -> [Book] {
        guard limit > 0 else { return [] }
        let books = await seriesBooksPage(for: aggregate, mediaScope: mediaScope, offset: 0, limit: await bookCount())
        return Array(books.filter { slice.includes($0.comicMetadata) }.dropFirst(max(0, offset)).prefix(limit))
    }
    func seriesAggregate(for aggregate: BrowseSeriesAggregate) async -> BrowseSeriesAggregate? {
        let groups = await browseSeriesAggregates(mediaType: "ebook")
        return groups.first { $0.id == aggregate.id }
    }
    func seriesBooksPage(for aggregate: BrowseSeriesAggregate, mediaScope: [String], offset: Int, limit: Int) async -> [Book] {
        guard limit > 0 else { return [] }
        if let id = aggregate.standaloneBookUniqueID {
            guard offset == 0, let book = await book(uniqueId: id),
                aggregate.includes(book),
                mediaScope.isEmpty || mediaScope.contains(book.mediaType.rawValue) else { return [] }
            return [book]
        }
        let members = await books(inSeriesNames: aggregate.matchingNames)
            .filter { aggregate.includes($0) && (mediaScope.isEmpty || mediaScope.contains($0.mediaType.rawValue)) }
            .sorted(by: seriesMemberOrder)
        return Array(members.dropFirst(max(0, offset)).prefix(limit))
    }

    func comicBooksPage(sourceFilter: LibrarySourceFilter, offset: Int, limit: Int) async -> [Book] {
        guard limit > 0 else { return [] }
        let comics = await allBooks()
            .filter { $0.isComic && sourceFilter.includes($0) }
            .sorted { lhs, rhs in
                let order = (lhs.series ?? "").localizedStandardCompare(rhs.series ?? "")
                if order != .orderedSame { return order == .orderedAscending }
                if lhs.comicMetadata?.seriesID != rhs.comicMetadata?.seriesID {
                    return (lhs.comicMetadata?.seriesID ?? "") < (rhs.comicMetadata?.seriesID ?? "")
                }
                return seriesMemberOrder(lhs, rhs)
            }
        return Array(comics.dropFirst(max(0, offset)).prefix(limit))
    }

    func comicBooksPage(sourceFilter: LibrarySourceFilter, offset: Int, limit: Int, sort: [BookStoreSortDescriptor]) async -> [Book] {
        guard limit > 0 else { return [] }
        let count = await bookCount()
        let sorted: [Book]
        switch sourceFilter {
        case .library(let providerId, let libraryId):
            sorted = await sortedPagedBooks(libraryId: libraryId, providerId: providerId, offset: 0, limit: count, mediaType: "ebook", sort: sort)
        case .connection(let id):
            sorted = await sortedPagedBooks(providerId: id, offset: 0, limit: count, mediaType: "ebook", sort: sort)
        case .all, .device:
            sorted = await sortedPagedBooks(offset: 0, limit: count, mediaType: "ebook", sort: sort)
        }
        return Array(sorted.filter { $0.isComic && sourceFilter.includes($0) }.dropFirst(max(0, offset)).prefix(limit))
    }

    func comicBookCount(sourceFilter: LibrarySourceFilter) async -> Int {
        await allBooks().count { $0.isComic && sourceFilter.includes($0) }
    }
}

private nonisolated func seriesMemberOrder(_ lhs: Book, _ rhs: Book) -> Bool {
    func key(_ book: Book) -> [Double] {
        let metadata = book.comicMetadata
        return [
            Double(metadata?.section.sortOrder ?? 0),
            metadata?.volumeOrder ?? .greatestFiniteMagnitude,
            metadata?.issueOrder ?? .greatestFiniteMagnitude,
            BookSortKeys.seriesNumber(book.seriesSequence),
        ]
    }
    let l = key(lhs)
    let r = key(rhs)
    if l != r { return l.lexicographicallyPrecedes(r) }
    let title = lhs.title.localizedStandardCompare(rhs.title)
    if title != .orderedSame { return title == .orderedAscending }
    return lhs.uniqueId < rhs.uniqueId
}

private extension LibrarySourceFilter {
    nonisolated func includes(_ book: Book) -> Bool {
        switch self {
        case .all: true
        case .device: book.source == .local || book.source == .smb
        case .connection(let id): book.providerId == id
        case .library(let providerId, let libraryId): book.providerId == providerId && book.libraryId == libraryId
        }
    }
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
    func beginReconciliation(libraryId: String, providerId: UUID) async throws -> ReconciliationStart
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
    @discardableResult
    func migrateAudiobookArtifacts(fromBookStableId: String, toBookStableId: String) async -> Bool

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
