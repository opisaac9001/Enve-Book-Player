import Combine
import Foundation
import Logging

enum AudiobookSeparationError: LocalizedError {
    case unsupported
    case sourceUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "This chapter is not backed by a separate local audio file."
        case .sourceUnavailable:
            return "The audiobook source is no longer available."
        }
    }
}

struct BookDetailSnapshot: Sendable {
    let book: Book
    let counterpart: Book?
    let inSeries: [Book]
    let workSummary: LibraryWorkSummary?
}

struct LibraryWorkSummary: Sendable {
    let key: String
    let editions: Int
    let sources: Int
}

struct HearthFeedSnapshot: Sendable {
    let listening: [Book]
    let reading: [Book]
    let fresh: [Book]
    let downloaded: [Book]
}

struct LibraryWorkIndexSnapshot: Sendable {
    let hiddenUniqueIds: Set<String>
    let representativeWorkKey: [String: String]
    let representativeCount: [String: Int]
}

struct BookSyncLibrarySnapshot: Sendable {
    let ebookCount: Int
    let ebooks: [Book]
}

struct RecentlyDeletedBookEntry: Identifiable, Sendable {
    let stableId: String
    let title: String
    let deletedAt: Date

    var id: String { stableId }
}

struct LibraryCollectionsOverview {
    let smart: [SmartCollection]
    let mine: [Collection]
    let server: [Collection]
    let smartPreviews: [String: (count: Int, book: Book?)]
    let memberPreviews: [String: Book]
}

struct CollectionEditorValues {
    let name: String
    let details: String
    let iconName: String
    let color: String
    let selectedImageData: Data?
    let rules: [SmartCollectionRule]
    let logicOperator: LogicOperator
}

struct BookOrbitCollectionMembership: Identifiable {
    let collection: Collection
    var containsBook: Bool

    var id: String { collection.id }
}

@MainActor
@Observable
final class LibraryEngine {
    private let appState: AppState
    private let catalog: LibraryCatalogCoordinator
    private let progressStore: UserProgressStore
    private let recovery: LibraryRecoveryCoordinator

    init(
        appState: AppState = .shared,
        catalog: LibraryCatalogCoordinator = .shared,
        progressStore: UserProgressStore = .shared,
        recovery: LibraryRecoveryCoordinator = .shared
    ) {
        self.appState = appState
        self.catalog = catalog
        self.progressStore = progressStore
        self.recovery = recovery
    }

    var isRefreshing: Bool {
        catalog.isRefreshing
    }

    func refreshLibrary() async {
        let signpost = PerfSignpost.begin("library-refresh")
        defer { PerfSignpost.end(signpost) }
        await catalog.refreshLibrary()
    }

    func detailSnapshot(for seed: Book, current: Book?) async -> BookDetailSnapshot {
        let shown = current ?? seed
        let fresh =
            await appState.bookStore.book(uniqueId: seed.uniqueId)
            ?? appState.bookInMemory(uniqueId: seed.uniqueId)
            ?? shown

        let counterpart: Book?
        switch fresh.mediaType {
        case .ebook:
            counterpart = await EbookAudiobookLinker.shared.linkedAudiobookAsync(for: fresh)
        case .audiobook:
            counterpart = await EbookAudiobookLinker.shared.linkedEbookAsync(for: fresh)
        case .podcast:
            counterpart = nil
        }

        let siblings: [Book]
        if let series = fresh.series {
            siblings = await appState.bookStore.books(inSeries: series).filter { $0.stableId != fresh.stableId }
        } else {
            siblings = []
        }

        return BookDetailSnapshot(
            book: fresh,
            counterpart: counterpart,
            inSeries: DetailSeriesOrder.sorted(siblings),
            workSummary: await workSummary(for: fresh)
        )
    }

    func canDownload(_ book: Book) -> Bool {
        guard book.source != .local else { return false }
        guard let provider = appState.getProvider(book.providerId) else { return true }
        return provider.capabilities.contains(.downloads)
    }

    func hasConnection(id: UUID) -> Bool {
        appState.providerConnections.connections.contains { $0.id == id }
    }

    func sourceConnection(for book: Book) -> ServerConnection? {
        appState.providerConnections.connections.first { $0.id == book.providerId }
    }

    func sourceConnection(for collection: Collection) -> ServerConnection? {
        guard let providerId = collection.providerId else { return nil }
        return appState.providerConnections.connections.first { $0.id == providerId }
    }

    func provider(for book: Book) -> LibraryProvider? {
        appState.getProvider(book.providerId)
    }

    func supportsPersonalRating(_ book: Book) -> Bool {
        appState.providerConnections.capability(PersonalRatingProvider.self, for: book)?.supportsPersonalRating == true
    }

    func setPersonalRating(_ rating: Int, for book: Book) async throws -> Book {
        guard let provider = appState.providerConnections.capability(PersonalRatingProvider.self, for: book),
            provider.supportsPersonalRating
        else {
            throw ProviderError.notImplemented
        }

        let normalized = min(max(rating, 1), 5)
        try await provider.updatePersonalRating(for: book, rating: normalized)

        if let updated = updateBook(
            uniqueId: book.uniqueId,
            {
                $0.personalRating = Double(normalized)
            }
        ) {
            notifyLibraryChanged()
            return updated
        }

        var updated = book
        updated.personalRating = Double(normalized)
        await appState.bookStore.upsertBooks([updated])
        notifyLibraryChanged()
        return updated
    }

    func updateBook(uniqueId: String, _ transform: (inout Book) -> Void) -> Book? {
        appState.mutateBook(uniqueId: uniqueId, transform)
    }

    func separateTrackIntoBook(_ track: AudioTrack, from book: Book) async throws {
        guard book.source == .local || book.source == .smb,
            let filePath = track.filePath,
            !filePath.isEmpty,
            let tracks = book.audioTracks,
            tracks.count > 1
        else {
            throw AudiobookSeparationError.unsupported
        }

        let sourceId = book.libraryId
        AudiobookGroupingOverrideStore.shared.forceStandalone(
            source: book.source,
            sourceId: sourceId,
            filePath: filePath
        )

        do {
            switch book.source {
            case .local:
                guard let library = LocalLibraryStorageStore.shared.loadLibraries().first(where: { $0.id == sourceId }) else {
                    throw AudiobookSeparationError.sourceUnavailable
                }
                let result = try await LocalLibraryService.shared.scanLibrary(library)
                LocalLibraryStorageStore.shared.saveScanResult(result)
                catalog.forceNextLocalRefresh = true
                await catalog.refreshLocalLibrariesFromUI()
            case .smb:
                guard let source = await SMBLibraryService.shared.getSources().first(where: { $0.id == sourceId }) else {
                    throw AudiobookSeparationError.sourceUnavailable
                }
                _ = try await SMBLibraryService.shared.scanLibrary(source, mode: .quick)
                let rebuilt = await SMBLibraryService.shared.getBooks(for: sourceId).map { $0.toBook() }
                await appState.bookStore.replaceLibrary(
                    books: rebuilt,
                    libraryId: sourceId,
                    providerId: rebuilt.first?.providerId ?? book.providerId,
                    allowSparseResult: false
                )
                notifyLibraryChanged()
            default:
                throw AudiobookSeparationError.unsupported
            }
        } catch {
            AudiobookGroupingOverrideStore.shared.removeForcedStandalone(
                source: book.source,
                sourceId: sourceId,
                filePath: filePath
            )
            throw error
        }
    }

