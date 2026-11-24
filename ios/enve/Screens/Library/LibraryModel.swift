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
    case all, audiobooks, ebooks, comics, podcasts

    var title: String {
        switch self {
        case .all: "All media"
        case .audiobooks: "Audiobooks"
        case .ebooks: "Ebooks"
        case .comics: "Comics"
        case .podcasts: "Podcasts"
        }
    }

    var mediaTypeRaw: String? {
        switch self {
        case .all: nil
        case .audiobooks: "audiobook"
        case .ebooks, .comics: "ebook"
        case .podcasts: "podcast"
        }
    }

    func matches(_ book: Book) -> Bool {
        switch self {
        case .all: true
        case .comics: book.mediaType == .ebook && book.isComic
        case .audiobooks, .ebooks, .podcasts: book.mediaType.rawValue == mediaTypeRaw
        }
    }
}

struct LibraryBrowsePreferences: Equatable {
    var facet: LibraryFacet
    var layout: LibraryLayout

    static let facetKey = "imagine.library.facet"
    static let comicsFacets: [LibraryFacet] = [.books, .series]

    static func load(media: LibraryMediaFilter, source: LibrarySourceFilter, defaults: UserDefaults) -> LibraryBrowsePreferences {
        let globalLayout = LibraryLayout(rawValue: defaults.string(forKey: LibraryLayout.defaultsKey) ?? "") ?? .list
        guard media == .comics else {
            let facet = LibraryFacet(rawValue: defaults.string(forKey: facetKey) ?? "") ?? .books
            return LibraryBrowsePreferences(facet: facet, layout: globalLayout)
        }
        let facet = LibraryFacet(rawValue: defaults.string(forKey: comicsKey("facet", source: source)) ?? "")
            .flatMap { comicsFacets.contains($0) ? $0 : nil }
            ?? .series
        let layout = LibraryLayout(rawValue: defaults.string(forKey: comicsKey("layout", source: source)) ?? "") ?? globalLayout
        return LibraryBrowsePreferences(facet: facet, layout: layout)
    }

    static func save(facet: LibraryFacet, media: LibraryMediaFilter, source: LibrarySourceFilter, defaults: UserDefaults) {
        defaults.set(facet.rawValue, forKey: media == .comics ? comicsKey("facet", source: source) : facetKey)
    }

    static func save(layout: LibraryLayout, media: LibraryMediaFilter, source: LibrarySourceFilter, defaults: UserDefaults) {
        defaults.set(layout.rawValue, forKey: media == .comics ? comicsKey("layout", source: source) : LibraryLayout.defaultsKey)
    }

    private static func comicsKey(_ name: String, source: LibrarySourceFilter) -> String {
        "imagine.library.comics.\(name).\(source.rawValue)"
    }
}

enum LibraryRemoteCatalogState: Equatable {
    case loading
    case loaded(hasMore: Bool)
    case onDeviceOnly
    case failed(String)
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
    private(set) var loadedAggregateFacets: Set<LibraryFacet> = []
    private(set) var totalLibraryCount = 0
    private(set) var resultTotalCount = 0
    private(set) var downloadedBookIds: Set<String> = []
    private var downloadedAudioStorageKeys: Set<String> = []
    @ObservationIgnored private var offlineBooks: [Book] = []
    private(set) var hasLoaded = false
    private(set) var isPagedMode = false

    private(set) var facet: LibraryFacet = .books
    private var selectedStatus: LibraryStatusFilter
    private var selectedMedia: LibraryMediaFilter
    private(set) var status: LibraryStatusFilter {
        get { !readingEnabled && selectedStatus == .reading ? .listening : selectedStatus }
        set { selectedStatus = newValue }
    }
    private(set) var media: LibraryMediaFilter {
        get { !readingEnabled && (selectedMedia == .ebooks || selectedMedia == .comics) ? .all : selectedMedia }
        set { selectedMedia = newValue }
    }
    private(set) var sort: LibrarySort
    private(set) var sortDirection: LibrarySortDirection
    private(set) var sortDescriptors: [LibrarySortDescriptor]
    private(set) var layout: LibraryLayout
    private(set) var sourceFilter: LibrarySourceFilter
    private(set) var searchQuery = ""
    private(set) var advancedFilters: LibraryAdvancedFilters
    private(set) var advancedFilterOptions = LibraryAdvancedFilterOptions()
    private(set) var isLoadingAdvancedFilterOptions = false
    private(set) var advancedFilterOptionsError: String?
    private(set) var hasMoreAdvancedFilterOptions = false
    @ObservationIgnored private var filterOptionsGeneration = 0

    private(set) var isSelecting = false
    private(set) var selectedIds: Set<String> = []

    private(set) var remoteCatalog: LibraryRemoteCatalogState?
    private(set) var isLoadingRemotePage = false
    private(set) var remotePageError: String?
    private(set) var localScopeNotice: String?
    private(set) var remoteIssues: [CatalogLaneIssue] = []
    @ObservationIgnored private var remoteSession: RemoteCatalogSession?
    @ObservationIgnored private var remoteTask: Task<Void, Never>?
    @ObservationIgnored private var restrictedCatalogProviders: Set<UUID> = []

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
    @ObservationIgnored private var lastBrowseQuery: BrowseQuery?
    @ObservationIgnored private var firstPageLimit = LibraryModel.pageSize

    private static let pageSize = 200
    private static let pagePrefetchDistance = 40
    private static let pagedThreshold = 3000
    private static let expensiveSupportDataThreshold = 5000
    private static let supportDataSampleLimit = 1200
    private static let statusKey = "imagine.library.status"
    private static let mediaKey = "imagine.library.media"
    private static let sortKey = "imagine.library.sort"
    private static let sortDirectionKey = "imagine.library.sortDirection"
    private static let sortDescriptorsKey = "imagine.library.sortDescriptors"
    private static let sourceKey = "imagine.library.source"
    private static let advancedFiltersKey = "imagine.library.advancedFilters"

