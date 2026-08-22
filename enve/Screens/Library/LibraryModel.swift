import Combine
import SwiftUI

enum LibraryFacet: String, CaseIterable {
    case books, series, authors, narrators, genres, shows

    var title: String {
        switch self {
        case .books: "Books"
        case .series: "Series"
        case .authors: "Authors"
        case .narrators: "Narrators"
        case .genres: "Genres"
        case .shows: "Shows"
        }
    }
}

enum LibraryLayout: String {
    case grid, list

    static let defaultsKey = "imagine.library.layout"

    static var persisted: LibraryLayout {
        LibraryLayout(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .list
    }
}

enum LibraryMediaFilter: String, CaseIterable {
    case all, audiobooks, ebooks, podcasts

    var title: String {
        switch self {
        case .all: "All media"
        case .audiobooks: "Audiobooks"
        case .ebooks: "Ebooks & comics"
        case .podcasts: "Podcasts"
        }
    }

    var mediaTypeRaw: String? {
        switch self {
        case .all: nil
        case .audiobooks: "audiobook"
        case .ebooks: "ebook"
        case .podcasts: "podcast"
        }
    }
}

enum LibrarySeriesFilter: String, CaseIterable, Codable {
    case all
    case inSeries
    case standalone

    var title: String {
        switch self {
        case .all: "Any"
        case .inSeries: "In a series"
        case .standalone: "Standalone"
        }
    }
}

struct LibraryAdvancedFilters: Codable, Equatable {
    var genres: Set<String> = []
    var languages: Set<String> = []
    var minimumRating: Double?
    var series: LibrarySeriesFilter = .all

    var isActive: Bool {
        !genres.isEmpty || !languages.isEmpty || minimumRating != nil || series != .all
    }

