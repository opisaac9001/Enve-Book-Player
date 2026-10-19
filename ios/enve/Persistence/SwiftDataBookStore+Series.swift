import Foundation
import Logging
import SwiftData

extension SwiftDataBookStore {
    func seriesAggregate(for aggregate: BrowseSeriesAggregate) async -> BrowseSeriesAggregate? {
        let worker = makeWorker()
        do {
            let groups = try await worker.fetchBrowseSeriesAggregates(
                mediaType: "ebook", providerId: aggregate.providerId, libraryId: aggregate.libraryId, selected: aggregate
            )
            if let exact = groups.first(where: { $0.id == aggregate.id }) { return exact }
            // Adopt newly refreshed metadata only when the legacy title resolves to one scoped comic run.
            guard aggregate.isComic, aggregate.comicSeriesID == nil, aggregate.standaloneBookUniqueID == nil,
                groups.count == 1, groups[0].isComic
            else { return nil }
            return groups[0]
        } catch {
            AppLogger.general.error("BookStore.seriesAggregate failed: \(error)")
            return nil
        }
    }

    func seriesBooksPage(for aggregate: BrowseSeriesAggregate, mediaScope: [String], offset: Int, limit: Int, slice: ComicSeriesSlice) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchSeriesBooksPage(for: aggregate, mediaScope: mediaScope, offset: offset, limit: limit, slice: slice)
        } catch {
            AppLogger.general.error("BookStore.seriesBooksPage(slice) failed: \(error)")
            return []
        }
    }

    func seriesBooksPage(for aggregate: BrowseSeriesAggregate, mediaScope: [String], offset: Int, limit: Int) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchSeriesBooksPage(for: aggregate, mediaScope: mediaScope, offset: offset, limit: limit)
        } catch {
            AppLogger.general.error("BookStore.seriesBooksPage failed: \(error)")
            return []
        }
    }

    func comicBooksPage(sourceFilter: LibrarySourceFilter, offset: Int, limit: Int) async -> [Book] {
        await comicBooksPage(sourceFilter: sourceFilter, offset: offset, limit: limit, sort: [])
    }

    func comicBooksPage(sourceFilter: LibrarySourceFilter, offset: Int, limit: Int, sort: [BookStoreSortDescriptor]) async -> [Book] {
        let scope = Self.comicScope(sourceFilter)
        let worker = makeWorker()
        do {
            return try await worker.fetchComicBooksPage(
                providerId: scope.providerId,
                libraryId: scope.libraryId,
                deviceOnly: scope.deviceOnly,
                offset: offset,
                limit: limit, sort: sort
            )
        } catch {
            AppLogger.general.error("BookStore.comicBooksPage failed: \(error)")
            return []
        }
    }

    func comicBookCount(sourceFilter: LibrarySourceFilter) async -> Int {
        let scope = Self.comicScope(sourceFilter)
        let worker = makeWorker()
        do {
            return try await worker.fetchComicBookCount(
                providerId: scope.providerId,
                libraryId: scope.libraryId,
                deviceOnly: scope.deviceOnly
            )
        } catch {
            AppLogger.general.error("BookStore.comicBookCount failed: \(error)")
            return 0
        }
    }

    private static func comicScope(_ filter: LibrarySourceFilter) -> (providerId: String?, libraryId: String?, deviceOnly: Bool) {
        switch filter {
        case .all: (nil, nil, false)
        case .device: (nil, nil, true)
        case .connection(let id): (id.uuidString, nil, false)
        case .library(let providerId, let libraryId): (providerId.uuidString, libraryId, false)
        }
    }
}