    private enum LibraryPagingMode {
        case none
        case recentKeyset
        case sortedOffset
        case comicOffset
        case remoteCursor
    }

    private struct RemoteCatalogKey: Equatable {
        let source: LibrarySourceFilter
        let request: RemoteCatalogRequest
        let scope: RemoteCatalogScope
    }

    private struct RemoteCatalogSession {
        let id = UUID()
        let key: RemoteCatalogKey
        var entries: [CatalogEntry] = []
        var cursor: RemoteCatalogCursor?
    }

    private struct BrowseQuery: Equatable {
        let facet: LibraryFacet
        let status: LibraryStatusFilter
        let media: LibraryMediaFilter
        let readingEnabled: Bool
        let source: LibrarySourceFilter
        let sort: [LibrarySortDescriptor]
        let advancedFilters: LibraryAdvancedFilters
        let search: String
    }

    private unowned let profileSession: ProfileSession?
    private var defaults: UserDefaults { profileSession?.defaults ?? .standard }
    private var preferences: LibraryDisplayPreferencesStore { profileSession?.preferences ?? .shared }
    var readingEnabled: Bool { preferences.readingEnabled }
    var availableMediaFilters: [LibraryMediaFilter] {
        readingEnabled ? LibraryMediaFilter.allCases : [.all, .audiobooks, .podcasts]
    }
    var availableStatusFilters: [LibraryStatusFilter] {
        LibraryStatusFilter.allCases.filter { readingEnabled || $0 != .reading }
    }

    init(profileSession: ProfileSession? = nil) {
        self.profileSession = profileSession
        let defaults = profileSession?.defaults ?? .standard
        selectedStatus = LibraryStatusFilter(rawValue: defaults.string(forKey: Self.statusKey) ?? "") ?? .all
        let sourceFilter = LibrarySourceFilter(rawValue: defaults.string(forKey: Self.sourceKey) ?? "")
        let media = LibraryMediaFilter(rawValue: defaults.string(forKey: Self.sourceMediaKey(sourceFilter)) ?? "")
            ?? LibraryMediaFilter(rawValue: defaults.string(forKey: Self.mediaKey) ?? "") ?? .all
        let browse = LibraryBrowsePreferences.load(media: media, source: sourceFilter, defaults: defaults)
        self.selectedMedia = media
        self.sourceFilter = sourceFilter
        facet = browse.facet
        layout = browse.layout
        let fallbackSort = LibrarySort(rawValue: defaults.string(forKey: Self.sortKey) ?? "") ?? .recent
        let fallbackDirection = LibrarySortDirection(rawValue: defaults.string(forKey: Self.sortDirectionKey) ?? "") ?? .descending
        let descriptors = Self.loadSortDescriptors(defaults: defaults, fallbackSort: fallbackSort, fallbackDirection: fallbackDirection)
        sortDescriptors = descriptors
        sort = descriptors.first?.field ?? fallbackSort
        sortDirection = descriptors.first?.direction ?? fallbackDirection
        advancedFilters =
            defaults.data(forKey: Self.advancedFiltersKey)
            .flatMap { try? JSONDecoder().decode(LibraryAdvancedFilters.self, from: $0) }
            ?? .empty
    }

