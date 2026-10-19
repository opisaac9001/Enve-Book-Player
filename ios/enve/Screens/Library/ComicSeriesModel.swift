import Foundation
import Observation

struct ComicSeriesFilter: Equatable {
    var status: LibraryStatusFilter = .all
    var advancedFilters: LibraryAdvancedFilters = .empty

    func includes(_ book: Book, library: LibraryEngine, offlineIDs: Set<String> = []) -> Bool {
        (status == .downloaded ? offlineIDs.contains(book.uniqueId) : library.matchesStatus(book, status: status, downloadedIds: []))
            && LibraryAdvancedFilterPolicy.matches(book, filters: advancedFilters)
    }
}

@Observable
final class ComicSeriesModel {
    enum LoadState: Equatable { case idle, loading, failed }

    private(set) var aggregate: BrowseSeriesAggregate
    private(set) var grouping = ComicSeriesGrouping(books: [])
    private(set) var hasLoaded = false
    private(set) var offlineIds: Set<String> = []
    private(set) var resumeBook: Book?
    private(set) var selectedSection: ComicSection?
    private(set) var sliceStates: [ComicSeriesSlice: LoadState] = [:]
    var expandedVolumeIds: Set<String> = []

    // Paging uses raw counts even when the incoming aggregate is filtered.
    private var rawAggregate: BrowseSeriesAggregate
    @ObservationIgnored private var loaded: [ComicSeriesSlice: [Book]] = [:]
    @ObservationIgnored private var fetched: [ComicSeriesSlice: Int] = [:]
    @ObservationIgnored private var exhausted: Set<ComicSeriesSlice> = []
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var needsRefresh = false
    @ObservationIgnored private var filter: ComicSeriesFilter
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    private let mediaScope: [String]
    private let library: LibraryEngine

    static let pageSize = 200

    init(aggregate: BrowseSeriesAggregate, mediaScope: [String], filter: ComicSeriesFilter, library: LibraryEngine) {
        self.aggregate = aggregate
        rawAggregate = aggregate
        self.mediaScope = mediaScope
        self.filter = filter
        self.library = library
        selectedSection = aggregate.sections.first?.section
    }

    var sections: [ComicSeriesSectionSummary] {
        if !aggregate.sections.isEmpty { return aggregate.sections }
        if !rawAggregate.sections.isEmpty { return rawAggregate.sections }
        return [ComicSeriesSectionSummary(section: .issues, count: aggregate.bookCount)]
    }

    private var books: [Book] { loaded.values.flatMap { $0 } }

    private var isFiltered: Bool { filter.status != .all || filter.advancedFilters.isActive }

    var continueBook: Book? {
        if let resumeBook, filter.includes(resumeBook, library: library, offlineIDs: offlineIds) {
            return books.first { $0.uniqueId == resumeBook.uniqueId } ?? resumeBook
        }
        return grouping.nextUnread ?? grouping.orderedBooks.first
    }

    private var hasLoadedEverything: Bool { rawSlices.allSatisfy { !hasMore($0) } }

    var totalCount: Int { hasLoadedEverything ? grouping.bookCount : aggregate.bookCount }
    var unreadCount: Int {
        hasLoadedEverything ? grouping.orderedBooks.count { !$0.isCompleted } : aggregate.unreadBookCount
    }

    var showsEmptyState: Bool {
        let section = selectedSection ?? .issues
        guard hasLoaded, volumeSummaries(in: section).isEmpty else { return false }
        guard let slice = primarySlice(in: section) else { return true }
        return looseBooks(in: section).isEmpty && state(of: slice) == .idle && !hasMore(slice)
    }

    func book(uniqueId: String) -> Book? { books.first { $0.uniqueId == uniqueId } }