    @discardableResult
    func resolveReadAloudIfUnknown(for book: Book) async -> Book? {
        guard book.mediaType == .ebook, book.epub3Features == nil,
            let provider = appState.getProvider(book.providerId) as? BookloreProvider,
            let features = await provider.fetchEPUB3Features(bookId: book.id)
        else { return nil }

        var updated = updateBook(uniqueId: book.uniqueId) { $0.epub3Features = features } ?? book
        updated.epub3Features = features
        await appState.bookStore.upsertBooks([updated])
        notifyLibraryChanged()
        return updated
    }

    func applyCurrentBookChapters(_ chapters: [Chapter], for book: Book) {
        var persistedBook = book
        persistedBook.chapters = chapters

        if let updated = appState.mutateBook(uniqueId: book.uniqueId, { $0.chapters = chapters }) {
            persistedBook = updated
        } else {
            Task(priority: .background) {
                await AppState.shared.bookStore.upsertBooks([persistedBook])
            }
        }

        updateActiveChapters(chapters, matching: book)
        catalog.saveMetadataChanges()
    }

    private func updateActiveChapters(_ chapters: [Chapter], matching book: Book) {
        if var active = appState.currentBook, isSameBook(active, book) {
            active.chapters = chapters
            appState.currentBook = active
        }

        ActivePlayback.composition.bookMetadataUpdater.updateChapters(chapters, for: book)

        PlayerViewModel.shared.refreshFromCurrentPlayback()
    }

    private func isSameBook(_ lhs: Book, _ rhs: Book) -> Bool {
        lhs.uniqueId == rhs.uniqueId || lhs.stableId == rhs.stableId || lhs.id == rhs.id
    }

    func notifyLibraryChanged() {
        appState.allBooksChanged.send(())
    }

    func toggleFinished(_ book: Book) -> Book {
        progressStore.toggleFinished(for: book)
        let observedAt = Date()
        var updated = book
        updated.isFinished.toggle()
        updated.currentTime = updated.isFinished ? (updated.duration ?? 0) : 0
        if updated.mediaType == .ebook {
            updated.ebookProgress = updated.isFinished ? 1 : 0
            updated.epubLocator = nil
        }
        updated.lastUpdate = observedAt
        Task {
            await LinkedBookProgressCoordinator.shared.setPairFinished(
                from: updated,
                finished: updated.isFinished,
                observedAt: observedAt
            )
        }
        return updated
    }

    func resetProgressToBeginning(for book: Book) {
        progressStore.resetToBeginning(for: book)
        Task {
            await LinkedBookProgressCoordinator.shared.resetPair(from: book)
        }
    }

    func hide(_ book: Book) async {
        recovery.removeBook(book)
        await appState.bookStore.setHidden(true, stableId: book.stableId)
    }

    func hideFromLibrary(_ books: [Book]) async {
        guard !books.isEmpty else { return }
        recovery.removeBooks(books)

        var preferences = LibraryDisplayPreferencesStore.shared.loadPreferences()
        for book in books {
            preferences.hiddenBookIds.insert(book.stableId)
            preferences.hiddenBookNames[book.stableId] = book.title
        }
        LibraryDisplayPreferencesStore.shared.savePreferences(preferences)

        for stableId in books.map(\.stableId) {
            await appState.bookStore.setHidden(true, stableId: stableId)
        }
    }

    func restoreHiddenBooks(stableIds: [String]) async {
        for stableId in stableIds {
            recovery.restoreDeletedBook(stableId)
            await appState.bookStore.setHidden(false, stableId: stableId)
            await appState.bookStore.setDeleted(false, stableId: stableId)
        }
    }

    func recentlyDeletedEntries() -> [RecentlyDeletedBookEntry] {
        DeletedBooksTombstoneStore.shared.allEntries.map {
            RecentlyDeletedBookEntry(stableId: $0.stableId, title: $0.title, deletedAt: $0.deletedAt)
        }
    }

    func restoreDeletedBooks(_ stableIds: [String]) async {
        await recovery.restoreDeletedBooks(stableIds)
    }