    var isSearchActive: Bool {
        !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var searchAttribution: String? {
        EnveProvenance.searchAttribution(for: searchQuery)
    }

    var mediaScope: [String] {
        media.mediaTypeRaw.map { [$0] } ?? ["audiobook", "ebook", "podcast"]
    }

    var availableFacets: [LibraryFacet] {
        media == .comics ? LibraryBrowsePreferences.comicsFacets : LibraryFacet.allCases
    }

    func title(for facet: LibraryFacet) -> String {
        media == .comics && facet == .books ? "Issues" : facet.title
    }

    var comicSeriesFilter: ComicSeriesFilter {
        ComicSeriesFilter(status: status, advancedFilters: advancedFilters)
    }

    func select(_ facet: LibraryFacet) {
        guard facet != self.facet else { return }
        self.facet = facet
        LibraryBrowsePreferences.save(facet: facet, media: media, source: sourceFilter, defaults: defaults)
        if facet != .books {
            libraryEndSelection()
        }
        scheduleReload()
    }

    private func applyBrowsePreferences() {
        let browse = LibraryBrowsePreferences.load(media: media, source: sourceFilter, defaults: defaults)
        if facet != browse.facet {
            facet = browse.facet
            if facet != .books { libraryEndSelection() }
        }
        if layout != browse.layout {
            layout = browse.layout
        }
    }

    func select(_ status: LibraryStatusFilter) {
        guard status != self.status else { return }
        self.status = status
        defaults.set(status.rawValue, forKey: Self.statusKey)
        scheduleReload()
    }

    func select(_ media: LibraryMediaFilter) {
        guard media != self.media else { return }
        let changesBrowseScope = media == .comics || self.media == .comics
        self.media = media
        defaults.set(media.rawValue, forKey: Self.sourceMediaKey(sourceFilter))
        defaults.set(media.rawValue, forKey: Self.mediaKey)
        if changesBrowseScope { applyBrowsePreferences() }
        scheduleReload()
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
        setSortDescriptors(descriptors)
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
        setSortDescriptors([])
    }

    func selectLayout(_ layout: LibraryLayout) {
        guard layout != self.layout else { return }
        self.layout = layout
        LibraryBrowsePreferences.save(layout: layout, media: media, source: sourceFilter, defaults: defaults)
    }

    func select(_ source: LibrarySourceFilter) {
        guard source != sourceFilter else { return }
        let previousMedia = media
        defaults.set(selectedMedia.rawValue, forKey: Self.sourceMediaKey(sourceFilter))
        sourceFilter = source
        defaults.set(source.rawValue, forKey: Self.sourceKey)
        if let saved = defaults.string(forKey: Self.sourceMediaKey(source)), let selected = LibraryMediaFilter(rawValue: saved) {
            media = selected
        }
        defaults.set(selectedMedia.rawValue, forKey: Self.mediaKey)
        if previousMedia == .comics || media == .comics { applyBrowsePreferences() }
        scheduleReload()
    }

    func focus(status: LibraryStatusFilter, media: LibraryMediaFilter, source: LibrarySourceFilter, facet: LibraryFacet = .books) {
        var changed = false
        if self.status != status {
            self.status = status
            defaults.set(status.rawValue, forKey: Self.statusKey)
            changed = true
        }
        let changesBrowseScope = (media == .comics || self.media == .comics) && (self.media != media || sourceFilter != source)
        if self.media != media {
            self.media = media
            defaults.set(media.rawValue, forKey: Self.mediaKey)
            changed = true
        }
        if sourceFilter != source {
            sourceFilter = source
            defaults.set(source.rawValue, forKey: Self.sourceKey)
            changed = true
        }
        defaults.set(selectedMedia.rawValue, forKey: Self.sourceMediaKey(source))
        if changesBrowseScope {
            applyBrowsePreferences()
        }
        if self.facet != facet {
            self.facet = facet
            LibraryBrowsePreferences.save(facet: facet, media: media, source: source, defaults: defaults)
            changed = true
        }
        if changed {
            libraryEndSelection()
            scheduleReload()
        }
    }

    var isNarrowed: Bool {
        activeFilterCount > 0
    }

    var activeFilterCount: Int {
        var count = 0
        if status != .all { count += 1 }
        if media != .all { count += 1 }
        if advancedFilters.minimumRating != nil { count += 1 }
        if advancedFilters.series != .all { count += 1 }
        count += advancedFilters.genres.count
        count += advancedFilters.languages.count
        return count
    }

    var resultSummary: String {
        let loaded = books.count
        switch remoteCatalog {
        case .loading: return "Loading"
        case .loaded(hasMore: true): return "\(loaded.formatted()) loaded"
        case .onDeviceOnly: return "\(loaded.formatted()) on this device"
        case .failed: return "Unavailable"
        case .loaded(hasMore: false), nil: break
        }
        if resultTotalCount > loaded {
            return "\(loaded.formatted()) of \(resultTotalCount.formatted()) loaded"
        }
        if media == .comics {
            return ComicSeriesFormat.issueCount(loaded)
        }
        return loaded == 1 ? "1 book" : "\(loaded.formatted()) books"
    }

    func isDownloaded(_ book: Book) -> Bool {
        if book.mediaType == .ebook { return downloadedBookIds.contains(book.uniqueId) }
        let storage = profileSession?.localStorage ?? LocalStorageManager.shared
        return storage.isAudiobookDownloaded(book, downloadedIds: downloadedAudioStorageKeys)
            && storage.isAudiobookDownloaded(book)
    }

    func clearFilters() {
        let leavesComics = media == .comics
        status = .all
        media = .all
        advancedFilters = .empty
        defaults.set(LibraryStatusFilter.all.rawValue, forKey: Self.statusKey)
        defaults.set(LibraryMediaFilter.all.rawValue, forKey: Self.mediaKey)
        defaults.set(LibraryMediaFilter.all.rawValue, forKey: Self.sourceMediaKey(sourceFilter))
        defaults.removeObject(forKey: Self.advancedFiltersKey)
        if leavesComics { applyBrowsePreferences() }
        scheduleReload()
    }

    var hasAdditionalDownloadFilters: Bool {
        sourceFilter != .all || media != .all || advancedFilters.isActive
    }

    func clearAdditionalDownloadFilters() {
        setAdvancedFilters(.empty)
        focus(status: .downloaded, media: .all, source: .all)
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

    var usesServerFilterOptions: Bool {
        let library = (profileSession?.engine ?? EnveEngine.shared).library
        return status == .all && media != .comics && media != .podcasts && library.supportsRemoteCatalog(sourceFilter)
    }

    var usesServerCatalogFilters: Bool {
        remoteCatalogRequest(library: (profileSession?.engine ?? EnveEngine.shared).library) != nil
    }

    var advancedFilterOptionsScope: String {
        "\(sourceFilter)|\(media)|\(status)|\(readingEnabled)"
    }

    func loadAdvancedFilterOptions(search: String = "") async {
        guard profileSession?.isRetired != true else { return }
        filterOptionsGeneration += 1
        let generation = filterOptionsGeneration
        isLoadingAdvancedFilterOptions = true
        advancedFilterOptionsError = nil
        defer { if generation == filterOptionsGeneration { isLoadingAdvancedFilterOptions = false } }
        let library = (profileSession?.engine ?? EnveEngine.shared).library
        let media = media
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let options: LibraryAdvancedFilterOptions
        var hasMore = false
        var error: String?
        if usesServerFilterOptions {
            let result = await library.remoteCatalogFilterOptions(
                sourceFilter: sourceFilter, mediaType: remoteMediaType, search: query
            )
            options = LibraryAdvancedFilterOptions(genres: result.options.genres, languages: result.options.languages)
            hasMore = result.options.hasMore
            if !result.issues.isEmpty {
                error = result.issues.map { "\($0.sourceName): \($0.message ?? "Showing downloads on this device.")" }.joined(separator: "\n")
            }
        } else {
            let list = await sourceScopedBooks(library: library, mediaType: nil, boundedForSupportData: true)
                .filter { media.matches($0) && (status == .downloaded || library.matchesStatus($0, status: status)) }
            let local = LibraryAdvancedFilterPolicy.options(from: list)
            options = LibraryAdvancedFilterOptions(
                genres: local.genres.filter { query.isEmpty || $0.localizedStandardContains(query) },
                languages: local.languages.filter { query.isEmpty || $0.localizedStandardContains(query) }
            )
        }
        guard generation == filterOptionsGeneration, !Task.isCancelled, profileSession?.isRetired != true else { return }
        advancedFilterOptions = options
        hasMoreAdvancedFilterOptions = hasMore
        advancedFilterOptionsError = error
    }

    private func setAdvancedFilters(_ filters: LibraryAdvancedFilters) {
        guard filters != advancedFilters else { return }
        advancedFilters = filters
        if filters.isActive, let data = try? JSONEncoder().encode(filters) {
            defaults.set(data, forKey: Self.advancedFiltersKey)
        } else {
            defaults.removeObject(forKey: Self.advancedFiltersKey)
        }
        scheduleReload()
    }

    var sortSummary: String {
        sortDescriptors.map(\.summary).joined(separator: " -> ")
    }

    var usesDefaultSorting: Bool {
        sortDescriptors.isEmpty || sortDescriptors == [Self.defaultSortDescriptor]
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
            return uniqueSortDescriptors(decoded)
        }
        return [LibrarySortDescriptor(field: fallbackSort, direction: fallbackDirection)]
    }

    private func setSortDescriptors(_ descriptors: [LibrarySortDescriptor]) {
        let descriptors = Self.uniqueSortDescriptors(descriptors)
        guard descriptors != sortDescriptors else { return }
        sortDescriptors = descriptors
        syncPrimarySort()
        persistSortDescriptors()
        scheduleReload()
    }

    private func syncPrimarySort() {
        let primary = sortDescriptors.first ?? Self.defaultSortDescriptor
        sort = primary.field
        sortDirection = primary.direction
    }

    private func persistSortDescriptors() {
        let defaults = self.defaults
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
            $0.source != .local && !(profileSession?.engine ?? EnveEngine.shared).downloads.isLibraryDownloaded($0)
        }
        libraryEndSelection()
        guard !targets.isEmpty else { return }
        PlatformHaptics.impact(.light)
        Task { [profileSession] in
            defer { withExtendedLifetime(profileSession) {} }
            guard profileSession?.isRetired != true else { return }
            for book in targets {
                await (profileSession?.engine ?? EnveEngine.shared).downloads.download(book)
            }
        }
    }