    func volumeSummaries(in section: ComicSection) -> [ComicVolumeSummary] {
        let source = isFiltered || !aggregate.volumes.isEmpty ? aggregate.volumes : rawAggregate.volumes
        return source
            .filter { $0.section == section && $0.count > 0 }
            .enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.order, rhs.element.order) {
                case let (l?, r?) where l != r: return l < r
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    func looseCount(in section: ComicSection) -> Int {
        let total = sections.first { $0.section == section }?.count ?? 0
        return max(0, total - volumeSummaries(in: section).reduce(0) { $0 + $1.count })
    }

    func directVolume(in section: ComicSection) -> ComicVolumeSummary? {
        let volumes = volumeSummaries(in: section)
        return volumes.count == 1 && looseCount(in: section) == 0 ? volumes[0] : nil
    }

    func looseSlice(in section: ComicSection) -> ComicSeriesSlice? {
        guard directVolume(in: section) == nil, looseCount(in: section) > 0 || volumeSummaries(in: section).isEmpty else { return nil }
        return rawAggregate.volumes.contains { $0.section == section } ? .loose(section) : .section(section)
    }

    func looseBooks(in section: ComicSection) -> [Book] {
        guard let group = grouping.sections.first(where: { $0.section == section }) else { return [] }
        return rawAggregate.volumes.contains { $0.section == section } ? group.looseBooks : group.orderedBooks
    }

    func books(in volume: ComicVolumeSummary) -> [Book] {
        grouping.sections.first { $0.section == volume.section }?.volumes.first { $0.id == volume.id }?.books ?? []
    }

    func state(of slice: ComicSeriesSlice) -> LoadState { sliceStates[slice] ?? .idle }

    func hasFetched(_ slice: ComicSeriesSlice) -> Bool { fetched[slice, default: 0] > 0 }

    func hasMore(_ slice: ComicSeriesSlice) -> Bool {
        !exhausted.contains(slice) && fetched[slice, default: 0] < rawCount(slice)
    }

    func toggleVolume(_ id: String) {
        guard expandedVolumeIds.insert(id).inserted else {
            expandedVolumeIds.remove(id)
            return
        }
        let volume = (rawAggregate.volumes + aggregate.volumes).first { $0.id == id }
        guard let slice = volume?.slice else { return }
        Task { if loaded[slice] == nil { await loadNextPage(slice) } }
    }

    func selectSection(_ section: ComicSection) {
        guard selectedSection != section else { return }
        selectedSection = section
        if hasLoaded { Task { await loadVisibleSlices() } }
    }

    func update(aggregate: BrowseSeriesAggregate) {
        guard aggregate != self.aggregate else { return }
        self.aggregate = aggregate
        scheduleRefresh()
    }

    func update(filter: ComicSeriesFilter) {
        guard filter != self.filter else { return }
        self.filter = filter
        regroup()
        if hasLoaded { Task { await loadVisibleSlices() } }
    }

    func loadInitial() async {
        guard !hasLoaded else { return }
        let resolved = await library.seriesAggregate(for: aggregate)
        guard !Task.isCancelled else { return }
        rawAggregate = resolved
        await resolveResume()
        guard !Task.isCancelled else { return }
        let resume = resumeBook?.comicMetadata
        if let section = resume?.section, sections.contains(where: { $0.section == section }) {
            selectedSection = section
        } else {
            selectedSection = sections.first?.section ?? .issues
        }
        if let resume, let volumeID = resume.volumeID, directVolume(in: resume.section) == nil,
            let volume = volumeSummaries(in: resume.section).first(where: { $0.volumeID == volumeID })
        {
            expandedVolumeIds.insert(volume.id)
        }
        hasLoaded = true
        await loadVisibleSlices()
    }

    func loadNextPage() async {
        guard let slice = primarySlice(in: selectedSection ?? .issues) else { return }
        await loadNextPage(slice)
    }

    func loadNextPage(_ slice: ComicSeriesSlice) async {
        guard hasMore(slice), state(of: slice) != .loading else { return }
        sliceStates[slice] = .loading
        defer { refreshWhenIdle() }
        let consumed = fetched[slice, default: 0]
        let limit = min(Self.pageSize, rawCount(slice) - consumed)
        let page = await library.seriesBooksPage(
            for: rawAggregate, mediaScope: mediaScope, offset: consumed, limit: limit, slice: slice
        )
        guard !Task.isCancelled, rawSlices.contains(slice) else {
            sliceStates[slice] = .idle
            return
        }
        // The repository reports failures as an empty page, so only a non-empty short page marks the end.
        guard !page.isEmpty else {
            sliceStates[slice] = .failed
            return
        }
        if page.count < limit { exhausted.insert(slice) }
        fetched[slice] = consumed + page.count
        var seen = Set(loaded[slice, default: []].map(\.uniqueId))
        loaded[slice, default: []].append(contentsOf: page.filter { seen.insert($0.uniqueId).inserted })
        regroup()
        sliceStates[slice] = .idle
        await refreshOffline()
    }

    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    func refresh() async {
        guard hasLoaded else { return }
        guard !isRefreshing else {
            needsRefresh = true
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            refreshWhenIdle()
        }
        let latest = await library.seriesAggregate(for: rawAggregate)
        guard !Task.isCancelled else { return }
        rawAggregate = latest
        if !isFiltered {
            aggregate = rawAggregate
        } else {
            var members: [Book] = []
            while members.count < latest.bookCount {
                let page = await library.seriesBooksPage(for: latest, mediaScope: mediaScope, offset: members.count, limit: Self.pageSize)
                guard !Task.isCancelled else { return }
                members += page
                if page.count < Self.pageSize { break }
            }
            let offline = filter.status == .downloaded ? await library.offlineBookIDs(in: members) : []
            aggregate = library.seriesAggregates(from: members.filter { filter.includes($0, library: library, offlineIDs: offline) }).first
                ?? BrowseSeriesAggregate(
                    name: latest.name, bookCount: 0, representativeThumb: latest.representativeThumb,
                    matchingNames: latest.matchingNames, isComic: true, providerId: latest.providerId,
                    libraryId: latest.libraryId, comicSeriesID: latest.comicSeriesID,
                    sections: latest.sections.map { ComicSeriesSectionSummary(section: $0.section, count: 0) }
                )
        }
        let valid = Set(rawSlices)
        for slice in loaded.keys where !valid.contains(slice) {
            loaded[slice] = nil
            fetched[slice] = nil
            exhausted.remove(slice)
            sliceStates[slice] = nil
        }
        if sliceStates.values.contains(.loading) { needsRefresh = true }
        // Keep the fetched depth so returning from the reader preserves issue positions.
        for slice in loaded.keys where state(of: slice) != .loading {
            let before = fetched[slice, default: 0]
            let target = min(before, rawCount(slice))
            var fresh: [Book] = []
            var ended = false
            while fresh.count < target {
                let limit = min(Self.pageSize, target - fresh.count)
                let page = await library.seriesBooksPage(
                    for: rawAggregate, mediaScope: mediaScope, offset: fresh.count, limit: limit, slice: slice
                )
                guard !Task.isCancelled else { return }
                fresh += page
                if page.count < limit { ended = true; break }
            }
            // A page load that ran meanwhile owns this slice; an empty result is a failed read, not an empty slice.
            guard fetched[slice, default: 0] == before, state(of: slice) != .loading, !fresh.isEmpty || target == 0 else { continue }
            loaded[slice] = fresh
            fetched[slice] = fresh.count
            if ended { exhausted.insert(slice) } else { exhausted.remove(slice) }
        }
        regroup()
        await resolveResume()
        if !sections.contains(where: { $0.section == selectedSection }) {
            selectedSection = sections.first?.section
        }
        await refreshOffline()
        await loadVisibleSlices()
    }

    func refreshOffline() async {
        let candidates = books + (resumeBook.map { [$0] } ?? [])
        let ids = await library.offlineBookIDs(in: candidates)
        if ids != offlineIds {
            offlineIds = ids
            if filter.status == .downloaded { regroup() }
        }
    }

    private func primarySlice(in section: ComicSection) -> ComicSeriesSlice? {
        directVolume(in: section)?.slice ?? looseSlice(in: section)
    }

    private func refreshWhenIdle() {
        guard needsRefresh, !isRefreshing, !sliceStates.values.contains(.loading) else { return }
        needsRefresh = false
        scheduleRefresh()
    }

    private func loadVisibleSlices() async {
        let section = selectedSection ?? .issues
        let expanded = directVolume(in: section) == nil
            ? volumeSummaries(in: section).filter { expandedVolumeIds.contains($0.id) }.map { $0.slice }
            : []
        for slice in (primarySlice(in: section).map { [$0] } ?? []) + expanded where loaded[slice] == nil {
            await loadNextPage(slice)
        }
    }

    private var rawSlices: [ComicSeriesSlice] {
        ComicSection.allCases.flatMap { section -> [ComicSeriesSlice] in
            let volumes = rawAggregate.volumes.filter { $0.section == section }
            if volumes.isEmpty { return rawSectionCount(section) > 0 ? [.section(section)] : [] }
            return (rawCount(.loose(section)) > 0 ? [.loose(section)] : []) + volumes.map { $0.slice }
        }
    }

    private func rawSectionCount(_ section: ComicSection) -> Int {
        if rawAggregate.sections.isEmpty { return section == .issues ? rawAggregate.bookCount : 0 }
        return rawAggregate.sections.first { $0.section == section }?.count ?? 0
    }

    private func rawCount(_ slice: ComicSeriesSlice) -> Int {
        switch slice {
        case .section(let section):
            return rawSectionCount(section)
        case .volume(let section, let id):
            return rawAggregate.volumes.first { $0.section == section && $0.volumeID == id }?.count ?? 0
        case .loose(let section):
            let inVolumes = rawAggregate.volumes.filter { $0.section == section }.reduce(0) { $0 + $1.count }
            return max(0, rawSectionCount(section) - inVolumes)
        }
    }

    private func resolveResume() async {
        let id = aggregate.resumeBookUniqueID ?? rawAggregate.resumeBookUniqueID
        let resolved = if let id { await library.book(uniqueId: id) } else { nil as Book? }
        if resolved != resumeBook { resumeBook = resolved }
    }

    private func regroup() {
        let next = ComicSeriesGrouping(books: books.filter { filter.includes($0, library: library, offlineIDs: offlineIds) })
        if next != grouping { grouping = next }
    }
}

extension ComicVolumeSummary {
    var slice: ComicSeriesSlice { .volume(section: section, id: volumeID) }
}