    static let empty = LibraryAdvancedFilters()
}

struct LibraryAdvancedFilterOptions {
    var genres: [String] = []
    var languages: [String] = []
}

enum LibraryAdvancedFilterPolicy {
    static func matches(_ book: Book, filters: LibraryAdvancedFilters) -> Bool {
        if !filters.genres.isEmpty {
            let selected = Set(filters.genres.map(normalized))
            let bookGenres = Set((book.genres ?? []).map(normalized))
            guard !selected.isDisjoint(with: bookGenres) else { return false }
        }
        if !filters.languages.isEmpty {
            let selected = Set(filters.languages.map(normalized))
            guard let language = book.language.map(normalized), selected.contains(language) else { return false }
        }
        if let minimumRating = filters.minimumRating,
            max(book.personalRating ?? 0, book.goodreadsRating ?? 0) < minimumRating
        {
            return false
        }
        let hasSeries = !(book.series?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        switch filters.series {
        case .all: break
        case .inSeries where !hasSeries: return false
        case .standalone where hasSeries: return false
        default: break
        }
        return true
    }

    static func options(from books: [Book]) -> LibraryAdvancedFilterOptions {
        LibraryAdvancedFilterOptions(
            genres: uniqueSorted(books.flatMap { $0.genres ?? [] }),
            languages: uniqueSorted(books.compactMap(\.language))
        )
    }

    private static func uniqueSorted(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return
            values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert(normalized($0)).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

@Observable
final class LibraryModel {
    private(set) var books: [Book] = [] {
        didSet { libraryRecollapse() }
    }

    private(set) var displayBooks: [Book] = []
    private(set) var seriesAggregates: [BrowseSeriesAggregate] = []
    private(set) var authorAggregates: [BrowseAuthorAggregate] = []
    private(set) var narratorAggregates: [BrowseNarratorAggregate] = []
    private(set) var genreAggregates: [BrowseGenreAggregate] = []
    private(set) var totalLibraryCount = 0
    private(set) var resultTotalCount = 0
    private(set) var downloadedBookIds: Set<String> = []
    private(set) var downloadedStableIds: Set<String> = []
    private(set) var hasLoaded = false
    private(set) var isPagedMode = false

    private(set) var facet: LibraryFacet = .books
    private(set) var status: LibraryStatusFilter
    private(set) var media: LibraryMediaFilter
    private(set) var sort: LibrarySort
    private(set) var sortDirection: LibrarySortDirection
    private(set) var sortDescriptors: [LibrarySortDescriptor]
    private(set) var layout: LibraryLayout
    private(set) var sourceFilter: LibrarySourceFilter
    private(set) var searchQuery = ""
    private(set) var advancedFilters: LibraryAdvancedFilters
    private(set) var advancedFilterOptions = LibraryAdvancedFilterOptions()
    private(set) var isLoadingAdvancedFilterOptions = false

    private(set) var isSelecting = false
    private(set) var selectedIds: Set<String> = []

    @ObservationIgnored private var rawPages: [Book] = []
    @ObservationIgnored private var pageCursor: Book?
    @ObservationIgnored private var pageOffset = 0
    @ObservationIgnored private var pagingMode: LibraryPagingMode = .none
    @ObservationIgnored private var isLoadingNextPage = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var workRefByRep: [String: LibraryWorkRef] = [:]
    @ObservationIgnored private var workHiddenIds: Set<String> = []
    @ObservationIgnored private var excludedLibraryKeys: Set<String> = []

    private static let pageSize = 200
    private static let pagePrefetchDistance = 40
    private static let pagedThreshold = 3000
    private static let expensiveSupportDataThreshold = 5000
    private static let supportDataSampleLimit = 1200
    private static let normalDownloadedBadgeLimit = 1000
    private static let statusKey = "imagine.library.status"
    private static let mediaKey = "imagine.library.media"
    private static let sortKey = "imagine.library.sort"
    private static let sortDirectionKey = "imagine.library.sortDirection"
    private static let sortDescriptorsKey = "imagine.library.sortDescriptors"
    private static let sourceKey = "imagine.library.source"
    private static let facetKey = "imagine.library.facet"
    private static let advancedFiltersKey = "imagine.library.advancedFilters"

    private enum LibraryPagingMode {
        case none
        case recentKeyset
        case sortedOffset
    }

    init() {
        let defaults = UserDefaults.standard
        facet = LibraryFacet(rawValue: defaults.string(forKey: Self.facetKey) ?? "") ?? .books
        status = LibraryStatusFilter(rawValue: defaults.string(forKey: Self.statusKey) ?? "") ?? .all
        media = LibraryMediaFilter(rawValue: defaults.string(forKey: Self.mediaKey) ?? "") ?? .all
        let fallbackSort = LibrarySort(rawValue: defaults.string(forKey: Self.sortKey) ?? "") ?? .recent
        let fallbackDirection = LibrarySortDirection(rawValue: defaults.string(forKey: Self.sortDirectionKey) ?? "") ?? .descending
        let descriptors = Self.loadSortDescriptors(defaults: defaults, fallbackSort: fallbackSort, fallbackDirection: fallbackDirection)
        sortDescriptors = descriptors
        sort = descriptors.first?.field ?? fallbackSort
        sortDirection = descriptors.first?.direction ?? fallbackDirection
        layout = .persisted
        sourceFilter = LibrarySourceFilter(rawValue: defaults.string(forKey: Self.sourceKey) ?? "")
        advancedFilters =
            defaults.data(forKey: Self.advancedFiltersKey)
            .flatMap { try? JSONDecoder().decode(LibraryAdvancedFilters.self, from: $0) }
            ?? .empty
    }

    var isSearchActive: Bool {
        !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var mediaScope: [String] {
        media.mediaTypeRaw.map { [$0] } ?? ["audiobook", "ebook", "podcast"]
    }

    func select(_ facet: LibraryFacet) {
        guard facet != self.facet else { return }
        self.facet = facet
        UserDefaults.standard.set(facet.rawValue, forKey: Self.facetKey)
        if facet != .books {
            libraryEndSelection()
        }
        Task { await reload() }
    }

    func select(_ status: LibraryStatusFilter) {
        guard status != self.status else { return }
        self.status = status
        UserDefaults.standard.set(status.rawValue, forKey: Self.statusKey)
        Task { await reload() }
    }

    func select(_ media: LibraryMediaFilter) {
        guard media != self.media else { return }
        self.media = media
        UserDefaults.standard.set(media.rawValue, forKey: Self.mediaKey)
        Task { await reload() }
    }

    func select(_ direction: LibrarySortDirection) {
        var descriptors = sortDescriptors
        if descriptors.isEmpty {
            descriptors = [LibrarySortDescriptor(field: sort, direction: direction)]
        } else {
            descriptors[0].direction = direction
        }
        setSortDescriptors(descriptors)
    }

    func addSort(_ sort: LibrarySort) {
        guard !sortDescriptors.contains(where: { $0.field == sort }) else { return }
        var descriptors = sortDescriptors
        descriptors.append(LibrarySortDescriptor(field: sort, direction: defaultDirection(for: sort)))
        setSortDescriptors(descriptors)
    }

    func removeSort(_ sort: LibrarySort) {
        let descriptors = sortDescriptors.filter { $0.field != sort }
        setSortDescriptors(descriptors.isEmpty ? [Self.defaultSortDescriptor] : descriptors)
    }

    func select(_ direction: LibrarySortDirection, for sort: LibrarySort) {
        guard let index = sortDescriptors.firstIndex(where: { $0.field == sort }) else { return }
        var descriptors = sortDescriptors
        guard descriptors[index].direction != direction else { return }
        descriptors[index].direction = direction
        setSortDescriptors(descriptors)
    }

    func moveSortUp(_ sort: LibrarySort) {
        guard let index = sortDescriptors.firstIndex(where: { $0.field == sort }), index > 0 else { return }
        var descriptors = sortDescriptors
        descriptors.swapAt(index, index - 1)
        setSortDescriptors(descriptors)
    }

    func moveSortDown(_ sort: LibrarySort) {
        guard let index = sortDescriptors.firstIndex(where: { $0.field == sort }),
            index < sortDescriptors.count - 1
        else { return }
        var descriptors = sortDescriptors
        descriptors.swapAt(index, index + 1)
        setSortDescriptors(descriptors)
    }

    func clearSorting() {
        setSortDescriptors([Self.defaultSortDescriptor])
    }

    func selectLayout(_ layout: LibraryLayout) {
        guard layout != self.layout else { return }
        self.layout = layout
        UserDefaults.standard.set(layout.rawValue, forKey: LibraryLayout.defaultsKey)
    }

    func select(_ source: LibrarySourceFilter) {
        guard source != sourceFilter else { return }
        sourceFilter = source
        UserDefaults.standard.set(source.rawValue, forKey: Self.sourceKey)
        Task { await reload() }
    }

    func focus(status: LibraryStatusFilter, media: LibraryMediaFilter, source: LibrarySourceFilter, facet: LibraryFacet = .books) {
        var changed = false
        if self.status != status {
            self.status = status
            UserDefaults.standard.set(status.rawValue, forKey: Self.statusKey)
            changed = true
        }
        if self.media != media {
            self.media = media
            UserDefaults.standard.set(media.rawValue, forKey: Self.mediaKey)
            changed = true
        }
        if sourceFilter != source {
            sourceFilter = source
            UserDefaults.standard.set(source.rawValue, forKey: Self.sourceKey)
            changed = true
        }
        if self.facet != facet {
            self.facet = facet
            UserDefaults.standard.set(facet.rawValue, forKey: Self.facetKey)
            changed = true
        }
        if changed {
            libraryEndSelection()
            Task { await reload() }
        }
    }

    var isNarrowed: Bool {
        status != .all || media != .all || sourceFilter != .all || advancedFilters.isActive
    }

    var activeFilterCount: Int {
        var count = 0
        if status != .all { count += 1 }
        if media != .all { count += 1 }
        if sourceFilter != .all { count += 1 }
        if advancedFilters.minimumRating != nil { count += 1 }
        if advancedFilters.series != .all { count += 1 }
        count += advancedFilters.genres.count
        count += advancedFilters.languages.count
        return count
    }

    var resultSummary: String {
        let loaded = books.count
        if resultTotalCount > loaded {
            return "\(loaded.formatted()) of \(resultTotalCount.formatted()) loaded"
        }
        return loaded == 1 ? "1 book" : "\(loaded.formatted()) books"
    }

    func isDownloaded(_ book: Book) -> Bool {
        downloadedBookIds.contains(book.uniqueId) || downloadedStableIds.contains(book.stableId)
    }

    func clearFilters() {
        status = .all
        media = .all
        sourceFilter = .all
        advancedFilters = .empty
        UserDefaults.standard.set(LibraryStatusFilter.all.rawValue, forKey: Self.statusKey)
        UserDefaults.standard.set(LibraryMediaFilter.all.rawValue, forKey: Self.mediaKey)
        UserDefaults.standard.set(LibrarySourceFilter.all.rawValue, forKey: Self.sourceKey)
        UserDefaults.standard.removeObject(forKey: Self.advancedFiltersKey)
        Task { await reload() }
    }

    func toggleGenre(_ genre: String) {
        var filters = advancedFilters
        if !filters.genres.insert(genre).inserted {
            filters.genres.remove(genre)
        }
        setAdvancedFilters(filters)
    }

    func toggleLanguage(_ language: String) {
        var filters = advancedFilters
        if !filters.languages.insert(language).inserted {
            filters.languages.remove(language)
        }
        setAdvancedFilters(filters)
    }

    func selectMinimumRating(_ rating: Double?) {
        var filters = advancedFilters
        filters.minimumRating = rating
        setAdvancedFilters(filters)
    }

    func selectSeriesFilter(_ series: LibrarySeriesFilter) {
        var filters = advancedFilters
        filters.series = series
        setAdvancedFilters(filters)
    }

    func loadAdvancedFilterOptions() async {
        guard !isLoadingAdvancedFilterOptions else { return }
        isLoadingAdvancedFilterOptions = true
        defer { isLoadingAdvancedFilterOptions = false }
        let library = EnveEngine.shared.library
        let downloaded = status == .downloaded ? downloadedStableIdsFromTasks() : []
        let list = await sourceScopedBooks(library: library, mediaType: nil, boundedForSupportData: true)
            .filter { library.matchesStatus($0, status: status, downloadedIds: downloaded) }
        advancedFilterOptions = LibraryAdvancedFilterPolicy.options(from: list)
    }

    private func setAdvancedFilters(_ filters: LibraryAdvancedFilters) {
        guard filters != advancedFilters else { return }
        advancedFilters = filters
        if filters.isActive, let data = try? JSONEncoder().encode(filters) {
            UserDefaults.standard.set(data, forKey: Self.advancedFiltersKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.advancedFiltersKey)
        }
        Task { await reload() }
    }

    var sortSummary: String {
        sortDescriptors.map(\.summary).joined(separator: " -> ")
    }

    var usesDefaultSorting: Bool {
        sortDescriptors == [Self.defaultSortDescriptor]
    }

    private var storeSortDescriptors: [BookStoreSortDescriptor] {
        let descriptors = sortDescriptors.isEmpty ? [Self.defaultSortDescriptor] : sortDescriptors
        return descriptors.map {
            BookStoreSortDescriptor(
                field: Self.storeSortField(for: $0.field),
                direction: Self.storeSortDirection(for: $0.direction)
            )
        }
    }

    private nonisolated static let defaultSortDescriptor = LibrarySortDescriptor(field: .recent, direction: .descending)

    private nonisolated static func storeSortField(for sort: LibrarySort) -> BookStoreSortField {
        switch sort {
        case .recent:
            return .recent
        case .recentlyRead:
            return .recentlyRead
        case .title:
            return .title
        case .author:
            return .authorGiven
        case .authorSurname:
            return .authorSurname
        case .narrator:
            return .narratorGiven
        case .narratorSurname:
            return .narratorSurname
        case .series:
            return .series
        case .progress:
            return .progress
        case .duration:
            return .duration
        case .year:
            return .year
        case .goodreadsRating:
            return .goodreadsRating
        }
    }

    private nonisolated static func storeSortDirection(for direction: LibrarySortDirection) -> BookStoreSortDirection {
        switch direction {
        case .ascending:
            return .ascending
        case .descending:
            return .descending
        }
    }

    private static func loadSortDescriptors(
        defaults: UserDefaults,
        fallbackSort: LibrarySort,
        fallbackDirection: LibrarySortDirection
    ) -> [LibrarySortDescriptor] {
        if let data = defaults.data(forKey: sortDescriptorsKey),
            let decoded = try? JSONDecoder().decode([LibrarySortDescriptor].self, from: data)
        {
            let unique = uniqueSortDescriptors(decoded)
            if !unique.isEmpty { return unique }
        }
        return [LibrarySortDescriptor(field: fallbackSort, direction: fallbackDirection)]
    }

    private func setSortDescriptors(_ descriptors: [LibrarySortDescriptor]) {
        let descriptors = Self.uniqueSortDescriptors(descriptors)
        guard descriptors != sortDescriptors else { return }
        sortDescriptors = descriptors.isEmpty ? [Self.defaultSortDescriptor] : descriptors
        syncPrimarySort()
        persistSortDescriptors()
        Task { await reload() }
    }

    private func syncPrimarySort() {
        let primary = sortDescriptors.first ?? Self.defaultSortDescriptor
        sort = primary.field
        sortDirection = primary.direction
    }

    private func persistSortDescriptors() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(sortDescriptors) {
            defaults.set(data, forKey: Self.sortDescriptorsKey)
        }
        defaults.set(sort.rawValue, forKey: Self.sortKey)
        defaults.set(sortDirection.rawValue, forKey: Self.sortDirectionKey)
    }

    private static func uniqueSortDescriptors(_ descriptors: [LibrarySortDescriptor]) -> [LibrarySortDescriptor] {
        var seen = Set<LibrarySort>()
        return descriptors.filter { seen.insert($0.field).inserted }
    }

    private func defaultDirection(for sort: LibrarySort) -> LibrarySortDirection {
        switch sort {
        case .recent, .recentlyRead, .progress, .duration, .year, .goodreadsRating:
            return .descending
        case .title, .author, .authorSurname, .narrator, .narratorSurname, .series:
            return .ascending
        }
    }

    func toggleSelecting() {
        isSelecting.toggle()
        if !isSelecting { selectedIds.removeAll() }
    }

    func toggleSelected(_ book: Book) {
        if selectedIds.contains(book.uniqueId) {
            selectedIds.remove(book.uniqueId)
        } else {
            selectedIds.insert(book.uniqueId)
        }
    }

    func isSelected(_ book: Book) -> Bool {
        selectedIds.contains(book.uniqueId)
    }

    var isLoadedSelectionComplete: Bool {
        let loaded = Set(displayBooks.map(\.uniqueId))
        return !loaded.isEmpty && loaded.isSubset(of: selectedIds)
    }

    var selectionScopeTitle: String {
        if isLoadedSelectionComplete { return "Clear" }
        return isPagedMode ? "Select loaded" : "Select all"
    }

    func toggleSelectionScope() {
        let loaded = Set(displayBooks.map(\.uniqueId))
        if isLoadedSelectionComplete {
            selectedIds.subtract(loaded)
        } else {
            selectedIds.formUnion(loaded)
        }
    }

    var selectedBooks: [Book] {
        displayBooks.filter { selectedIds.contains($0.uniqueId) }
    }

    var hasPlayableSelection: Bool {
        selectedBooks.contains { $0.mediaType != .ebook }
    }

    private func libraryEndSelection() {
        selectedIds.removeAll()
        isSelecting = false
    }

    func downloadSelected() {
        let targets = selectedBooks.filter {
            $0.source != .local && !LibraryBookActions.isDownloaded($0)
        }
        libraryEndSelection()
        guard !targets.isEmpty else { return }
        PlatformHaptics.impact(.light)
        Task {
            for book in targets {
                await EnveEngine.shared.downloads.download(book)
            }
        }
    }

    func playSelected() {
        let targets = selectedBooks
        guard EnveEngine.shared.playback.playAll(targets, groupKey: "selection") else { return }
        libraryEndSelection()
        PlatformHaptics.impact(.medium)
    }

    func queueSelected() {
        let targets = selectedBooks.filter { $0.mediaType != .ebook }
        libraryEndSelection()
        guard !targets.isEmpty else { return }
        EnveEngine.shared.playback.addLast(targets, groupKey: "selection")
        PlatformHaptics.impact(.light)
    }

    func removeSelectedDownloads() {
        let targets = selectedBooks.filter {
            $0.source != .local && LibraryBookActions.isDownloaded($0)
        }
        libraryEndSelection()
        guard !targets.isEmpty else { return }
        PlatformHaptics.impact(.medium)
        for book in targets {
            LibraryBookActions.removeDownload(book)
        }
    }

    func markSelectedFinished() {
        let targets = selectedBooks.filter { !$0.isFinished }
        libraryEndSelection()
        guard !targets.isEmpty else { return }
        PlatformHaptics.impact(.light)
        for book in targets {
            _ = EnveEngine.shared.library.toggleFinished(book)
        }
    }

    func hideSelected() {
        let targets = selectedBooks
        libraryEndSelection()
        guard !targets.isEmpty else { return }
        Self.markHidden(targets)
        let ids = Set(targets.map(\.uniqueId))
        books.removeAll { ids.contains($0.uniqueId) }
        rawPages.removeAll { ids.contains($0.uniqueId) }
    }

    func updateSearch(_ text: String) {
        searchTask?.cancel()
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            guard isSearchActive else { return }
            searchQuery = ""
            if facet != .books {
                libraryEndSelection()
            }
            Task { await reload() }
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            searchQuery = text
            await reload()
        }
    }

    func bootstrap() async {
        guard !hasLoaded else { return }
        if let id = sourceFilter.providerId,
            !EnveEngine.shared.library.hasConnection(id: id)
        {
            sourceFilter = .all
            UserDefaults.standard.set(LibrarySourceFilter.all.rawValue, forKey: Self.sourceKey)
        }
        await reload()
    }

    func reload() async {
        generation &+= 1
        let gen = generation
        let library = EnveEngine.shared.library
        excludedLibraryKeys = LibraryDisplayPreferencesStore.shared.loadPreferences().excludedLibraryIds
        totalLibraryCount = await library.totalBookCount()
        if facet == .books || isSearchActive {
            if await shouldBuildWorkIndex(library: library) {
                await rebuildWorkIndex()
            } else {
                workHiddenIds = []
                workRefByRep = [:]
                libraryRecollapse()
            }
        }
        let downloadedLimit =
            status == .downloaded
            ? max(totalLibraryCount, 1)
            : min(max(totalLibraryCount, 1), Self.normalDownloadedBadgeLimit)
        let downloadedEbooks = await library.downloadedEbooks(limit: downloadedLimit)
        downloadedBookIds = Set(downloadedEbooks.map(\.uniqueId))
        downloadedStableIds = Set(downloadedEbooks.map(\.stableId))
        downloadedStableIds.formUnion(downloadedStableIdsFromTasks())

        if isSearchActive {
            let results = await library.searchBooks(query: searchQuery, sourceFilter: sourceFilter, limit: 200)
            guard gen == generation else { return }
            let downloaded = status == .downloaded ? downloadedStableIdsFromTasks() : []
            let mediaRaw = media.mediaTypeRaw
            let kept = results.filter {
                (mediaRaw == nil || $0.mediaType.rawValue == mediaRaw)
                    && library.matchesStatus($0, status: status, downloadedIds: downloaded)
                    && libraryMatchesSource($0)
                    && LibraryAdvancedFilterPolicy.matches($0, filters: advancedFilters)
            }
            books = library.applySort(kept, descriptors: sortDescriptors)
            resultTotalCount = kept.count
            isPagedMode = false
            pageCursor = nil
            pageOffset = 0
            pagingMode = .none
            hasLoaded = true
            return
        }

        switch facet {
        case .books:
            await loadGrid(gen: gen, library: library)
        case .series:
            await loadSeriesAggregates(gen: gen, library: library)
        case .authors:
            await loadAuthorAggregates(gen: gen, library: library)
        case .narrators:
            await loadNarratorAggregates(gen: gen, library: library)
        case .genres:
            await loadGenreAggregates(gen: gen, library: library)
        case .shows:
            await PodcastsModel.shared.loadIfNeeded()
        }
        if gen == generation { hasLoaded = true }
    }

    private func loadGrid(gen: Int, library: LibraryEngine) async {
        if advancedFilters.isActive {
            await presentStatusScopedBooks(library: library, gen: gen)
            return
        }
        switch status {
        case .all:
            let raw = media.mediaTypeRaw
            if sourceFilter == .device {
                await present(await sourceScopedBooks(library: library, mediaType: raw), gen: gen)
                return
            }
            if case .library(let providerId, let libraryId) = sourceFilter {
                let scopedCount = await library.bookCount(
                    sourceFilter: .library(providerId: providerId, libraryId: libraryId),
                    mediaType: raw
                )
                resultTotalCount = scopedCount
                if scopedCount > Self.pagedThreshold {
                    if usesDefaultSorting, !library.usesRemoteBrowsing(sourceFilter: sourceFilter) {
                        let first = await library.pagedBooks(sourceFilter: sourceFilter, mediaType: raw, after: nil, limit: Self.pageSize)
                        guard gen == generation else { return }
                        rawPages = first
                        pageCursor = first.last
                        pageOffset = first.count
                        pagingMode = .recentKeyset
                        isPagedMode = true
                        let kept = first.filter { libraryMatchesSource($0) && (raw == nil || $0.mediaType.rawValue == raw) }
                        books = kept
                    } else {
                        await beginSortedPaging(gen: gen, library: library)
                    }
                } else {
                    let all = await library.pagedBooks(sourceFilter: sourceFilter, mediaType: raw, offset: 0, limit: max(scopedCount, 1))
                    guard gen == generation else { return }
                    rawPages = []
                    pageCursor = nil
                    pageOffset = 0
                    pagingMode = .none
                    isPagedMode = false
                    let kept = all.filter { libraryMatchesSource($0) && (raw == nil || $0.mediaType.rawValue == raw) }
                    books = library.applySort(kept, descriptors: sortDescriptors)
                }
                return
            }
            if case .connection(let providerId) = sourceFilter {
                let scopedCount = await library.bookCount(sourceFilter: .connection(providerId), mediaType: raw)
                resultTotalCount = scopedCount
                if scopedCount > Self.pagedThreshold {
                    if usesDefaultSorting {
                        let first = await library.pagedBooks(sourceFilter: sourceFilter, mediaType: raw, after: nil, limit: Self.pageSize)
                        guard gen == generation else { return }
                        rawPages = first
                        pageCursor = first.last
                        pageOffset = first.count
                        pagingMode = .recentKeyset
                        isPagedMode = true
                        let kept = first.filter(libraryMatchesSource)
                        books = kept
                    } else {
                        await beginSortedPaging(gen: gen, library: library)
                    }
                } else {
                    let all = await library.pagedBooks(sourceFilter: sourceFilter, mediaType: raw, after: nil, limit: max(scopedCount, 1))
                    guard gen == generation else { return }
                    rawPages = []
                    pageCursor = nil
                    pageOffset = 0
                    pagingMode = .none
                    isPagedMode = false
                    books = library.applySort(all.filter(libraryMatchesSource), descriptors: sortDescriptors)
                }
                return
            }
            let scopedCount: Int
            if let raw {
                scopedCount = await library.bookCount(mediaType: raw)
            } else {
                scopedCount = totalLibraryCount
            }
            resultTotalCount = scopedCount
            if scopedCount > Self.pagedThreshold {
                if usesDefaultSorting {
                    let first = await library.pagedBooks(sourceFilter: sourceFilter, mediaType: raw, after: nil, limit: Self.pageSize)
                    guard gen == generation else { return }
                    rawPages = first
                    pageCursor = first.last
                    pageOffset = first.count
                    pagingMode = .recentKeyset
                    isPagedMode = true
                    let kept = first.filter(libraryMatchesSource)
                    books = kept
                } else {
                    await beginSortedPaging(gen: gen, library: library)
                }
            } else {
                let all = await library.pagedBooks(sourceFilter: sourceFilter, mediaType: raw, offset: 0, limit: max(scopedCount, 1))
                guard gen == generation else { return }
                rawPages = []
                pageCursor = nil
                pageOffset = 0
                pagingMode = .none
                isPagedMode = false
                books = library.applySort(all.filter(libraryMatchesSource), descriptors: sortDescriptors)
            }
        case .listening:
            if sourceFilter == .all {
                await present(await library.continueListeningBooks(limit: 300), gen: gen)
            } else {
                await presentStatusScopedBooks(library: library, gen: gen)
            }
        case .reading:
            if sourceFilter == .all {
                await present(await library.continueReadingBooks(limit: 300), gen: gen)
            } else {
                await presentStatusScopedBooks(library: library, gen: gen)
            }
        case .finished:
            if sourceFilter == .all {
                await present(await library.booksMatching(Self.finishedCollection, limit: 1000), gen: gen)
            } else {
                await presentStatusScopedBooks(library: library, gen: gen)
            }
        case .downloaded:
            if sourceFilter == .all {
                let ids = downloadedStableIdsFromTasks()
                let list = await library.downloadedBooks(audioStableIds: ids, ebookLimit: max(totalLibraryCount, 1))
                let kept = library.filterStatus(list, status: .downloaded, downloadedIds: ids)
                await present(kept, gen: gen)
            } else {
                await presentStatusScopedBooks(library: library, gen: gen)
            }
        }
    }

    private func presentStatusScopedBooks(library: LibraryEngine, gen: Int) async {
        let downloaded = status == .downloaded ? downloadedStableIdsFromTasks() : []
        let list = await sourceScopedBooks(library: library, mediaType: media.mediaTypeRaw, boundedForSupportData: true)
        let kept = library.filterStatus(list, status: status, downloadedIds: downloaded)
        await present(kept, gen: gen)
    }

    private func present(_ list: [Book], gen: Int) async {
        let mediaRaw = media.mediaTypeRaw
        var kept = mediaRaw.map { r in list.filter { $0.mediaType.rawValue == r } } ?? list
        kept = kept.filter(libraryMatchesSource)
        kept = kept.filter { LibraryAdvancedFilterPolicy.matches($0, filters: advancedFilters) }
        guard gen == generation else { return }
        rawPages = []
        pageCursor = nil
        pageOffset = 0
        pagingMode = .none
        isPagedMode = false
        books = EnveEngine.shared.library.applySort(kept, descriptors: sortDescriptors)
        resultTotalCount = kept.count
    }

    func loadNextPageIfNeeded(currentBookId: String) {
        let triggerIndex = max(displayBooks.count - Self.pagePrefetchDistance, 0)
        guard isPagedMode, !isLoadingNextPage, !isSearchActive,
            displayBooks.indices.contains(triggerIndex),
            displayBooks[triggerIndex].uniqueId == currentBookId,
            pagingMode != .none
        else { return }
        isLoadingNextPage = true
        let gen = generation
        let mode = pagingMode
        let cursor = pageCursor
        let offset = pageOffset
        Task {
            let library = EnveEngine.shared.library
            let next: [Book]
            switch mode {
            case .recentKeyset:
                guard let cursor else {
                    pagingMode = .none
                    isLoadingNextPage = false
                    return
                }
                next = await library.pagedBooks(
                    sourceFilter: sourceFilter,
                    mediaType: media.mediaTypeRaw,
                    after: cursor,
                    limit: Self.pageSize
                )
            case .sortedOffset:
                next = await loadSortedPage(library: library, offset: offset, limit: Self.pageSize)
            case .none:
                next = []
            }
            defer { isLoadingNextPage = false }
            guard gen == generation else { return }
            guard !next.isEmpty else {
                pageCursor = nil
                pagingMode = .none
                return
            }
            var seen = Set(rawPages.map(\.uniqueId))
            rawPages.append(contentsOf: next.filter { seen.insert($0.uniqueId).inserted })
            switch mode {
            case .recentKeyset:
                pageCursor = next.last
                if next.count < Self.pageSize { pagingMode = .none }
            case .sortedOffset:
                pageOffset = offset + Self.pageSize
            case .none:
                pagingMode = .none
            }
            let mediaRaw = media.mediaTypeRaw
            let kept = rawPages.filter {
                libraryMatchesSource($0) && (mediaRaw == nil || $0.mediaType.rawValue == mediaRaw)
            }
            books = kept
        }
    }

    private func beginSortedPaging(gen: Int, library: LibraryEngine) async {
        let first = await loadSortedPage(library: library, offset: 0, limit: Self.pageSize)
        guard gen == generation else { return }
        rawPages = first
        pageCursor = nil
        pageOffset = Self.pageSize
        pagingMode = first.isEmpty ? .none : .sortedOffset
        isPagedMode = pagingMode != .none
        books = first.filter(libraryMatchesSource)
    }

    private func loadSortedPage(library: LibraryEngine, offset: Int, limit: Int) async -> [Book] {
        await library.sortedPagedBooks(
            sourceFilter: sourceFilter,
            mediaType: media.mediaTypeRaw,
            offset: offset,
            limit: limit,
            sort: storeSortDescriptors
        )
    }

    private func libraryMatchesSource(_ book: Book) -> Bool {
        if !excludedLibraryKeys.isEmpty,
            excludedLibraryKeys.contains("\(book.providerId.uuidString)_\(book.libraryId)")
        {
            return false
        }
        switch sourceFilter {
        case .all: return true
        case .device: return book.source == .local || book.source == .smb
        case .connection(let id): return book.providerId == id
        case .library(let providerId, let libraryId):
            return book.providerId == providerId && book.libraryId == libraryId
        }
    }

    private func rebuildWorkIndex() async {
        let index = await EnveEngine.shared.library.workIndex()
        workHiddenIds = index.hiddenUniqueIds
        workRefByRep = index.representativeWorkKey.reduce(into: [:]) { result, entry in
            result[entry.key] = LibraryWorkRef(key: entry.value, count: index.representativeCount[entry.key] ?? 2)
        }
        libraryRecollapse()
    }

    private func shouldBuildWorkIndex(library: LibraryEngine) async -> Bool {
        switch sourceFilter {
        case .device:
            return true
        case .all:
            return totalLibraryCount <= Self.expensiveSupportDataThreshold
        case .connection, .library:
            return await library.largeSourceCount(
                sourceFilter: sourceFilter,
                mediaType: media.mediaTypeRaw,
                threshold: Self.expensiveSupportDataThreshold
            ) == nil
        }
    }

    private func libraryRecollapse() {
        if workHiddenIds.isEmpty {
            displayBooks = books
        } else {
            displayBooks = books.filter { !workHiddenIds.contains($0.uniqueId) }
        }
    }

    func consolidatedWork(for book: Book) -> LibraryWorkRef? {
        workRefByRep[book.uniqueId]
    }

    private func loadSeriesAggregates(gen: Int, library: LibraryEngine) async {
        if sourceFilter != .all || status != .all || advancedFilters.isActive {
            let books = await sourceScopedBooksForCurrentMedia(library: library, boundedForSupportData: true)
            let merged = library.seriesAggregates(from: books)
            guard gen == generation else { return }
            seriesAggregates = merged
            return
        }

        let merged = await library.seriesAggregates(mediaScope: mediaScope)
        guard gen == generation else { return }
        seriesAggregates = merged
    }

    private func loadAuthorAggregates(gen: Int, library: LibraryEngine) async {
        if sourceFilter != .all || status != .all || advancedFilters.isActive {
            let books = await sourceScopedBooksForCurrentMedia(library: library, boundedForSupportData: true)
            let merged = library.authorAggregates(from: books)
            guard gen == generation else { return }
            authorAggregates = merged
            return
        }

        let merged = await library.authorAggregates(mediaScope: mediaScope)
        guard gen == generation else { return }
        authorAggregates = merged
    }

    private func loadNarratorAggregates(gen: Int, library: LibraryEngine) async {
        if sourceFilter != .all || status != .all || advancedFilters.isActive {
            let books = await sourceScopedBooksForCurrentMedia(library: library, boundedForSupportData: true)
            let merged = library.narratorAggregates(from: books)
            guard gen == generation else { return }
            narratorAggregates = merged
            return
        }

        let merged = await library.narratorAggregates(mediaScope: mediaScope)
        guard gen == generation else { return }
        narratorAggregates = merged
    }

    private func loadGenreAggregates(gen: Int, library: LibraryEngine) async {
        if sourceFilter != .all || status != .all || advancedFilters.isActive {
            let books = await sourceScopedBooksForCurrentMedia(library: library, boundedForSupportData: true)
            let merged = library.genreAggregates(from: books)
            guard gen == generation else { return }
            genreAggregates = merged
            return
        }

        let merged = await library.genreAggregates(mediaScope: mediaScope)
        guard gen == generation else { return }
        genreAggregates = merged
    }

    func books(forGenre aggregate: BrowseGenreAggregate) async -> [Book] {
        let library = EnveEngine.shared.library
        if sourceFilter == .all, status == .all, !advancedFilters.isActive {
            return await library.books(forGenre: aggregate, mediaScope: mediaScope)
        }
        let matchingKeys = Set(aggregate.matchingGenres.map(Self.genreLookupKey))
        return await sourceScopedBooksForCurrentMedia(library: library, boundedForSupportData: true)
            .filter { book in
                (book.genres ?? []).contains { matchingKeys.contains(Self.genreLookupKey($0)) }
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func sourceScopedBooksForCurrentMedia(library: LibraryEngine, boundedForSupportData: Bool = false) async -> [Book] {
        let downloaded = status == .downloaded ? downloadedStableIdsFromTasks() : []
        return await sourceScopedBooks(library: library, mediaType: nil, boundedForSupportData: boundedForSupportData)
            .filter { library.matchesStatus($0, status: status, downloadedIds: downloaded) }
            .filter { LibraryAdvancedFilterPolicy.matches($0, filters: advancedFilters) }
    }

    private func sourceScopedBooks(
        library: LibraryEngine,
        mediaType: String?,
        boundedForSupportData: Bool = false
    ) async -> [Book] {
        let mediaTypes = mediaType.map { [$0] } ?? mediaScope
        return await library.sourceScopedBooks(
            sourceFilter: sourceFilter,
            mediaTypes: mediaTypes,
            limitPerMediaType: boundedForSupportData ? Self.supportDataSampleLimit : nil
        )
            .filter(libraryMatchesSource)
    }

    private nonisolated static func genreLookupKey(_ genre: String) -> String {
        genre.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    func hide(_ book: Book) {
        Self.markHidden(book)
        books.removeAll { $0.uniqueId == book.uniqueId }
        rawPages.removeAll { $0.uniqueId == book.uniqueId }
    }

    static func markHidden(_ book: Book) {
        markHidden([book])
    }

    static func markHidden(_ booksToHide: [Book]) {
        guard !booksToHide.isEmpty else { return }
        Task { await EnveEngine.shared.library.hideFromLibrary(booksToHide) }
        PlatformHaptics.impact(.light)
    }

    private func downloadedStableIdsFromTasks() -> Set<String> {
        EnveEngine.shared.downloads.completedDownloadBookIds
    }

    private static let finishedCollection = SmartCollection(
        id: "imagine.library.finished",
        name: "Finished",
        description: nil,
        rules: SmartCollectionRuleGroup(
            logicOperator: .and,
            rules: [SmartCollectionRule(field: .isFinished, operator: .isTrue, value: "")]
        ),
        iconName: "checkmark.circle",
        color: "",
        isSystem: true,
        sortOrder: 0
    )

}