    func playSelected() {
        let targets = selectedBooks
        guard (profileSession?.engine ?? EnveEngine.shared).playback.playAll(targets, groupKey: "selection") else { return }
        libraryEndSelection()
        PlatformHaptics.impact(.medium)
    }

    func queueSelected() {
        let targets = selectedBooks.filter { $0.mediaType != .ebook }
        libraryEndSelection()
        guard !targets.isEmpty else { return }
        (profileSession?.engine ?? EnveEngine.shared).playback.addLast(targets, groupKey: "selection")
        PlatformHaptics.impact(.light)
    }

    func removeSelectedDownloads() {
        let targets = selectedBooks.filter {
            $0.source != .local && (profileSession?.engine ?? EnveEngine.shared).downloads.isLibraryDownloaded($0)
        }
        libraryEndSelection()
        guard !targets.isEmpty else { return }
        PlatformHaptics.impact(.medium)
        for book in targets {
            Task { [profileSession] in
                defer { withExtendedLifetime(profileSession) {} }
                guard profileSession?.isRetired != true else { return }
                await (profileSession?.engine ?? EnveEngine.shared).downloads.removeLibraryDownload(for: book)
            }
        }
    }

    func markSelectedFinished() {
        let targets = selectedBooks.filter { !$0.isFinished }
        libraryEndSelection()
        guard !targets.isEmpty else { return }
        PlatformHaptics.impact(.light)
        for book in targets {
            _ = (profileSession?.engine ?? EnveEngine.shared).library.toggleFinished(book)
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
        remoteSession?.entries.removeAll { ids.contains($0.book.uniqueId) }
    }

    func updateSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed != searchQuery.trimmingCharacters(in: .whitespaces) {
            invalidateRemoteCatalog()
        }
        if trimmed.isEmpty {
            guard isSearchActive else { return }
            searchQuery = ""
            if facet != .books {
                libraryEndSelection()
            }
            scheduleReload()
            return
        }
        searchTask = Task { [profileSession] in
            defer { withExtendedLifetime(profileSession) {} }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, profileSession?.isRetired != true else { return }
            searchQuery = text
            await reload()
        }
    }

    func bootstrap() async {
        guard !hasLoaded else { return }
        if let id = sourceFilter.providerId,
            !(profileSession?.engine ?? EnveEngine.shared).library.hasConnection(id: id)
        {
            sourceFilter = .all
            defaults.set(LibrarySourceFilter.all.rawValue, forKey: Self.sourceKey)
            if media == .comics { applyBrowsePreferences() }
        }
        await reload()
    }

    private func scheduleReload() {
        invalidateRemoteCatalog()
        let session = profileSession
        Task { [weak self] in
            defer { withExtendedLifetime(session) {} }
            guard let self, session?.isRetired != true else { return }
            await reload()
        }
    }