extension SwiftDataBookStore.Worker {
    func fetchBrowseSeriesAggregates(
        mediaType: String,
        providerId: UUID? = nil,
        libraryId: String? = nil,
        selected: BrowseSeriesAggregate? = nil
    ) throws -> [BrowseSeriesAggregate] {
        let localMediaType = mediaType
        let localProviderId = providerId?.uuidString ?? ""
        let localLibraryId = libraryId ?? ""
        let predicate: Predicate<BookRecord>
        if let id = selected?.standaloneBookUniqueID {
            predicate = #Predicate { record in
                record.uniqueId == id && record.providerId == localProviderId
                    && record.libraryId == localLibraryId && !record.isDeleted && !record.isHidden
            }
        } else if let selected, let seriesID = selected.comicSeriesID {
            predicate = #Predicate<BookRecord> { record in
                (record.comicSeriesID == seriesID && record.providerId == localProviderId)
                    && (record.libraryId == localLibraryId && record.mediaType == localMediaType)
                    && (!record.isDeleted && !record.isHidden)
            }
        } else if let selected {
            let names: [String?] = selected.matchingNames.map { $0 }
            let anyProvider = providerId == nil
            let anyLibrary = libraryId == nil
            predicate = #Predicate<BookRecord> { record in
                (names.contains(record.series) && record.mediaType == localMediaType)
                    && ((anyProvider || record.providerId == localProviderId) && (anyLibrary || record.libraryId == localLibraryId))
                    && (!record.isDeleted && !record.isHidden)
            }
        } else {
        switch (providerId, libraryId) {
        case (nil, _):
            predicate = #Predicate<BookRecord> { record in
                record.mediaType == localMediaType && !record.isDeleted && !record.isHidden
            }
        case (.some, nil):
            predicate = #Predicate<BookRecord> { record in
                record.mediaType == localMediaType && !record.isDeleted && !record.isHidden && record.providerId == localProviderId
            }
        case (.some, .some):
            predicate = #Predicate<BookRecord> { record in
                record.mediaType == localMediaType && !record.isDeleted && !record.isHidden
                    && record.providerId == localProviderId && record.libraryId == localLibraryId
            }
        }
        }
        var descriptor = FetchDescriptor<BookRecord>(predicate: predicate)
        descriptor.propertiesToFetch = [
            \BookRecord.uniqueId,
            \BookRecord.title,
            \BookRecord.series,
            \BookRecord.thumb,
            \BookRecord.currentTime,
            \BookRecord.duration,
            \BookRecord.ebookProgress,
            \BookRecord.isFinished,
            \BookRecord.lastUpdate,
            \BookRecord.providerId,
            \BookRecord.libraryId,
            \BookRecord.mediaType,
            \BookRecord.ebookFormat,
            \BookRecord.comicSeriesID,
            \BookRecord.comicSectionOrder,
            \BookRecord.comicVolumeOrder,
            \BookRecord.comicIssueOrder,
            \BookRecord.seriesNumberSortValue,
            \BookRecord.titleSortKey,
        ]
        if selected != nil { descriptor.propertiesToFetch.append(\BookRecord.comicMetadataJSON) }
        let rows = try modelContext.fetch(descriptor)

        struct Acc {
            var name: String
            var isComic: Bool
            var providerId: UUID?
            var libraryId: String?
            var comicSeriesID: String?
            var standaloneBookUniqueID: String?
            var count: Int = 0
            var completedCount: Int = 0
            var thumb: String?
            var matchingNames = Set<String>()
            var latestStarted: BookRecord?
            var firstUnread: BookRecord?
            var sectionCounts: [ComicSection: Int] = [:]
            var metadata: [ComicMetadata] = []
        }
        var bucket: [String: Acc] = [:]
        for row in rows {
            let seriesName = row.series?.trimmingCharacters(in: .whitespacesAndNewlines)
            let isComic = Self.isComicRecord(row)
            guard isComic || seriesName?.isEmpty == false else { continue }
            let raw = seriesName?.isEmpty == false ? seriesName! : row.title
            let standalone = isComic && row.comicSeriesID == nil && seriesName?.isEmpty != false
            let key: String
            var acc: Acc
            if isComic {
                key = "comic|\(row.providerId)|\(row.libraryId)|" + (standalone ? "book:\(row.uniqueId)" : (row.comicSeriesID.map { "id:\($0)" } ?? "title:\(raw)"))
                acc = bucket[key] ?? Acc(
                    name: raw,
                    isComic: true,
                    providerId: UUID(uuidString: row.providerId),
                    libraryId: row.libraryId,
                    comicSeriesID: row.comicSeriesID,
                    standaloneBookUniqueID: standalone ? row.uniqueId : nil
                )
            } else {
                let displayName = NameNormalizer.normalizeSeriesName(raw)
                key = "series|\(displayName)"
                acc = bucket[key] ?? Acc(name: displayName, isComic: false, providerId: providerId, libraryId: libraryId)
            }
            acc.count += 1
            if isComic {
                let section = ComicSection.allCases.first { $0.sortOrder == row.comicSectionOrder } ?? .issues
                acc.sectionCounts[section, default: 0] += 1
                if selected != nil, let data = row.comicMetadataJSON,
                    let metadata = try? JSONDecoder().decode(ComicMetadata.self, from: data) {
                    acc.metadata.append(metadata)
                }
            }
            let progress = localMediaType == "ebook"
                ? row.ebookProgress ?? 0
                : row.duration.map { $0 > 0 ? row.currentTime / $0 : 0 } ?? 0
            if row.isFinished || progress >= Book.finishedProgressThreshold {
                acc.completedCount += 1
            } else {
                if progress > 0, acc.latestStarted.map({ row.lastUpdate > $0.lastUpdate }) ?? true {
                    acc.latestStarted = row
                }
                if acc.firstUnread.map({ Self.seriesMemberPrecedes(row, $0) }) ?? true {
                    acc.firstUnread = row
                }
            }
            acc.matchingNames.insert(raw)
            if acc.thumb == nil, let t = row.thumb, !t.isEmpty { acc.thumb = t }
            bucket[key] = acc
        }
        return bucket.values.map {
            BrowseSeriesAggregate(
                name: $0.name,
                bookCount: $0.count,
                completedBookCount: $0.completedCount,
                representativeThumb: $0.thumb,
                matchingNames: $0.matchingNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                isComic: $0.isComic,
                providerId: $0.providerId,
                libraryId: $0.libraryId,
                comicSeriesID: $0.comicSeriesID,
                resumeBookUniqueID: ($0.latestStarted ?? $0.firstUnread)?.uniqueId,
                resumeBookLastUpdate: ($0.latestStarted ?? $0.firstUnread)?.lastUpdate,
                sections: $0.sectionCounts.map { ComicSeriesSectionSummary(section: $0.key, count: $0.value) }
                    .sorted { $0.section.sortOrder < $1.section.sortOrder },
                volumes: ComicVolumeSummary.grouped($0.metadata),
                standaloneBookUniqueID: $0.standaloneBookUniqueID
            )
        }
    }

    private nonisolated static func isComicRecord(_ record: BookRecord) -> Bool {
        guard record.mediaType == AppMediaType.ebook.rawValue else { return false }
        if record.comicSeriesID != nil { return true }
        return [EbookFormat.cbz.rawValue, EbookFormat.cbr.rawValue, EbookFormat.imagefolder.rawValue]
            .contains(record.ebookFormat ?? "")
    }

    // Mirrors seriesPageSortDescriptors, where SQLite orders missing values first.
    private nonisolated static func seriesMemberPrecedes(_ lhs: BookRecord, _ rhs: BookRecord) -> Bool {
        func key(_ record: BookRecord) -> [Double] {
            [
                record.comicSectionOrder.map { Double($0) } ?? -.greatestFiniteMagnitude,
                record.comicVolumeOrder ?? -.greatestFiniteMagnitude,
                record.comicIssueOrder ?? -.greatestFiniteMagnitude,
                record.seriesNumberSortValue,
            ]
        }
        let l = key(lhs)
        let r = key(rhs)
        if l != r { return l.lexicographicallyPrecedes(r) }
        if lhs.titleSortKey != rhs.titleSortKey { return lhs.titleSortKey < rhs.titleSortKey }
        return lhs.uniqueId < rhs.uniqueId
    }

    private nonisolated static var seriesPageSortDescriptors: [SortDescriptor<BookRecord>] {
        [
            SortDescriptor(\.comicSectionOrder),
            SortDescriptor(\.comicVolumeOrder),
            SortDescriptor(\.comicIssueOrder),
            SortDescriptor(\.seriesNumberSortValue),
            SortDescriptor(\.titleSortKey),
            SortDescriptor(\.uniqueId),
        ]
    }

    func fetchSeriesBooksPage(
        for aggregate: BrowseSeriesAggregate,
        mediaScope: [String],
        offset: Int,
        limit: Int,
        slice: ComicSeriesSlice? = nil
    ) throws -> [Book] {
        guard limit > 0 else { return [] }
        try backfillSortKeysIfNeeded()
        let ebookType = AppMediaType.ebook.rawValue
        let scope = mediaScope.isEmpty
            ? [AppMediaType.audiobook.rawValue, AppMediaType.podcast.rawValue, ebookType]
            : mediaScope
        let names: [String?] = aggregate.matchingNames.map { $0 }
        let pid = aggregate.providerId?.uuidString ?? ""
        let lid = aggregate.libraryId ?? ""

        let predicate: Predicate<BookRecord>
        if let id = aggregate.standaloneBookUniqueID {
            guard scope.contains(ebookType) else { return [] }
            predicate = #Predicate { record in
                record.uniqueId == id && record.providerId == pid && record.libraryId == lid
                    && !record.isDeleted && !record.isHidden
            }
        } else if aggregate.isComic, let seriesID = aggregate.comicSeriesID {
            predicate = #Predicate { record in
                record.comicSeriesID == seriesID
                    && record.providerId == pid
                    && record.libraryId == lid
                    && record.mediaType == ebookType
                    && scope.contains(record.mediaType)
                    && !record.isDeleted
                    && !record.isHidden
            }
        } else {
            switch (aggregate.providerId, aggregate.libraryId) {
            case (nil, _):
                predicate = #Predicate { record in
                    names.contains(record.series) && scope.contains(record.mediaType)
                        && !record.isDeleted && !record.isHidden
                }
            case (.some, nil):
                predicate = #Predicate { record in
                    record.providerId == pid && names.contains(record.series)
                        && scope.contains(record.mediaType) && !record.isDeleted && !record.isHidden
                }
            case (.some, .some):
                predicate = #Predicate { record in
                    record.providerId == pid && record.libraryId == lid
                        && names.contains(record.series) && scope.contains(record.mediaType)
                        && !record.isDeleted && !record.isHidden
                }
            }
        }

        var descriptor = FetchDescriptor<BookRecord>(predicate: predicate, sortBy: Self.seriesPageSortDescriptors)
        if aggregate.isComic, aggregate.comicSeriesID != nil, slice == nil {
            descriptor.fetchOffset = max(0, offset)
            descriptor.fetchLimit = limit
            return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
        }

        descriptor.fetchLimit = 200
        var rawOffset = 0
        var skipped = 0
        var books: [Book] = []
        while books.count < limit {
            try Task.checkCancellation()
            descriptor.fetchOffset = rawOffset
            let rows = try modelContext.fetch(descriptor)
            for row in rows where Self.isComicRecord(row) == aggregate.isComic {
                if aggregate.isComic, aggregate.comicSeriesID == nil, row.comicSeriesID != nil { continue }
                if let slice {
                    let metadata = row.comicMetadataJSON.flatMap { try? JSONDecoder().decode(ComicMetadata.self, from: $0) }
                    if !slice.includes(metadata) { continue }
                }
                if skipped < max(0, offset) { skipped += 1; continue }
                if let book = row.toBook() { books.append(book) }
                if books.count == limit { break }
            }
            if rows.count < 200 { break }
            rawOffset += rows.count
        }
        return books
    }

    private func comicDescriptor(providerId: String?, libraryId: String?, deviceOnly: Bool) -> FetchDescriptor<BookRecord> {
        let ebookType = AppMediaType.ebook.rawValue
        let cbz = EbookFormat.cbz.rawValue
        let cbr = EbookFormat.cbr.rawValue
        let imageFolder = EbookFormat.imagefolder.rawValue
        let localSource = Book.BookSource.local.rawValue
        let smbSource = Book.BookSource.smb.rawValue
        let pid = providerId ?? ""
        let lid = libraryId ?? ""

        let predicate: Predicate<BookRecord>
        if deviceOnly {
            predicate = #Predicate { record in
                (record.source == localSource || record.source == smbSource)
                    && record.mediaType == ebookType
                    && (record.comicSeriesID != nil || record.ebookFormat == cbz
                        || record.ebookFormat == cbr || record.ebookFormat == imageFolder)
                    && !record.isDeleted
                    && !record.isHidden
            }
        } else if providerId != nil, libraryId != nil {
            predicate = #Predicate { record in
                record.providerId == pid
                    && record.libraryId == lid
                    && record.mediaType == ebookType
                    && (record.comicSeriesID != nil || record.ebookFormat == cbz
                        || record.ebookFormat == cbr || record.ebookFormat == imageFolder)
                    && !record.isDeleted
                    && !record.isHidden
            }
        } else if providerId != nil {
            predicate = #Predicate { record in
                record.providerId == pid
                    && record.mediaType == ebookType
                    && (record.comicSeriesID != nil || record.ebookFormat == cbz
                        || record.ebookFormat == cbr || record.ebookFormat == imageFolder)
                    && !record.isDeleted
                    && !record.isHidden
            }
        } else {
            predicate = #Predicate { record in
                record.mediaType == ebookType
                    && (record.comicSeriesID != nil || record.ebookFormat == cbz
                        || record.ebookFormat == cbr || record.ebookFormat == imageFolder)
                    && !record.isDeleted
                    && !record.isHidden
            }
        }
        var sortBy: [SortDescriptor<BookRecord>] = [
            SortDescriptor(\.seriesMissingRank),
            SortDescriptor(\.seriesSortKey),
            SortDescriptor(\.providerId),
            SortDescriptor(\.libraryId),
            SortDescriptor(\.comicSeriesID),
        ]
        sortBy += Self.seriesPageSortDescriptors
        return FetchDescriptor<BookRecord>(predicate: predicate, sortBy: sortBy)
    }

    func fetchComicBooksPage(
        providerId: String?,
        libraryId: String?,
        deviceOnly: Bool,
        offset: Int,
        limit: Int,
        sort: [BookStoreSortDescriptor]
    ) throws -> [Book] {
        guard limit > 0 else { return [] }
        try backfillSortKeysIfNeeded()
        var descriptor = comicDescriptor(providerId: providerId, libraryId: libraryId, deviceOnly: deviceOnly)
        if !sort.isEmpty { descriptor.sortBy = Self.sortDescriptors(for: sort) }
        descriptor.fetchOffset = max(0, offset)
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
    }

    func fetchComicBookCount(providerId: String?, libraryId: String?, deviceOnly: Bool) throws -> Int {
        try modelContext.fetchCount(comicDescriptor(providerId: providerId, libraryId: libraryId, deviceOnly: deviceOnly))
    }
}