    func unlinkAudiobook(from ebook: Book) -> Book {
        if EbookAudiobookLinker.shared.linkedAudiobook(for: ebook) != nil {
            if #available(iOS 26.0, *) {
                StoryAlignService.shared.deleteConversions(involving: ebook)
            }
        }
        appState.mutateBook(uniqueId: ebook.uniqueId) {
            $0.linkedAudiobookStableId = nil
            $0.linkedAudiobookChapterOffset = 0
        }
        EbookLinkStore.shared.saveLinks()
        EbookAudiobookLinker.shared.invalidateCache()
        LinkedBookProgressCoordinator.shared.removeMapping(ebookStableId: ebook.stableId)
        Task {
            guard appState.bookInMemory(stableId: ebook.stableId)?.linkedAudiobookStableId == nil else {
                return
            }
            await appState.bookStore.removeLink(ebookStableId: ebook.stableId)
        }
        var updated = ebook
        updated.linkedAudiobookStableId = nil
        updated.linkedAudiobookChapterOffset = 0
        return updated
    }

    func linkAudiobook(_ audiobook: Book, to ebook: Book) async -> Bool {
        let updated = appState.mutateBook(uniqueId: ebook.uniqueId) {
            $0.linkedAudiobookStableId = audiobook.stableId
            $0.linkedAudiobookChapterOffset = 0
        }
        guard updated != nil else { return false }
        EbookLinkStore.shared.saveLinks()
        await appState.bookStore.upsertLink(
            ebookStableId: ebook.stableId,
            audiobookStableId: audiobook.stableId,
            chapterOffset: 0
        )
        EbookAudiobookLinker.shared.invalidateCache()
        LinkedBookProgressCoordinator.shared.removeMapping(ebookStableId: ebook.stableId)

        var linkedAudiobook = audiobook
        if linkedAudiobook.chapters?.isEmpty != false {
            await catalog.refreshBookDetails(for: audiobook)
            linkedAudiobook = appState.bookInMemory(stableId: audiobook.stableId) ?? audiobook
        }

        guard let linkedEbook = appState.bookInMemory(uniqueId: ebook.uniqueId) else { return true }
        if let ebookChapters = await EbookChapterSyncService.shared.extractEbookChapters(for: linkedEbook) {
            let offset =
                EbookChapterSyncService.shared.recommendedOffset(
                    ebookChapters: ebookChapters,
                    audiobookChapters: linkedAudiobook.chapters
                ) ?? 0
            if offset != 0 {
                appState.mutateBook(uniqueId: ebook.uniqueId) {
                    $0.linkedAudiobookChapterOffset = offset
                }
                EbookLinkStore.shared.saveLinks()
                await appState.bookStore.upsertLink(
                    ebookStableId: ebook.stableId,
                    audiobookStableId: audiobook.stableId,
                    chapterOffset: offset
                )
                EbookAudiobookLinker.shared.invalidateCache()
            }

            if let synced = EbookChapterSyncService.shared.syncChaptersIfPossible(
                ebookChapters: ebookChapters,
                audiobookChapters: linkedAudiobook.chapters,
                offset: offset
            ) {
                appState.mutateBook(uniqueId: ebook.uniqueId) { $0.chapters = synced }
                ReaderArtifactsStore.shared.saveCachedChapters(bookId: linkedEbook.stableId, chapters: synced)
                if linkedEbook.id != linkedEbook.stableId {
                    ReaderArtifactsStore.shared.saveCachedChapters(bookId: linkedEbook.id, chapters: synced)
                }
            }
        }

        await LinkedBookProgressCoordinator.shared.reconcilePair(for: linkedEbook)
        return true
    }

    func permanentlyDelete(_ book: Book) {
        recovery.permanentlyDeleteBook(book)
    }

    func book(stableId: String) async -> Book? {
        await appState.bookStore.book(stableId: stableId)
    }

    func readAloudSourceBook(stableId: String) async -> Book? {
        await appState.bookStore.book(stableId: stableId)
            ?? appState.bookInMemory(stableId: stableId)
    }

    func totalBookCount() async -> Int {
        await appState.bookStore.bookCount()
    }

    func bookCount(mediaType: String?) async -> Int {
        if let mediaType {
            await appState.bookStore.bookCount(mediaType: mediaType)
        } else {
            await appState.bookStore.bookCount()
        }
    }

    func bookCount(sourceFilter: LibrarySourceFilter, mediaType: String?) async -> Int {
        if mediaType == nil, let remote = remoteBrowse(sourceFilter),
            let count = try? await remote.provider.remoteBookCount(libraryId: remote.libraryId)
        {
            RemoteLibraryBrowseStore.shared.record(
                providerId: remote.provider.connection.id,
                libraryId: remote.libraryId,
                bookCount: count
            )
            return count
        }
        switch sourceFilter {
        case .all, .device:
            return await bookCount(mediaType: mediaType)
        case let .connection(providerId):
            return await appState.bookStore.bookCount(providerId: providerId, mediaType: mediaType)
        case let .library(providerId, libraryId):
            return await appState.bookStore.bookCount(libraryId: libraryId, providerId: providerId)
        }
    }

    func searchBooks(query: String, sourceFilter: LibrarySourceFilter, limit: Int) async -> [Book] {
        if let remote = remoteBrowse(sourceFilter),
            let results = try? await remote.provider.remoteSearchBooks(
                libraryId: remote.libraryId,
                query: query,
                limit: limit
            )
        {
            return await mergingStoredRecords(results)
        }
        switch sourceFilter {
        case let .library(providerId, libraryId):
            return await appState.bookStore.searchBooks(query: query, libraryId: libraryId, providerId: providerId, limit: limit)
        case .all, .device, .connection:
            return await appState.bookStore.searchBooks(query: query, limit: limit)
        }
    }

    func usesRemoteBrowsing(sourceFilter: LibrarySourceFilter) -> Bool {
        remoteBrowse(sourceFilter) != nil
    }

    private func remoteBrowse(_ sourceFilter: LibrarySourceFilter) -> (provider: BookloreProvider, libraryId: String)? {
        guard case let .library(providerId, libraryId) = sourceFilter,
            RemoteLibraryBrowseStore.shared.isRemoteBrowsed(providerId: providerId, libraryId: libraryId),
            let provider = appState.getProvider(providerId) as? BookloreProvider,
            provider.supportsRemoteBrowsing
        else { return nil }
        return (provider, libraryId)
    }

    private func mergingStoredRecords(_ remote: [Book]) async -> [Book] {
        guard !remote.isEmpty else { return [] }
        let suppressed = DeletedBooksTombstoneStore.shared.allDeleted
            .union(LibraryDisplayPreferencesStore.shared.loadPreferences().hiddenBookIds)
        let stored = await appState.bookStore.booksByUniqueIds(Set(remote.map(\.uniqueId)))
        return remote.compactMap { book in
            guard !suppressed.contains(book.stableId) else { return nil }
            return stored[book.uniqueId] ?? book
        }
    }

    private static func remoteSort(for sort: [BookStoreSortDescriptor]) -> (field: GrimmoryRemoteSort, descending: Bool)? {
        guard sort.count == 1, let descriptor = sort.first else { return nil }
        let field: GrimmoryRemoteSort
        switch descriptor.field {
        case .recent: field = .addedOn
        case .recentlyRead: field = .lastReadTime
        case .title: field = .title
        default: return nil
        }
        return (field, descriptor.direction == .descending)
    }

    func matchesStatus(_ book: Book, status: LibraryStatusFilter, downloadedIds: Set<String>) -> Bool {
        switch status {
        case .all:
            return true
        case .listening:
            return !book.isFinished && book.currentTime > 0
                && statusAllowsContinue(book)
                && (book.mediaType != .ebook || book.readAloudSourceStableId != nil)
        case .reading:
            return !book.isFinished
                && statusAllowsContinue(book)
                && book.mediaType == .ebook
                && book.canonicalEbookProgress > 0.001
        case .finished:
            return book.isFinished
        case .downloaded:
            if book.mediaType == .ebook {
                return LibraryBookActions.hasPermanentEbookDownload(book)
            }
            return downloadedIds.contains(book.stableId)
                && EnveEngine.shared.downloads.isAudiobookDownloaded(book)
        }
    }

    private func statusAllowsContinue(_ book: Book) -> Bool {
        guard book.source == .booklore, let status = book.serverReadStatus else { return true }
        return status == "READING" || status == "RE_READING"
    }

    func filterStatus(_ books: [Book], status: LibraryStatusFilter, downloadedIds: Set<String>) -> [Book] {
        books.filter { matchesStatus($0, status: status, downloadedIds: downloadedIds) }
    }

    nonisolated func applySort(_ books: [Book], descriptors: [LibrarySortDescriptor]) -> [Book] {
        let descriptors =
            descriptors.isEmpty
            ? [LibrarySortDescriptor(field: .recent, direction: .descending)]
            : descriptors
        return books.sorted { lhs, rhs in
            for descriptor in descriptors {
                let lhsMissing = missingSortValue(lhs, sort: descriptor.field)
                let rhsMissing = missingSortValue(rhs, sort: descriptor.field)
                if lhsMissing != rhsMissing {
                    return !lhsMissing
                }
                let comparison = sortComparison(lhs, rhs, sort: descriptor.field)
                if comparison != .orderedSame {
                    return descriptor.direction == .ascending
                        ? comparison == .orderedAscending
                        : comparison == .orderedDescending
                }
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private nonisolated func missingSortValue(_ book: Book, sort: LibrarySort) -> Bool {
        switch sort {
        case .recent:
            return book.addedAt == nil
        case .recentlyRead:
            return book.currentTime <= 0 && book.canonicalEbookProgress <= 0.001
        case .title:
            return book.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .author, .authorSurname:
            return book.author?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        case .narrator, .narratorSurname:
            return book.narrator?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        case .series:
            return book.series?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        case .progress:
            return false
        case .duration:
            return book.duration == nil
        case .year:
            return book.publishedYear == nil
        case .goodreadsRating:
            return book.personalRating == nil && book.goodreadsRating == nil
        }
    }

    private nonisolated func sortComparison(_ lhs: Book, _ rhs: Book, sort: LibrarySort) -> ComparisonResult {
        switch sort {
        case .recent:
            return compare(lhs.addedAt ?? .distantPast, rhs.addedAt ?? .distantPast)
        case .recentlyRead:
            return compare(lhs.lastUpdate, rhs.lastUpdate)
        case .title:
            return lhs.title.localizedStandardCompare(rhs.title)
        case .author:
            return compareName(lhs.author, rhs.author, style: .given)
        case .authorSurname:
            return compareName(lhs.author, rhs.author, style: .surname)
        case .narrator:
            return compareName(lhs.narrator, rhs.narrator, style: .given)
        case .narratorSurname:
            return compareName(lhs.narrator, rhs.narrator, style: .surname)
        case .series:
            let series = compareText(lhs.series, rhs.series)
            if series != .orderedSame { return series }
            return compare(BookSortKeys.seriesNumber(lhs.seriesSequence), BookSortKeys.seriesNumber(rhs.seriesSequence))
        case .progress:
            return compare(lhs.progressPercentage, rhs.progressPercentage)
        case .duration:
            return compare(lhs.duration ?? 0, rhs.duration ?? 0)
        case .year:
            return compare(lhs.publishedYear ?? 0, rhs.publishedYear ?? 0)
        case .goodreadsRating:
            return compare(
                max(lhs.personalRating ?? 0, lhs.goodreadsRating ?? 0),
                max(rhs.personalRating ?? 0, rhs.goodreadsRating ?? 0)
            )
        }
    }

    private nonisolated func compareText(_ lhs: String?, _ rhs: String?) -> ComparisonResult {
        let left = lhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let right = rhs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return compare(BookSortKeys.text(left), BookSortKeys.text(right))
    }

    private enum NameSortStyle {
        case given, surname
    }

    private nonisolated func compareName(
        _ lhs: String?,
        _ rhs: String?,
        style: NameSortStyle
    ) -> ComparisonResult {
        let keyStyle: BookSortKeys.NameStyle =
            switch style {
            case .given: .given
            case .surname: .surname
            }
        return compare(BookSortKeys.name(lhs, style: keyStyle), BookSortKeys.name(rhs, style: keyStyle))
    }

    private nonisolated func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    func pagedBooks(sourceFilter: LibrarySourceFilter, mediaType: String?, offset: Int, limit: Int) async -> [Book] {
        switch sourceFilter {
        case let .library(providerId, libraryId):
            await appState.bookStore.pagedBooks(libraryId: libraryId, providerId: providerId, offset: offset, limit: limit)
        case .all, .device, .connection:
            await appState.bookStore.pagedBooks(offset: offset, limit: limit, mediaType: mediaType)
        }
    }

    func pagedBooks(sourceFilter: LibrarySourceFilter, mediaType: String?, after cursor: Book?, limit: Int) async -> [Book] {
        switch sourceFilter {
        case let .library(providerId, libraryId):
            await appState.bookStore.pagedBooks(libraryId: libraryId, providerId: providerId, after: cursor, limit: limit)
        case let .connection(providerId):
            await appState.bookStore.pagedBooks(providerId: providerId, after: cursor, limit: limit, mediaType: mediaType)
        case .all, .device:
            await appState.bookStore.pagedBooks(after: cursor, limit: limit, mediaType: mediaType)
        }
    }

    func sortedPagedBooks(
        sourceFilter: LibrarySourceFilter,
        mediaType: String?,
        offset: Int,
        limit: Int,
        sort: [BookStoreSortDescriptor]
    ) async -> [Book] {
        if mediaType == nil, let remote = remoteBrowse(sourceFilter),
            let remoteSort = Self.remoteSort(for: sort),
            let page = try? await remote.provider.remoteBooksPage(
                libraryId: remote.libraryId,
                offset: offset,
                limit: limit,
                sort: remoteSort.field,
                descending: remoteSort.descending
            )
        {
            return await mergingStoredRecords(page.books)
        }
        switch sourceFilter {
        case let .library(providerId, libraryId):
            return await appState.bookStore.sortedPagedBooks(
                libraryId: libraryId,
                providerId: providerId,
                offset: offset,
                limit: limit,
                mediaType: mediaType,
                sort: sort
            )
        case let .connection(providerId):
            return await appState.bookStore.sortedPagedBooks(
                providerId: providerId,
                offset: offset,
                limit: limit,
                mediaType: mediaType,
                sort: sort
            )
        case .all, .device:
            return await appState.bookStore.sortedPagedBooks(offset: offset, limit: limit, mediaType: mediaType, sort: sort)
        }
    }

    func largeSourceCount(sourceFilter: LibrarySourceFilter, mediaType: String?, threshold: Int) async -> Int? {
        let count = await bookCount(sourceFilter: sourceFilter, mediaType: mediaType)
        return count > threshold ? count : nil
    }

    func sourceScopedBooks(sourceFilter: LibrarySourceFilter, mediaTypes: [String], limitPerMediaType: Int? = nil) async -> [Book] {
        var result: [Book] = []
        switch sourceFilter {
        case .all:
            for raw in mediaTypes {
                let count = await appState.bookStore.bookCount(mediaType: raw)
                result.append(
                    contentsOf: await appState.bookStore.pagedBooks(
                        offset: 0,
                        limit: limitPerMediaType ?? max(count, 1),
                        mediaType: raw
                    )
                )
            }
        case .device:
            for raw in mediaTypes {
                result.append(
                    contentsOf: await appState.bookStore.firstBooks(
                        source: Book.BookSource.local.rawValue,
                        mediaType: raw,
                        limit: limitPerMediaType ?? 10000
                    )
                )
                result.append(
                    contentsOf: await appState.bookStore.firstBooks(
                        source: Book.BookSource.smb.rawValue,
                        mediaType: raw,
                        limit: limitPerMediaType ?? 10000
                    )
                )
            }
        case let .connection(providerId):
            for raw in mediaTypes {
                let count = await appState.bookStore.bookCount(providerId: providerId, mediaType: raw)
                result.append(
                    contentsOf: await appState.bookStore.pagedBooks(
                        providerId: providerId,
                        after: nil,
                        limit: limitPerMediaType ?? max(count, 1),
                        mediaType: raw
                    )
                )
            }
        case let .library(providerId, libraryId):
            let count = await appState.bookStore.bookCount(libraryId: libraryId, providerId: providerId)
            result.append(
                contentsOf: await appState.bookStore.pagedBooks(
                    libraryId: libraryId,
                    providerId: providerId,
                    offset: 0,
                    limit: limitPerMediaType ?? max(count, 1)
                )
            )
        }

        var seen = Set<String>()
        let allowedMedia = Set(mediaTypes)
        return result.filter { book in
            seen.insert(book.uniqueId).inserted && allowedMedia.contains(book.mediaType.rawValue)
        }
    }

    func continueListeningBooks(limit: Int) async -> [Book] {
        let persisted = await appState.bookStore.continueListeningBooks(limit: limit)
        let recentStableIds = Set(
            BookProgressStore.shared.loadSnapshots()
                .filter { $0.book.mediaType == .audiobook }
                .map(\.stableId)
        )
        guard !recentStableIds.isEmpty else { return persisted }

        let recentBooks = await appState.bookStore.booksByStableIds(recentStableIds).values.compactMap { book -> Book? in
            guard !book.isFinished, !book.hideFromContinue,
                let progress = BookProgressStore.shared.loadProgress(for: book),
                progress.progress > 0,
                book.duration.map({ progress.progress < $0 * 0.99 }) ?? true
            else {
                return nil
            }
            var updated = book
            updated.currentTime = progress.progress
            updated.lastUpdate = Date(timeIntervalSince1970: progress.lastUpdated)
            return updated
        }

        var seen = Set<String>()
        return Array(
            (persisted + recentBooks)
                .sorted { $0.lastUpdate > $1.lastUpdate }
                .filter { seen.insert($0.stableId).inserted }
                .prefix(limit)
        )
    }

    func continueReadingBooks(limit: Int) async -> [Book] {
        await appState.bookStore.continueReadingBooks(limit: limit)
    }

    func recentBooks(limit: Int) async -> [Book] {
        await appState.bookStore.recentBooks(limit: limit)
    }

    func recentHearthBooks(limit: Int) async -> [Book] {
        let audiobooks = await appState.bookStore.recentBooks(limit: limit)
        let ebooks = await appState.bookStore.recentEbooks(limit: limit)
        var seen = Set<String>()
        return Array(
            (audiobooks + ebooks)
                .sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
                .filter { seen.insert($0.stableId).inserted }
                .prefix(limit)
        )
    }

    func hearthFeed(dismissedStableIds: Set<String>, currentStableId: String?) async -> HearthFeedSnapshot {
        let listening = deduplicatedHomeBooks(
            await continueListeningBooks(limit: 16),
            dismissedStableIds: dismissedStableIds,
            currentStableId: currentStableId
        )
        let reading = deduplicatedHomeBooks(
            await continueReadingBooks(limit: 16),
            dismissedStableIds: dismissedStableIds,
            currentStableId: currentStableId
        )
        return HearthFeedSnapshot(
            listening: listening,
            reading: reading,
            fresh: await recentHearthBooks(limit: 12),
            downloaded: await homeDownloadedBooks(limit: 16)
        )
    }

    func firstBooks(mediaType: String, limit: Int) async -> [Book] {
        await appState.bookStore.firstBooks(mediaType: mediaType, limit: limit)
    }

    func firstBooks(source: String, mediaType: String, limit: Int) async -> [Book] {
        await appState.bookStore.firstBooks(source: source, mediaType: mediaType, limit: limit)
    }

    func firstBooks(mediaTypes: [String], limitPerMediaType: Int) async -> [Book] {
        var books: [Book] = []
        for mediaType in mediaTypes {
            books += await firstBooks(mediaType: mediaType, limit: limitPerMediaType)
        }
        return books
    }

    func firstBooks(source: String, mediaTypes: [String], limitPerMediaType: Int) async -> [Book] {
        var books: [Book] = []
        for mediaType in mediaTypes {
            books += await firstBooks(source: source, mediaType: mediaType, limit: limitPerMediaType)
        }
        return books
    }

    func booksMatching(_ collection: SmartCollection, limit: Int?) async -> [Book] {
        await appState.bookStore.booksMatching(collection, limit: limit)
    }

    func currentCollection(for seed: Collection) -> Collection {
        UserCollectionStore.shared.collections.first { $0.id == seed.id }
            ?? catalog.collections.first { $0.id == seed.id && $0.providerId == seed.providerId }
            ?? seed
    }

    @discardableResult
    func addBooks(_ books: [Book], to collection: Collection) -> Int {
        let current = currentCollection(for: collection)
        guard current.isUserGenerated else { return 0 }

        var memberIDs = current.books
        var seen = Set(memberIDs)
        let additions = books.map(\.id).filter { seen.insert($0).inserted }
        guard !additions.isEmpty else { return 0 }
        memberIDs.append(contentsOf: additions)

        UserCollectionStore.shared.save(
            Collection(
                id: current.id,
                name: current.name,
                description: current.description,
                books: memberIDs,
                bookCount: memberIDs.count,
                iconName: current.iconName,
                color: current.color,
                providerId: current.providerId,
                parentID: current.parentID,
                customCoverPath: current.customCoverPath,
                isSystem: current.isSystem,
                isUserGenerated: true,
                remoteId: current.remoteId,
                serverIcon: current.serverIcon,
                syncToKobo: current.syncToKobo,
                displayOrder: current.displayOrder,
                isServerEditable: current.isServerEditable
            )
        )
        return additions.count
    }

    func createCollection(named name: String, books: [Book]) -> Collection? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var seen = Set<String>()
        let memberIDs = books.map(\.id).filter { seen.insert($0).inserted }
        let collection = Collection(
            id: UUID().uuidString,
            name: name,
            description: nil,
            books: memberIDs,
            bookCount: memberIDs.count,
            iconName: "books.vertical.fill",
            color: "orange",
            providerId: nil,
            isUserGenerated: true
        )
        UserCollectionStore.shared.save(collection)
        return collection
    }

    func currentSmartCollection(for seed: SmartCollection) -> SmartCollection {
        SmartCollectionStore.shared.merged.first { $0.id == seed.id } ?? seed
    }

    func collectionsOverview() async -> LibraryCollectionsOverview {
        let smart = SmartCollectionStore.shared.merged
        let mine = UserCollectionStore.shared.collections
        let server = catalog.collections.filter { !$0.isUserGenerated }

        var smartPreviews: [String: (count: Int, book: Book?)] = [:]
        for collection in smart {
            let count = await appState.bookStore.bookCountMatching(collection)
            let book = await appState.bookStore.booksMatching(collection, limit: 1).first
            smartPreviews[collection.id] = (count, book)
        }

        var memberPreviews: [String: Book] = [:]
        for collection in mine + server where !collection.books.isEmpty {
            if let first = await mirroredCollectionBooks(collection, limit: 5).first {
                memberPreviews[collection.scopedID] = first
            }
        }

        return LibraryCollectionsOverview(
            smart: smart,
            mine: mine,
            server: server,
            smartPreviews: smartPreviews,
            memberPreviews: memberPreviews
        )
    }

    private func saveCollectionCover(id: String, data: Data) -> String? {
        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let filename = "collection_cover_\(id).jpg"
        let fileURL = documentsDirectory.appendingPathComponent(filename)

        do {
            try data.write(to: fileURL, options: .atomic)
            return fileURL.path
        } catch {
            AppLogger.general.error("Error saving collection cover: \(error)")
            return nil
        }
    }

    func saveCollection(collection: Collection?, smartCollection: SmartCollection?, isSmart: Bool, values: CollectionEditorValues) {
        let id = collection?.id ?? smartCollection?.id ?? UUID().uuidString
        var coverPath = collection?.customCoverPath ?? smartCollection?.customCoverPath
        if let data = values.selectedImageData {
            coverPath = saveCollectionCover(id: id, data: data)
        }

        let trimmedName = values.name.trimmingCharacters(in: .whitespaces)
        let trimmedDetails = values.details.trimmingCharacters(in: .whitespaces)

        if isSmart {
            let updated = SmartCollection(
                id: id,
                name: trimmedName,
                description: trimmedDetails.isEmpty ? nil : trimmedDetails,
                rules: SmartCollectionRuleGroup(logicOperator: values.logicOperator, rules: values.rules),
                iconName: values.iconName,
                color: values.color,
                isSystem: smartCollection?.isSystem ?? false,
                sortOrder: smartCollection?.sortOrder ?? 100,
                parentID: smartCollection?.parentID,
                customCoverPath: coverPath
            )
            SmartCollectionStore.shared.save(updated)
        } else {
            let updated = Collection(
                id: id,
                name: trimmedName,
                description: trimmedDetails.isEmpty ? nil : trimmedDetails,
                books: collection?.books ?? [],
                bookCount: collection?.bookCount ?? 0,
                iconName: values.iconName,
                color: values.color,
                providerId: collection?.providerId,
                parentID: collection?.parentID,
                customCoverPath: coverPath,
                isSystem: collection?.isSystem ?? false,
                isUserGenerated: true
            )
            UserCollectionStore.shared.save(updated)
        }
    }

    func deleteCollection(collection: Collection?, smartCollection: SmartCollection?) {
        if let smartCollection {
            SmartCollectionStore.shared.delete(smartCollection)
        } else if let collection {
            UserCollectionStore.shared.delete(collection)
        }
    }

    func books(in collection: Collection) async -> [Book] {
        if let provider = bookOrbitProvider(for: collection), let remoteId = collection.remoteId {
            return (try? await provider.fetchCollectionBooks(collectionId: remoteId, page: 0, size: 100).books) ?? []
        }
        return await mirroredCollectionBooks(collection)
    }

    private func mirroredCollectionBooks(_ collection: Collection, limit: Int? = nil) async -> [Book] {
        let ids = limit.map { Array(collection.books.prefix($0)) } ?? collection.books
        guard !ids.isEmpty else { return [] }

        guard let providerId = collection.providerId else {
            let map = await appState.bookStore.booksByIds(Set(ids))
            return ids.compactMap { map[$0] }
        }

        let uniqueIds = ids.map { "\(providerId)_\($0)" }
        let map = await appState.bookStore.booksByAnyIds(Set(uniqueIds))
        return zip(ids, uniqueIds).compactMap { id, uniqueId in
            guard let book = map[uniqueId], book.providerId == providerId, book.id == id else {
                return nil
            }
            return book
        }
    }

    func bookOrbitCollectionPage(
        _ collection: Collection,
        page: Int,
        size: Int = 60,
        query: String? = nil
    ) async throws -> BookOrbitProvider.CollectionPage {
        guard let provider = bookOrbitProvider(for: collection), let remoteId = collection.remoteId else {
            throw ProviderError.invalidResponse
        }
        return try await provider.fetchCollectionBooks(collectionId: remoteId, page: page, size: size, query: query)
    }

    func bookOrbitAdminConnections() async -> [ServerConnection] {
        var result: [ServerConnection] = []
        for connection in appState.providerConnections.connections where connection.type == .bookOrbit && connection.isConnected && !connection.isArchived {
            if let provider = appState.getProvider(connection.id) as? BookOrbitProvider,
                (try? await provider.currentUserIsAdmin()) == true
            {
                result.append(connection)
            }
        }
        return result
    }

    func saveBookOrbitCollection(
        connectionId: UUID,
        collection: Collection?,
        edit: BookOrbitProvider.CollectionEdit
    ) async throws {
        guard let provider = appState.getProvider(connectionId) as? BookOrbitProvider else {
            throw ProviderError.invalidResponse
        }
        if let remoteId = collection?.remoteId {
            _ = try await provider.updateCollection(id: remoteId, edit: edit)
        } else {
            _ = try await provider.createCollection(edit)
        }
        try await refreshBookOrbitCollections(providerId: connectionId)
    }

    func deleteBookOrbitCollection(_ collection: Collection) async throws {
        guard let provider = bookOrbitProvider(for: collection), let remoteId = collection.remoteId else {
            throw ProviderError.invalidResponse
        }
        try await provider.deleteCollection(id: remoteId)
        try await refreshBookOrbitCollections(providerId: provider.connection.id)
    }

    func reorderBookOrbitCollections(_ collections: [Collection]) async throws {
        guard let first = collections.first, let provider = bookOrbitProvider(for: first) else { return }
        try await provider.reorderCollections(collections.compactMap(\.remoteId))
        try await refreshBookOrbitCollections(providerId: provider.connection.id)
    }

    func bookOrbitMemberships(for book: Book) async throws -> [BookOrbitCollectionMembership] {
        guard let provider = appState.getProvider(book.providerId) as? BookOrbitProvider else { return [] }
        guard try await provider.currentUserIsAdmin() else { return [] }
        return try await provider.collectionsContaining(bookId: book.id).map {
            BookOrbitCollectionMembership(collection: $0.collection, containsBook: $0.containsBook)
        }
    }

    func canManageBookOrbitCollections(for book: Book) async -> Bool {
        guard let provider = appState.getProvider(book.providerId) as? BookOrbitProvider else { return false }
        return (try? await provider.currentUserIsAdmin()) == true
    }

    func setBookOrbitMembership(_ containsBook: Bool, book: Book, collection: Collection) async throws {
        guard let provider = bookOrbitProvider(for: collection), let remoteId = collection.remoteId else {
            throw ProviderError.invalidResponse
        }
        if containsBook {
            try await provider.addBooks([book.id], toCollection: remoteId)
        } else {
            try await provider.removeBooks([book.id], fromCollection: remoteId)
        }
        try await refreshBookOrbitCollections(providerId: provider.connection.id)
    }

    func removeBookOrbitBook(_ book: Book, from collection: Collection) async throws {
        try await setBookOrbitMembership(false, book: book, collection: collection)
    }

    private func bookOrbitProvider(for collection: Collection) -> BookOrbitProvider? {
        guard let providerId = collection.providerId else { return nil }
        return appState.getProvider(providerId) as? BookOrbitProvider
    }

    private func refreshBookOrbitCollections(providerId: UUID) async throws {
        guard let provider = appState.getProvider(providerId) as? BookOrbitProvider else { return }
        let refreshed = try await provider.fetchCollections(libraryId: nil)
        catalog.commitServerCollectionSnapshot(refreshed, from: provider)
    }

    func observedBooks(matching collection: SmartCollection) -> AsyncStream<[Book]> {
        let store = appState.bookStore
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                for await books in store.observe(.matching(collectionId: collection.id, payload: collection)) {
                    continuation.yield(books)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func searchBooks(query: String, limit: Int) async -> [Book] {
        await appState.bookStore.searchBooks(query: query, limit: limit)
    }

    func titleAuthorPairs() async -> [(title: String, author: String)] {
        await appState.bookStore.titleAuthorPairs()
    }

    func detailBooks(author name: String) async -> [Book] {
        var seen = Set<String>()
        var merged: [Book] = []
        for mediaType in ["audiobook", "ebook", "podcast"] {
            for book in await appState.bookStore.books(byAuthor: name, mediaType: mediaType, limit: 500)
            where seen.insert(book.stableId).inserted {
                merged.append(book)
            }
        }
        return DetailSeriesOrder.sorted(merged)
    }

    func detailBooks(series name: String) async -> [Book] {
        DetailSeriesOrder.sorted(await appState.bookStore.books(inSeries: name))
    }

    func libraryChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                for await _ in NotificationCenter.default.notifications(named: .bookStoreDidChange).map({ _ in () }) {
                    continuation.yield(())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func downloadedEbooks(limit: Int) async -> [Book] {
        await appState.bookStore.downloadedEbooks(limit: limit)
    }

    func bookSyncSnapshots(limit: Int) -> AsyncStream<BookSyncLibrarySnapshot> {
        let store = appState.bookStore
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                for await (count, books) in store.observe({
                    async let count = store.bookCount(mediaType: "ebook")
                    async let books = store.firstBooks(mediaType: "ebook", limit: limit)
                    return await (count, books)
                }) {
                    continuation.yield(BookSyncLibrarySnapshot(ebookCount: count, ebooks: books))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func observedBooks(mediaType: String) -> AsyncStream<[Book]> {
        let store = appState.bookStore
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                for await books in store.observe(.mediaType(mediaType)) {
                    continuation.yield(books)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func books(source: String, providerId: UUID) async -> [Book] {
        await appState.bookStore.books(source: source, providerId: providerId)
    }

    func refreshDetails(for book: Book) async -> Book {
        await catalog.refreshBookDetails(for: book)
        return appState.bookInMemory(uniqueId: book.uniqueId) ?? book
    }

    func removeLocalEbookDebugImports(limit: Int) async {
        let ids = Set(
            (await firstBooks(mediaType: "ebook", limit: limit))
                .filter { $0.source == .local }
                .map(\.uniqueId)
        )
        guard !ids.isEmpty else { return }
        await appState.bookStore.deleteBooks(uniqueIds: ids)
        NotificationCenter.default.post(name: .bookStoreDidChange, object: nil)
    }

    func downloadedBooks(audioStableIds: Set<String>, ebookLimit: Int) async -> [Book] {
        var list = Array((await appState.bookStore.booksByStableIds(audioStableIds)).values)
        var seen = Set(list.map(\.stableId))
        for book in await appState.bookStore.downloadedEbooks(limit: ebookLimit) where seen.insert(book.stableId).inserted {
            list.append(book)
        }
        return list
    }

    func homeDownloadedBooks(limit: Int) async -> [Book] {
        let ebooks = await appState.bookStore.downloadedEbooks(limit: limit)
        let storage = LocalStorageManager.shared
        let downloadedIds = await Task.detached(priority: .userInitiated) {
            Set(storage.downloadedAudiobookIds())
        }.value
        let audiobooks = appState.allBooks.filter {
            $0.mediaType == .audiobook && storage.isAudiobookDownloaded($0, downloadedIds: downloadedIds)
        }
        var seen = Set<String>()
        return Array(
            (ebooks + audiobooks)
                .sorted { $0.lastUpdate > $1.lastUpdate }
                .filter { seen.insert($0.stableId).inserted }
                .prefix(limit)
        )
    }

    private func deduplicatedHomeBooks(
        _ books: [Book],
        dismissedStableIds: Set<String>,
        currentStableId: String?
    ) -> [Book] {
        var seen = Set<String>()
        var results: [Book] = []
        for book in books {
            guard !dismissedStableIds.contains(book.stableId) || book.stableId == currentStableId else { continue }
            if seen.insert(book.stableId).inserted {
                results.append(book)
            }
        }
        return results
    }

    func workSlices() async -> [WorkSlice] {
        await appState.bookStore.workSlices()
    }

    func workIndex() async -> LibraryWorkIndexSnapshot {
        let index = WorkGrouping.index(await workSlices())
        return LibraryWorkIndexSnapshot(
            hiddenUniqueIds: index.hiddenUniqueIds,
            representativeWorkKey: index.representativeWorkKey,
            representativeCount: index.representativeCount
        )
    }

    func workView(workKey key: String) async -> WorkView? {
        let overrides = WorkOverrideStore.shared
        var members = await appState.bookStore.books(workKey: key)
        for id in overrides.stableIdsMerged(into: key) {
            if let extra = await appState.bookStore.book(stableId: id) {
                members.append(extra)
            }
        }

        var seen = Set<String>()
        let resolved = members.filter { member in
            guard seen.insert(member.uniqueId).inserted else { return false }
            return overrides.effectiveWorkKey(stableId: member.stableId, computed: WorkIdentity.workKey(for: member)) == key
        }
        return WorkGrouping.makeWorkView(workKey: key, members: resolved)
    }

    func splitWorkSource(stableId: String) {
        WorkOverrideStore.shared.split(stableId: stableId)
        NotificationCenter.default.post(name: .bookStoreDidChange, object: nil)
    }

    func workMergeSuggestions(limit: Int) async -> [WorkMergeSuggestion] {
        let books = await appState.bookStore.booksWithIdentifiers(limit: limit)
        return WorkSuggestions.identifierSuggestions(from: books)
    }

    func confirmWorkMergeSuggestion(_ suggestion: WorkMergeSuggestion) {
        WorkOverrideStore.shared.merge(stableIds: suggestion.stableIds, intoComputedWorkKey: suggestion.targetWorkKey)
        NotificationCenter.default.post(name: .bookStoreDidChange, object: nil)
    }

    func dismissWorkMergeSuggestion(_ suggestion: WorkMergeSuggestion) {
        WorkOverrideStore.shared.dismissSuggestion(id: suggestion.id)
    }

    func seriesAggregates(mediaScope: [String]) async -> [BrowseSeriesAggregate] {
        var bucket: [String: (count: Int, completedCount: Int, thumb: String?, matchingNames: Set<String>)] = [:]
        for raw in mediaScope {
            for aggregate in await appState.bookStore.browseSeriesAggregates(mediaType: raw) {
                var entry = bucket[aggregate.name] ?? (0, 0, nil, [])
                entry.count += aggregate.bookCount
                entry.completedCount += aggregate.completedBookCount
                if entry.thumb == nil { entry.thumb = aggregate.representativeThumb }
                entry.matchingNames.formUnion(aggregate.matchingNames)
                bucket[aggregate.name] = entry
            }
        }
        return
            bucket
            .map {
                BrowseSeriesAggregate(
                    name: $0.key,
                    bookCount: $0.value.count,
                    completedBookCount: $0.value.completedCount,
                    representativeThumb: $0.value.thumb,
                    matchingNames: $0.value.matchingNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func seriesAggregates(from books: [Book]) -> [BrowseSeriesAggregate] {
        struct Acc {
            var count = 0
            var completedCount = 0
            var thumb: String?
            var matchingNames = Set<String>()
        }

        var bucket: [String: Acc] = [:]
        for book in books {
            guard let raw = book.series?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            let displayName = NameNormalizer.normalizeSeriesName(raw)
            var acc = bucket[displayName, default: Acc()]
            acc.count += 1
            if book.isCompleted { acc.completedCount += 1 }
            acc.matchingNames.insert(raw)
            if acc.thumb == nil { acc.thumb = book.thumb }
            bucket[displayName] = acc
        }

        return
            bucket
            .map {
                BrowseSeriesAggregate(
                    name: $0.key,
                    bookCount: $0.value.count,
                    completedBookCount: $0.value.completedCount,
                    representativeThumb: $0.value.thumb,
                    matchingNames: $0.value.matchingNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func genreAggregates(mediaScope: [String]) async -> [BrowseGenreAggregate] {
        struct Acc {
            var name: String
            var count = 0
            var matchingGenres = Set<String>()
        }

        var bucket: [String: Acc] = [:]
        for raw in mediaScope {
            for slice in await appState.bookStore.browseSlices(mediaType: raw) {
                for genre in normalizedGenres(slice.genres) {
                    let key = genreLookupKey(genre)
                    var acc = bucket[key] ?? Acc(name: genre)
                    acc.count += 1
                    acc.matchingGenres.insert(genre)
                    bucket[key] = acc
                }
            }
        }
        return bucket.values
            .map {
                BrowseGenreAggregate(
                    name: $0.name,
                    bookCount: $0.count,
                    matchingGenres: $0.matchingGenres.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func genreAggregates(from books: [Book]) -> [BrowseGenreAggregate] {
        struct Acc {
            var name: String
            var count = 0
            var matchingGenres = Set<String>()
        }

        var bucket: [String: Acc] = [:]
        for book in books {
            for genre in normalizedGenres(book.genres) {
                let key = genreLookupKey(genre)
                var acc = bucket[key] ?? Acc(name: genre)
                acc.count += 1
                acc.matchingGenres.insert(genre)
                bucket[key] = acc
            }
        }
        return bucket.values
            .map {
                BrowseGenreAggregate(
                    name: $0.name,
                    bookCount: $0.count,
                    matchingGenres: $0.matchingGenres.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func authorAggregates(mediaScope: [String]) async -> [BrowseAuthorAggregate] {
        var bucket: [String: (count: Int, thumb: String?, matchingNames: Set<String>)] = [:]
        for raw in mediaScope {
            for aggregate in await appState.bookStore.browseAuthorAggregates(mediaType: raw) {
                var entry = bucket[aggregate.name] ?? (0, nil, [])
                entry.count += aggregate.bookCount
                if entry.thumb == nil { entry.thumb = aggregate.representativeThumb }
                entry.matchingNames.formUnion(aggregate.matchingNames)
                bucket[aggregate.name] = entry
            }
        }
        return
            bucket
            .map {
                BrowseAuthorAggregate(
                    name: $0.key,
                    bookCount: $0.value.count,
                    representativeThumb: $0.value.thumb,
                    matchingNames: $0.value.matchingNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func authorAggregates(from books: [Book]) -> [BrowseAuthorAggregate] {
        let namesByBook = books.map { book in
            (book, normalizedAuthorNames(for: book))
        }
        let canonicalMap = NameNormalizer.buildCanonicalMap(from: namesByBook.flatMap(\.1))

        struct Acc {
            var count = 0
            var thumb: String?
            var matchingNames = Set<String>()
        }

        var bucket: [String: Acc] = [:]
        for (book, authors) in namesByBook where !authors.isEmpty {
            let rawLookupName = book.author?.trimmingCharacters(in: .whitespacesAndNewlines)
            for author in Set(authors) {
                let displayName = NameNormalizer.canonicalName(for: author, using: canonicalMap)
                var acc = bucket[displayName, default: Acc()]
                acc.count += 1
                if let rawLookupName, !rawLookupName.isEmpty { acc.matchingNames.insert(rawLookupName) }
                acc.matchingNames.insert(author)
                if acc.thumb == nil { acc.thumb = book.thumb }
                bucket[displayName] = acc
            }
        }

        return
            bucket
            .map {
                BrowseAuthorAggregate(
                    name: $0.key,
                    bookCount: $0.value.count,
                    representativeThumb: $0.value.thumb,
                    matchingNames: $0.value.matchingNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func narratorAggregates(mediaScope: [String]) async -> [BrowseNarratorAggregate] {
        var bucket: [String: (count: Int, thumb: String?)] = [:]
        for raw in mediaScope {
            for aggregate in await appState.bookStore.browseNarratorAggregates(mediaType: raw) {
                var entry = bucket[aggregate.name] ?? (0, nil)
                entry.count += aggregate.bookCount
                if entry.thumb == nil { entry.thumb = aggregate.representativeThumb }
                bucket[aggregate.name] = entry
            }
        }
        return
            bucket
            .map { BrowseNarratorAggregate(name: $0.key, bookCount: $0.value.count, representativeThumb: $0.value.thumb) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func narratorAggregates(from books: [Book]) -> [BrowseNarratorAggregate] {
        struct Acc {
            var count = 0
            var thumb: String?
        }

        var bucket: [String: Acc] = [:]
        for book in books {
            guard let raw = book.narrator?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            var acc = bucket[raw, default: Acc()]
            acc.count += 1
            if acc.thumb == nil { acc.thumb = book.thumb }
            bucket[raw] = acc
        }

        return
            bucket
            .map { BrowseNarratorAggregate(name: $0.key, bookCount: $0.value.count, representativeThumb: $0.value.thumb) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func normalizedAuthorNames(for book: Book) -> [String] {
        let explicit = book.authors ?? []
        let names = explicit.isEmpty ? (book.author ?? "").split(separator: ",").map(String.init) : explicit
        return Array(Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
    }

    private nonisolated func normalizedGenres(_ genres: [String]?) -> [String] {
        var seen = Set<String>()
        return (genres ?? []).compactMap {
            let genre = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !genre.isEmpty, seen.insert(genreLookupKey(genre)).inserted else { return nil }
            return genre
        }
    }

    private nonisolated func genreLookupKey(_ genre: String) -> String {
        genre.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    func seriesFan(for aggregate: BrowseSeriesAggregate, mediaScope: [String]) async -> [Book] {
        var collected: [Book] = []
        for raw in mediaScope where collected.count < 3 {
            collected += await appState.bookStore.books(
                bySeriesNames: aggregate.matchingNames,
                mediaType: raw,
                limit: 3 - collected.count
            )
        }
        return collected
    }

    func books(forSeries aggregate: BrowseSeriesAggregate, mediaScope: [String]) async -> [Book] {
        if mediaScope.count == 1, let raw = mediaScope.first {
            return await appState.bookStore.books(bySeriesNames: aggregate.matchingNames, mediaType: raw, limit: 500)
        }
        return await appState.bookStore.books(inSeriesNames: aggregate.matchingNames)
    }

    func books(forGenre aggregate: BrowseGenreAggregate, mediaScope: [String]) async -> [Book] {
        let matchingKeys = Set(aggregate.matchingGenres.map { genreLookupKey($0) })
        var ids: [String] = []
        var seenIds = Set<String>()

        for raw in mediaScope {
            let slices = await appState.bookStore.browseSlices(mediaType: raw)
            for slice in slices where normalizedGenres(slice.genres).contains(where: { matchingKeys.contains(genreLookupKey($0)) }) {
                if seenIds.insert(slice.id).inserted {
                    ids.append(slice.id)
                    if ids.count == 500 { break }
                }
            }
            if ids.count == 500 { break }
        }

        return await appState.bookStore.books(withIds: ids)
            .filter { normalizedGenres($0.genres).contains(where: { matchingKeys.contains(genreLookupKey($0)) }) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func coverBook(forAuthor aggregate: BrowseAuthorAggregate, mediaScope: [String]) async -> Book? {
        for raw in mediaScope {
            if let first = await appState.bookStore.books(
                byAuthorNames: aggregate.matchingNames,
                mediaType: raw,
                limit: 1
            ).first {
                return first
            }
        }
        return nil
    }

    func books(forAuthor aggregate: BrowseAuthorAggregate, mediaScope: [String]) async -> [Book] {
        var collected: [Book] = []
        var seen = Set<String>()
        for raw in mediaScope {
            let page = await appState.bookStore.books(byAuthorNames: aggregate.matchingNames, mediaType: raw, limit: 400)
            collected += page.filter { seen.insert($0.uniqueId).inserted }
        }
        return collected
    }

    func coverBook(forNarrator aggregate: BrowseNarratorAggregate, mediaScope: [String]) async -> Book? {
        for raw in mediaScope {
            if let first = await appState.bookStore.books(
                byNarrator: aggregate.name,
                mediaType: raw,
                limit: 1
            ).first {
                return first
            }
        }
        return nil
    }

    func books(forNarrator aggregate: BrowseNarratorAggregate, mediaScope: [String]) async -> [Book] {
        var collected: [Book] = []
        var seen = Set<String>()
        for raw in mediaScope {
            let page = await appState.bookStore.books(byNarrator: aggregate.name, mediaType: raw, limit: 400)
            collected += page.filter { seen.insert($0.uniqueId).inserted }
        }
        return collected
    }

    private func workSummary(for book: Book) async -> LibraryWorkSummary? {
        let key = WorkIdentity.workKey(for: book)
        guard !key.isEmpty else { return nil }

        guard let view = await workView(workKey: key), view.isConsolidated else {
            return nil
        }
        return LibraryWorkSummary(key: key, editions: view.editionCount, sources: view.sourceCount)
    }
}