    func reload() async {
        let session = profileSession
        defer { withExtendedLifetime(session) {} }
        guard session?.isRetired != true else { return }
        generation &+= 1
        let gen = generation
        let library = (profileSession?.engine ?? EnveEngine.shared).library
        if readingEnabled, defaults.string(forKey: Self.sourceMediaKey(sourceFilter)) == nil,
            let providerId = sourceFilter.providerId, let libraryId = sourceFilter.libraryId {
            let typedComicLibrary = (profileSession?.engine ?? EnveEngine.shared).sources.librarySourceSnapshot.libraries.contains {
                $0.providerId == providerId && $0.id == libraryId && $0.isComic
            }
            let comicCount = typedComicLibrary || library.supportsRemoteCatalog(sourceFilter)
                ? 0 : await library.comicBookCount(sourceFilter: sourceFilter)
            let total = comicCount > 0 ? await library.bookCount(sourceFilter: sourceFilter, mediaType: "ebook") : 0
            if typedComicLibrary || (comicCount > 0 && comicCount == total) {
                media = .comics
                applyBrowsePreferences()
                defaults.set(media.rawValue, forKey: Self.sourceMediaKey(sourceFilter))
                defaults.set(media.rawValue, forKey: Self.mediaKey)
            }
        }
        if lastBrowseQuery?.readingEnabled != readingEnabled {
            applyBrowsePreferences()
        }
        let query = BrowseQuery(
            facet: facet,
            status: status,
            media: media,
            readingEnabled: readingEnabled,
            source: sourceFilter,
            sort: sortDescriptors,
            advancedFilters: advancedFilters,
            search: searchQuery
        )
        if query == lastBrowseQuery {
            firstPageLimit = max(rawPages.count, Self.pageSize)
        } else {
            firstPageLimit = Self.pageSize
            lastBrowseQuery = query
        }
        excludedLibraryKeys = (profileSession?.preferences ?? LibraryDisplayPreferencesStore.shared).loadPreferences().excludedLibraryIds
        if let request = remoteCatalogRequest(library: library) {
            await loadRemoteCatalog(request, library: library)
            return
        }
        endRemoteCatalog()
        restrictedCatalogProviders = status == .downloaded ? [] : library.unreachableCatalogProviderIds(for: sourceFilter)
        localScopeNotice = localOnlyNotice(library: library)
        // A query needs neither a fresh catalog count, the work index, nor a walk of every download.
        let searchesOnly = isSearchActive && query.status != .downloaded
        let storage = session?.localStorage ?? LocalStorageManager.shared
        let audioKeys = Set(storage.downloadedAudiobookIds())
        if searchesOnly {
            offlineBooks = []
        } else {
            totalLibraryCount = await library.totalBookCount()
            if facet == .books || isSearchActive {
                if query.status != .downloaded, readingEnabled, await shouldBuildWorkIndex(library: library) {
                    await rebuildWorkIndex()
                } else {
                    workHiddenIds = []
                    workRefByRep = [:]
                    libraryRecollapse()
                }
            }
            let downloadedEbooks = await library.downloadedEbooks(limit: max(totalLibraryCount, 1))
            let downloadedAudio = query.status == .downloaded ? await library.downloadedAudiobooks(storageKeys: audioKeys) : []
            guard gen == generation else { return }
            downloadedBookIds = Set(downloadedEbooks.map(\.uniqueId))
            offlineBooks = query.status == .downloaded ? downloadedEbooks + downloadedAudio : []
        }
        downloadedAudioStorageKeys = audioKeys

        if isSearchActive {
            let results: [Book]
            if status == .downloaded {
                results = RemoteCatalogRequest(search: searchQuery, mediaType: nil, sort: .title).onDeviceBooks(
                    from: offlineBooks, providerId: sourceFilter.providerId, libraryId: sourceFilter.libraryId,
                    isOnDevice: { _ in true }
                )
            } else {
                results = await library.searchBooks(query: searchQuery, sourceFilter: sourceFilter, limit: 200)
            }
            guard gen == generation else { return }
            let media = media
            let offlineIDs = Set(offlineBooks.map(\.uniqueId))
            let kept = results.filter {
                media.matches($0)
                    && (status == .downloaded ? offlineIDs.contains($0.uniqueId) : library.matchesStatus($0, status: status))
                    && libraryMatchesSource($0)
                    && LibraryAdvancedFilterPolicy.matches($0, filters: advancedFilters)
            }
            if searchesOnly {
                let ids = await library.offlineBookIDs(in: kept.filter { $0.mediaType == .ebook })
                guard gen == generation else { return }
                downloadedBookIds = ids
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
        if status != .downloaded && (!readingEnabled || advancedFilters.isActive || (media == .comics && status != .all)) {
            await presentStatusScopedBooks(library: library, gen: gen)
            return
        }
        switch status {
        case .all:
            if media == .comics {
                await loadComics(gen: gen, library: library)
                return
            }
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
                        let first = await library.pagedBooks(sourceFilter: sourceFilter, mediaType: raw, after: nil, limit: firstPageLimit)
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
                        let first = await library.pagedBooks(sourceFilter: sourceFilter, mediaType: raw, after: nil, limit: firstPageLimit)
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
                    let first = await library.pagedBooks(sourceFilter: sourceFilter, mediaType: raw, after: nil, limit: firstPageLimit)
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
            await present(offlineBooks, gen: gen)
        }
    }

    private func presentStatusScopedBooks(library: LibraryEngine, gen: Int) async {
        let list = await sourceScopedBooks(library: library, mediaType: media.mediaTypeRaw, boundedForSupportData: readingEnabled && media != .comics)
        await present(library.filterStatus(list, status: status), gen: gen)
    }

    private func present(_ list: [Book], gen: Int) async {
        var kept = list.filter(media.matches)
        kept = kept.filter(libraryMatchesSource)
        kept = kept.filter { LibraryAdvancedFilterPolicy.matches($0, filters: advancedFilters) }
        guard gen == generation else { return }
        rawPages = []
        pageCursor = nil
        pageOffset = 0
        pagingMode = .none
        isPagedMode = false
        books = (profileSession?.engine ?? EnveEngine.shared).library.applySort(kept, descriptors: sortDescriptors)
        resultTotalCount = kept.count
    }

    func loadNextPageIfNeeded(currentBookId: String) {
        let triggerIndex = max(displayBooks.count - Self.pagePrefetchDistance, 0)
        guard isPagedMode, !isLoadingNextPage,
            let visibleIndex = displayBooks.firstIndex(where: { $0.uniqueId == currentBookId }),
            visibleIndex >= triggerIndex,
            pagingMode != .none
        else { return }
        if pagingMode == .remoteCursor {
            if remotePageError == nil { loadNextRemotePage() }
            return
        }
        guard !isSearchActive else { return }
        isLoadingNextPage = true
        let gen = generation
        let mode = pagingMode
        let cursor = pageCursor
        let offset = pageOffset
        Task { [profileSession] in
            defer { withExtendedLifetime(profileSession) {} }
            guard profileSession?.isRetired != true else { return }
            let library = (profileSession?.engine ?? EnveEngine.shared).library
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
            case .comicOffset:
                next = await library.comicBooksPage(sourceFilter: sourceFilter, offset: offset, limit: Self.pageSize, sort: storeSortDescriptors)
            case .none, .remoteCursor:
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
            case .comicOffset:
                pageOffset = offset + next.count
                if next.count < Self.pageSize { pagingMode = .none }
            case .none, .remoteCursor:
                pagingMode = .none
            }
            let media = media
            let kept = rawPages.filter {
                libraryMatchesSource($0) && media.matches($0)
            }
            books = kept
        }
    }

    private func beginSortedPaging(gen: Int, library: LibraryEngine) async {
        let limit = firstPageLimit
        let first = await loadSortedPage(library: library, offset: 0, limit: limit)
        guard gen == generation else { return }
        rawPages = first
        pageCursor = nil
        pageOffset = limit
        pagingMode = first.isEmpty ? .none : .sortedOffset
        isPagedMode = pagingMode != .none
        books = first.filter(libraryMatchesSource)
    }

    private func loadComics(gen: Int, library: LibraryEngine) async {
        let count = await library.comicBookCount(sourceFilter: sourceFilter)
        guard gen == generation else { return }
        resultTotalCount = count
        if count > Self.pagedThreshold {
            let limit = firstPageLimit
            let first = await library.comicBooksPage(sourceFilter: sourceFilter, offset: 0, limit: limit, sort: storeSortDescriptors)
            guard gen == generation else { return }
            rawPages = first
            pageCursor = nil
            pageOffset = first.count
            pagingMode = first.count < limit ? .none : .comicOffset
            isPagedMode = true
            books = first.filter { libraryMatchesSource($0) && media.matches($0) }
        } else {
            let all = await library.comicBooksPage(sourceFilter: sourceFilter, offset: 0, limit: max(count, 1), sort: storeSortDescriptors)
            guard gen == generation else { return }
            rawPages = []
            pageCursor = nil
            pageOffset = 0
            pagingMode = .none
            isPagedMode = false
            let kept = all.filter { libraryMatchesSource($0) && media.matches($0) }
            books = library.applySort(kept, descriptors: sortDescriptors)
        }
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

    func refreshFromServer() async {
        remoteTask?.cancel()
        remoteSession = nil
        await reload()
    }

    @discardableResult
    func loadMoreRemote() -> Task<Void, Never>? {
        remotePageError = nil
        return loadNextRemotePage()
    }

    private var remoteSort: RemoteCatalogSort? {
        let primary = sortDescriptors.first ?? Self.defaultSortDescriptor
        switch (primary.field, primary.direction) {
        case (.title, .ascending): return .title
        case (.recent, .descending): return .recentlyAdded
        default: return nil
        }
    }

    private var remoteMediaType: AppMediaType? {
        switch media {
        case .all: readingEnabled ? nil : .audiobook
        case .audiobooks: .audiobook
        case .ebooks: .ebook
        case .comics, .podcasts: nil
        }
    }

    private func remoteCatalogRequest(library: LibraryEngine) -> RemoteCatalogRequest? {
        guard facet == .books || isSearchActive, status == .all,
            advancedFilters.minimumRating == nil, advancedFilters.series == .all,
            media != .comics, media != .podcasts, library.supportsRemoteCatalog(sourceFilter)
        else { return nil }
        let search = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return RemoteCatalogRequest(
            search: search.isEmpty ? nil : search, mediaType: remoteMediaType, sort: remoteSort ?? .title,
            genres: advancedFilters.genres, languages: advancedFilters.languages
        )
    }

    private func localOnlyNotice(library: LibraryEngine) -> String? {
        guard status != .downloaded, media != .podcasts, library.supportsRemoteCatalog(sourceFilter) else { return nil }
        if !restrictedCatalogProviders.isEmpty {
            return "Server unavailable. Its books are limited to downloads on this device."
        }
        return facet == .books || isSearchActive
            ? "These filters use cached server listings, which may be incomplete."
            : "\(facet.title) use cached server listings, which may be incomplete."
    }

    private func loadRemoteCatalog(_ request: RemoteCatalogRequest, library: LibraryEngine) async {
        localScopeNotice = remoteSort == nil ? "Server sources sort by title or date added." : nil
        restrictedCatalogProviders = []
        workHiddenIds = []
        workRefByRep = [:]
        rawPages = []
        pageCursor = nil
        pageOffset = 0
        resultTotalCount = 0
        let key = RemoteCatalogKey(source: sourceFilter, request: request, scope: library.remoteCatalogScope(for: sourceFilter))
        if let current = remoteSession, current.key == key {
            switch remoteCatalog {
            case .loading:
                return
            case .loaded where !remoteIssues.contains(where: { $0.message == nil }):
                let restored = await library.presentableBooks(for: current.entries)
                await presentRemote(restored, appending: false, library: library, sessionId: current.id)
                return
            case .loaded, .onDeviceOnly, .failed, nil:
                break
            }
        }

        remoteTask?.cancel()
        let session = RemoteCatalogSession(key: key)
        remoteSession = session
        isLoadingNextPage = false
        isLoadingRemotePage = false
        remotePageError = nil
        remoteIssues = []
        pagingMode = .none
        isPagedMode = false
        books = []
        remoteCatalog = .loading
        hasLoaded = true

        let id = session.id
        let task = Task { [weak self, profileSession] in
            defer { withExtendedLifetime(profileSession) {} }
            guard let self else { return }
            defer {
                if remoteSession?.id == id { isLoadingRemotePage = false }
            }
            let result = await library.remoteCatalogPage(sourceFilter: key.source, request: request, after: nil) { [weak self] entries in
                guard let self, !Task.isCancelled, self.isCurrentRemoteSession(id, library: library) else { return }
                self.remoteSession?.entries = entries
                let partial = await library.presentableBooks(for: entries)
                guard await self.presentRemote(partial, appending: false, library: library, sessionId: id) else { return }
                self.remoteCatalog = .loaded(hasMore: true)
                self.isLoadingRemotePage = true
            }
            guard !Task.isCancelled, isCurrentRemoteSession(id, library: library) else { return }
            remoteSession?.entries = result.entries
            remoteSession?.cursor = result.next
            remoteIssues = result.issues
            if !result.reachedSource, let failure = result.issues.first(where: { $0.message != nil }),
                !result.issues.contains(where: { $0.message == nil })
            {
                books = []
                remoteCatalog = .failed(failure.message ?? "")
                return
            }
            guard await presentRemote(result.books, appending: false, library: library, sessionId: id) else { return }
            remoteCatalog = result.reachedSource || result.issues.isEmpty
                ? .loaded(hasMore: result.next != nil) : .onDeviceOnly
            pagingMode = result.next == nil ? .none : .remoteCursor
            isPagedMode = result.next != nil
        }
        remoteTask = task
        await task.value
    }

    @discardableResult
    private func loadNextRemotePage() -> Task<Void, Never>? {
        let library = (profileSession?.engine ?? EnveEngine.shared).library
        guard let session = remoteSession, let cursor = session.cursor, !isLoadingRemotePage,
            isCurrentRemoteSession(session.id, library: library)
        else { return nil }
        isLoadingNextPage = true
        isLoadingRemotePage = true
        remotePageError = nil
        let id = session.id
        let key = session.key
        remoteTask = Task { [weak self, profileSession] in
            defer { withExtendedLifetime(profileSession) {} }
            guard let self else { return }
            defer {
                if remoteSession?.id == id {
                    isLoadingNextPage = false
                    isLoadingRemotePage = false
                }
            }
            let result = await library.remoteCatalogPage(sourceFilter: key.source, request: key.request, after: cursor)
            guard !Task.isCancelled, isCurrentRemoteSession(id, library: library) else { return }
            let known = Set(remoteSession?.entries.map(\.book.uniqueId) ?? [])
            remoteSession?.entries.append(contentsOf: result.entries.filter { !known.contains($0.book.uniqueId) })
            for issue in result.issues where !remoteIssues.contains(issue) {
                remoteIssues.append(issue)
            }
            if !result.reachedSource, result.entries.isEmpty, let failure = result.issues.first(where: { $0.message != nil }) {
                remotePageError = failure.message
                return
            }
            let lost = Set(result.issues.filter { $0.message == nil }.map(\.providerId))
            if !lost.isEmpty {
                restrictedCatalogProviders.formUnion(lost)
                remoteSession?.entries.removeAll { lost.contains($0.book.providerId) && !library.isOnDevice($0.book) }
                books = books.filter(libraryMatchesSource)
            }
            remoteSession?.cursor = result.next
            guard await presentRemote(
                result.books.filter { !known.contains($0.uniqueId) },
                appending: true,
                library: library,
                sessionId: id
            ) else { return }
            if case .loaded = remoteCatalog {
                let hasRemoteCards = remoteSession?.entries.contains { !library.isOnDevice($0.book) } == true
                remoteCatalog = result.reachedSource || lost.isEmpty || hasRemoteCards || result.next != nil
                    ? .loaded(hasMore: result.next != nil) : .onDeviceOnly
            }
            if result.next == nil {
                pagingMode = .none
                isPagedMode = false
            }
        }
        return remoteTask
    }

    @discardableResult
    private func presentRemote(_ list: [Book], appending: Bool, library: LibraryEngine, sessionId: UUID) async -> Bool {
        let audioKeys = Set((profileSession?.localStorage ?? LocalStorageManager.shared).downloadedAudiobookIds())
        let ebookIds = await library.offlineBookIDs(in: list.filter { $0.mediaType == .ebook })
        guard !Task.isCancelled, isCurrentRemoteSession(sessionId, library: library) else { return false }
        downloadedAudioStorageKeys = audioKeys
        let kept = list.filter(libraryMatchesSource)
        if appending {
            downloadedBookIds.formUnion(ebookIds)
            books.append(contentsOf: kept)
        } else {
            downloadedBookIds = ebookIds
            books = kept
        }
        return true
    }

    private func isCurrentRemoteSession(_ id: UUID, library: LibraryEngine) -> Bool {
        guard profileSession?.isRetired != true, let session = remoteSession, session.id == id else { return false }
        guard library.remoteCatalogScope(for: session.key.source) == session.key.scope else {
            scheduleReload()
            return false
        }
        return true
    }

    private func endRemoteCatalog() {
        guard remoteSession != nil || remoteCatalog != nil else { return }
        remoteTask?.cancel()
        remoteTask = nil
        remoteSession = nil
        remoteCatalog = nil
        remoteIssues = []
        if isLoadingRemotePage { isLoadingNextPage = false }
        isLoadingRemotePage = false
        remotePageError = nil
        if pagingMode == .remoteCursor { pagingMode = .none }
    }

    // Runs as the query changes, before any debounce, so a slower superseded response can never be shown under the new query.
    private func invalidateRemoteCatalog() {
        guard remoteSession != nil || remoteCatalog != nil else { return }
        remoteTask?.cancel()
        remoteTask = nil
        remoteSession = nil
        if isLoadingRemotePage { isLoadingNextPage = false }
        isLoadingRemotePage = false
        remotePageError = nil
        remoteIssues = []
        pagingMode = .none
        isPagedMode = false
        books = []
        remoteCatalog = .loading
    }

    private static func sourceMediaKey(_ source: LibrarySourceFilter) -> String {
        "imagine.library.source.media.\(source.rawValue)"
    }

    private func libraryMatchesSource(_ book: Book) -> Bool {
        guard preferences.includesLibraryBook(book) else { return false }
        if (!NetworkPolicyService.shared.isConnected || restrictedCatalogProviders.contains(book.providerId)),
            !(profileSession?.engine ?? EnveEngine.shared).library.isOnDevice(book)
        {
            return false
        }
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
        let index = await (profileSession?.engine ?? EnveEngine.shared).library.workIndex()
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
        let isSourceOnly = readingEnabled && status == .all && !advancedFilters.isActive && excludedLibraryKeys.isEmpty
            && restrictedCatalogProviders.isEmpty
        let merged: [BrowseSeriesAggregate]
        switch sourceFilter {
        case .all where isSourceOnly:
            merged = await library.seriesAggregates(mediaScope: mediaScope)
        case .connection(let providerId) where isSourceOnly:
            merged = await library.seriesAggregates(mediaScope: mediaScope, providerId: providerId)
        case .library(let providerId, let libraryId) where isSourceOnly:
            merged = await library.seriesAggregates(mediaScope: mediaScope, providerId: providerId, libraryId: libraryId)
        default:
            let books = await sourceScopedBooksForCurrentMedia(library: library, boundedForSupportData: readingEnabled && media != .comics)
            merged = library.seriesAggregates(from: books)
        }
        guard gen == generation else { return }
        seriesAggregates = media == .comics ? merged.filter(\.isComic) : merged
        loadedAggregateFacets.insert(.series)
    }

    private func loadAuthorAggregates(gen: Int, library: LibraryEngine) async {
        if !readingEnabled || sourceFilter != .all || status != .all || advancedFilters.isActive || !restrictedCatalogProviders.isEmpty {
            let books = await sourceScopedBooksForCurrentMedia(library: library, boundedForSupportData: readingEnabled)
            let merged = library.authorAggregates(from: books)
            guard gen == generation else { return }
            if authorAggregates != merged { authorAggregates = merged }
            loadedAggregateFacets.insert(.authors)
            return
        }

        let merged = await library.authorAggregates(mediaScope: mediaScope)
        guard gen == generation, !Task.isCancelled else { return }
        if authorAggregates != merged { authorAggregates = merged }
        loadedAggregateFacets.insert(.authors)
    }

    private func loadNarratorAggregates(gen: Int, library: LibraryEngine) async {
        if !readingEnabled || sourceFilter != .all || status != .all || advancedFilters.isActive || !restrictedCatalogProviders.isEmpty {
            let books = await sourceScopedBooksForCurrentMedia(library: library, boundedForSupportData: readingEnabled)
            let merged = library.narratorAggregates(from: books)
            guard gen == generation else { return }
            narratorAggregates = merged
            loadedAggregateFacets.insert(.narrators)
            return
        }

        let merged = await library.narratorAggregates(mediaScope: mediaScope)
        guard gen == generation else { return }
        narratorAggregates = merged
        loadedAggregateFacets.insert(.narrators)
    }

    private func loadGenreAggregates(gen: Int, library: LibraryEngine) async {
        if !readingEnabled || sourceFilter != .all || status != .all || advancedFilters.isActive || !restrictedCatalogProviders.isEmpty {
            let books = await sourceScopedBooksForCurrentMedia(library: library, boundedForSupportData: readingEnabled)
            let merged = library.genreAggregates(from: books)
            guard gen == generation else { return }
            genreAggregates = merged
            loadedAggregateFacets.insert(.genres)
            return
        }

        let merged = await library.genreAggregates(mediaScope: mediaScope)
        guard gen == generation else { return }
        genreAggregates = merged
        loadedAggregateFacets.insert(.genres)
    }

    func books(forGenre aggregate: BrowseGenreAggregate) async -> [Book] {
        let library = (profileSession?.engine ?? EnveEngine.shared).library
        if readingEnabled, sourceFilter == .all, status == .all, !advancedFilters.isActive, restrictedCatalogProviders.isEmpty {
            return await library.books(forGenre: aggregate, mediaScope: mediaScope)
        }
        let matchingKeys = Set(aggregate.matchingGenres.map(Self.genreLookupKey))
        return await sourceScopedBooksForCurrentMedia(library: library, boundedForSupportData: readingEnabled)
            .filter { book in
                (book.genres ?? []).contains { matchingKeys.contains(Self.genreLookupKey($0)) }
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func sourceScopedBooksForCurrentMedia(library: LibraryEngine, boundedForSupportData: Bool = false) async -> [Book] {
        let media = media
        return await sourceScopedBooks(library: library, mediaType: nil, boundedForSupportData: boundedForSupportData)
            .filter { media.matches($0) && (status == .downloaded || library.matchesStatus($0, status: status)) }
            .filter { LibraryAdvancedFilterPolicy.matches($0, filters: advancedFilters) }
    }

    private func sourceScopedBooks(
        library: LibraryEngine,
        mediaType: String?,
        boundedForSupportData: Bool = false
    ) async -> [Book] {
        if status == .downloaded { return offlineBooks.filter(libraryMatchesSource) }
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
        remoteSession?.entries.removeAll { $0.book.uniqueId == book.uniqueId }
    }

    static func markHidden(_ book: Book, profileSession: ProfileSession? = nil) {
        markHidden([book], profileSession: profileSession)
    }

    static func markHidden(_ booksToHide: [Book], profileSession: ProfileSession? = nil) {
        guard !booksToHide.isEmpty else { return }
        Task {
            defer { withExtendedLifetime(profileSession) {} }
            guard profileSession?.isRetired != true else { return }
            await (profileSession?.engine ?? EnveEngine.shared).library.hideFromLibrary(booksToHide)
        }
        PlatformHaptics.impact(.light)
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
