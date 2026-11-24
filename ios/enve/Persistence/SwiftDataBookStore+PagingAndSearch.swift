import Foundation
import Logging
import SwiftData

extension SwiftDataBookStore {
    func pagedBooks(offset: Int, limit: Int, mediaType: String?) async -> [Book] {
        await read("pagedBooks", fallback: []) {
            try await $0.fetchPaged(offset: offset, limit: limit, mediaType: mediaType)
        }
    }

    func booksAfterUniqueId(_ cursor: String?, limit: Int) async -> [Book] {
        await read("booksAfterUniqueId", fallback: []) { try await $0.fetchAfterUniqueId(cursor, limit: limit) }
    }

    func pagedBooks(after cursor: Book?, limit: Int, mediaType: String?) async -> [Book] {
        await read("pagedBooks(after:)", fallback: []) {
            try await $0.fetchPagedAfter(book: cursor, limit: limit, mediaType: mediaType)
        }
    }

    func pagedBooks(libraryId: String, providerId: UUID, after cursor: Book?, limit: Int) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchPagedForLibraryAfter(
                book: cursor,
                libraryId: libraryId,
                providerId: providerId.uuidString,
                limit: limit
            )
        } catch {
            AppLogger.general.error("BookStore.pagedBooks(library, after:) failed: \(error)")
            return []
        }
    }

    func pagedBooks(providerId: UUID, after cursor: Book?, limit: Int, mediaType: String?) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchPagedForProviderAfter(
                book: cursor,
                providerId: providerId.uuidString,
                limit: limit,
                mediaType: mediaType
            )
        } catch {
            AppLogger.general.error("BookStore.pagedBooks(provider, after:) failed: \(error)")
            return []
        }
    }

    func pagedBooks(libraryId: String, providerId: UUID, offset: Int, limit: Int) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchPagedForLibrary(
                libraryId: libraryId,
                providerId: providerId.uuidString,
                offset: offset,
                limit: limit
            )
        } catch {
            AppLogger.general.error("BookStore.pagedBooks(library) failed: \(error)")
            return []
        }
    }

    func sortedPagedBooks(offset: Int, limit: Int, mediaType: String?, sort: [BookStoreSortDescriptor]) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchSortedPaged(
                offset: offset,
                limit: limit,
                mediaType: mediaType,
                providerId: nil,
                libraryId: nil,
                sort: sort
            )
        } catch {
            AppLogger.general.error("BookStore.sortedPagedBooks failed: \(error)")
            return []
        }
    }

    func sortedPagedBooks(providerId: UUID, offset: Int, limit: Int, mediaType: String?, sort: [BookStoreSortDescriptor]) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchSortedPaged(
                offset: offset,
                limit: limit,
                mediaType: mediaType,
                providerId: providerId.uuidString,
                libraryId: nil,
                sort: sort
            )
        } catch {
            AppLogger.general.error("BookStore.sortedPagedBooks(provider) failed: \(error)")
            return []
        }
    }

    func sortedPagedBooks(
        libraryId: String,
        providerId: UUID,
        offset: Int,
        limit: Int,
        mediaType: String?,
        sort: [BookStoreSortDescriptor]
    ) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchSortedPaged(
                offset: offset,
                limit: limit,
                mediaType: mediaType,
                providerId: providerId.uuidString,
                libraryId: libraryId,
                sort: sort
            )
        } catch {
            AppLogger.general.error("BookStore.sortedPagedBooks(library) failed: \(error)")
            return []
        }
    }

    func searchBooks(query: String, limit: Int) async -> [Book] {
        await read("searchBooks", fallback: []) { try await $0.searchBooks(query: query, limit: limit) }
    }

    func searchBooks(query: String, mediaType: String, limit: Int) async -> [Book] {
        await read("searchBooks(mediaType:)", fallback: []) {
            try await $0.searchBooks(query: query, mediaType: mediaType, limit: limit)
        }
    }

    func catalogPage(
        excludingProviderIds: Set<UUID>,
        mediaType: String?,
        search: String?,
        sort: [BookStoreSortDescriptor],
        offset: Int,
        limit: Int
    ) async -> [Book] {
        let worker = await makeBackgroundWorker()
        do {
            return try await worker.fetchCatalogPage(
                excludingProviderIds: Set(excludingProviderIds.map(\.uuidString)),
                mediaType: mediaType,
                search: search,
                sort: sort,
                offset: offset,
                limit: limit
            )
        } catch {
            AppLogger.general.error("BookStore.catalogPage failed: \(error)")
            return []
        }
    }

    func searchBooks(query: String, libraryId: String?, providerId: UUID?, limit: Int) async -> [Book] {
        await read("searchBooks(scoped)", fallback: []) {
            try await $0.searchBooks(query: query, libraryId: libraryId, providerId: providerId?.uuidString, limit: limit)
        }
    }
}

extension SwiftDataBookStore.Worker {
    func fetchPaged(offset: Int, limit: Int, mediaType: String?) throws -> [Book] {
        var descriptor: FetchDescriptor<BookRecord>
        if let mt = mediaType {
            descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { $0.mediaType == mt && !$0.isDeleted && !$0.isHidden },
                sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { !$0.isDeleted && !$0.isHidden },
                sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
            )
        }
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
    }

    func fetchSortedPaged(
        offset: Int,
        limit: Int,
        mediaType: String?,
        providerId: String?,
        libraryId: String?,
        sort: [BookStoreSortDescriptor]
    ) throws -> [Book] {
        try backfillSortKeysIfNeeded()
        let sortBy = Self.sortDescriptors(for: sort)
        var descriptor: FetchDescriptor<BookRecord>

        if let providerId, let libraryId {
            if let mt = mediaType {
                descriptor = FetchDescriptor<BookRecord>(
                    predicate: #Predicate {
                        $0.providerId == providerId
                            && $0.libraryId == libraryId
                            && $0.mediaType == mt
                            && !$0.isDeleted
                            && !$0.isHidden
                    },
                    sortBy: sortBy
                )
            } else {
                descriptor = FetchDescriptor<BookRecord>(
                    predicate: #Predicate {
                        $0.providerId == providerId
                            && $0.libraryId == libraryId
                            && !$0.isDeleted
                            && !$0.isHidden
                    },
                    sortBy: sortBy
                )
            }
        } else if let providerId {
            if let mt = mediaType {
                descriptor = FetchDescriptor<BookRecord>(
                    predicate: #Predicate {
                        $0.providerId == providerId
                            && $0.mediaType == mt
                            && !$0.isDeleted
                            && !$0.isHidden
                    },
                    sortBy: sortBy
                )
            } else {
                descriptor = FetchDescriptor<BookRecord>(
                    predicate: #Predicate {
                        $0.providerId == providerId
                            && !$0.isDeleted
                            && !$0.isHidden
                    },
                    sortBy: sortBy
                )
            }
        } else if let mt = mediaType {
            descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.mediaType == mt && !$0.isDeleted && !$0.isHidden
                },
                sortBy: sortBy
            )
        } else {
            descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { !$0.isDeleted && !$0.isHidden },
                sortBy: sortBy
            )
        }

        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
    }

    func fetchCatalogPage(
        excludingProviderIds: Set<String>,
        mediaType: String?,
        search: String?,
        sort: [BookStoreSortDescriptor],
        offset: Int,
        limit: Int
    ) throws -> [Book] {
        try backfillSortKeysIfNeeded()
        let needle = search?.lowercased() ?? ""
        let matchesAnyText = needle.isEmpty
        if !matchesAnyText { try backfillSearchTextIfNeeded() }
        let matchesAnyMedia = mediaType == nil
        let media = mediaType ?? ""
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { record in
                !record.isDeleted && !record.isHidden
                    && !excludingProviderIds.contains(record.providerId)
                    && (matchesAnyMedia || record.mediaType == media)
                    && (matchesAnyText || record.searchText.contains(needle))
            },
            sortBy: Self.sortDescriptors(for: sort)
        )
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
    }

    func backfillSortKeysIfNeeded() throws {
        let flag = "imagine.bookSortKeysBackfilled.v1"
        if UserDefaults.standard.bool(forKey: flag) { return }
        let pageSize = 2000
        var offset = 0
        while true {
            try Task.checkCancellation()
            var descriptor = FetchDescriptor<BookRecord>(sortBy: [SortDescriptor(\.uniqueId)])
            descriptor.fetchLimit = pageSize
            descriptor.fetchOffset = offset
            let page = try modelContext.fetch(descriptor)
            if page.isEmpty { break }
            for record in page {
                record.refreshSortKeys()
            }
            try modelContext.save()
            offset += page.count
            if page.count < pageSize { break }
        }
        UserDefaults.standard.set(true, forKey: flag)
    }

    nonisolated static func sortDescriptors(for descriptors: [BookStoreSortDescriptor]) -> [SortDescriptor<BookRecord>] {
        let descriptors =
            descriptors.isEmpty
            ? [BookStoreSortDescriptor(field: .recent, direction: .descending)]
            : descriptors
        var sortBy: [SortDescriptor<BookRecord>] = []

        for descriptor in descriptors {
            let order = sortOrder(for: descriptor.direction)
            switch descriptor.field {
            case .recent:
                sortBy.append(SortDescriptor(\.addedAtMissingRank, order: .forward))
                sortBy.append(SortDescriptor(\.addedAtSortValue, order: order))
            case .recentlyRead:
                sortBy.append(SortDescriptor(\.lastUpdate, order: order))
            case .title:
                sortBy.append(SortDescriptor(\.titleMissingRank, order: .forward))
                sortBy.append(SortDescriptor(\.titleSortKey, order: order))
            case .authorGiven:
                sortBy.append(SortDescriptor(\.authorMissingRank, order: .forward))
                sortBy.append(SortDescriptor(\.authorGivenSortKey, order: order))
            case .authorSurname:
                sortBy.append(SortDescriptor(\.authorMissingRank, order: .forward))
                sortBy.append(SortDescriptor(\.authorSurnameSortKey, order: order))
            case .narratorGiven:
                sortBy.append(SortDescriptor(\.narratorMissingRank, order: .forward))
                sortBy.append(SortDescriptor(\.narratorGivenSortKey, order: order))
            case .narratorSurname:
                sortBy.append(SortDescriptor(\.narratorMissingRank, order: .forward))
                sortBy.append(SortDescriptor(\.narratorSurnameSortKey, order: order))
            case .series:
                sortBy.append(SortDescriptor(\.seriesMissingRank, order: .forward))
                sortBy.append(SortDescriptor(\.seriesSortKey, order: order))
                sortBy.append(SortDescriptor(\.seriesNumberSortValue, order: order))
            case .progress:
                sortBy.append(SortDescriptor(\.progressSortValue, order: order))
            case .duration:
                sortBy.append(SortDescriptor(\.durationMissingRank, order: .forward))
                sortBy.append(SortDescriptor(\.durationSortValue, order: order))
            case .year:
                sortBy.append(SortDescriptor(\.yearMissingRank, order: .forward))
                sortBy.append(SortDescriptor(\.yearSortValue, order: order))
            case .goodreadsRating:
                sortBy.append(SortDescriptor(\.goodreadsRatingMissingRank, order: .forward))
                sortBy.append(SortDescriptor(\.goodreadsRatingSortValue, order: order))
            }
        }

        sortBy.append(SortDescriptor(\.titleSortKey, order: .forward))
        sortBy.append(SortDescriptor(\.uniqueId, order: .forward))
        return sortBy
    }

    private nonisolated static func sortOrder(for direction: BookStoreSortDirection) -> SortOrder {
        switch direction {
        case .ascending:
            return .forward
        case .descending:
            return .reverse
        }
    }

    func fetchAfterUniqueId(_ cursor: String?, limit: Int) throws -> [Book] {
        var descriptor: FetchDescriptor<BookRecord>
        if let cursor {
            descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { $0.uniqueId > cursor },
                sortBy: [SortDescriptor(\.uniqueId, order: .forward)]
            )
        } else {
            descriptor = FetchDescriptor<BookRecord>(
                sortBy: [SortDescriptor(\.uniqueId, order: .forward)]
            )
        }
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
    }

    func fetchPagedAfter(book cursor: Book?, limit: Int, mediaType: String?) throws -> [Book] {
        let sort: [SortDescriptor<BookRecord>] = [
            SortDescriptor(\.addedAt, order: .reverse),
            SortDescriptor(\.uniqueId, order: .reverse),
        ]
        var descriptor: FetchDescriptor<BookRecord>
        if let cursor {
            let distantPast = Date.distantPast
            let cursorDate = cursor.addedAt ?? distantPast
            let cursorId = cursor.uniqueId
            if let mt = mediaType {
                descriptor = FetchDescriptor<BookRecord>(
                    predicate: #Predicate {
                        $0.mediaType == mt && !$0.isDeleted && !$0.isHidden
                            && (($0.addedAt ?? distantPast) < cursorDate
                                || (($0.addedAt ?? distantPast) == cursorDate && $0.uniqueId < cursorId))
                    },
                    sortBy: sort
                )
            } else {
                descriptor = FetchDescriptor<BookRecord>(
                    predicate: #Predicate {
                        !$0.isDeleted && !$0.isHidden
                            && (($0.addedAt ?? distantPast) < cursorDate
                                || (($0.addedAt ?? distantPast) == cursorDate && $0.uniqueId < cursorId))
                    },
                    sortBy: sort
                )
            }
        } else {
            if let mt = mediaType {
                descriptor = FetchDescriptor<BookRecord>(
                    predicate: #Predicate { $0.mediaType == mt && !$0.isDeleted && !$0.isHidden },
                    sortBy: sort
                )
            } else {
                descriptor = FetchDescriptor<BookRecord>(
                    predicate: #Predicate { !$0.isDeleted && !$0.isHidden },
                    sortBy: sort
                )
            }
        }
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
    }

    func fetchPagedForLibraryAfter(book cursor: Book?, libraryId: String, providerId: String, limit: Int) throws -> [Book] {
        let sort: [SortDescriptor<BookRecord>] = [
            SortDescriptor(\.addedAt, order: .reverse),
            SortDescriptor(\.uniqueId, order: .reverse),
        ]
        var descriptor: FetchDescriptor<BookRecord>
        if let cursor {
            let distantPast = Date.distantPast
            let cursorDate = cursor.addedAt ?? distantPast
            let cursorId = cursor.uniqueId
            descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.libraryId == libraryId && $0.providerId == providerId && !$0.isDeleted && !$0.isHidden
                        && (($0.addedAt ?? distantPast) < cursorDate
                            || (($0.addedAt ?? distantPast) == cursorDate && $0.uniqueId < cursorId))
                },
                sortBy: sort
            )
        } else {
            descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.libraryId == libraryId && $0.providerId == providerId && !$0.isDeleted && !$0.isHidden
                },
                sortBy: sort
            )
        }
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
    }

    func fetchPagedForProviderAfter(book cursor: Book?, providerId: String, limit: Int, mediaType: String?) throws -> [Book] {
        let sort: [SortDescriptor<BookRecord>] = [
            SortDescriptor(\.addedAt, order: .reverse),
            SortDescriptor(\.uniqueId, order: .reverse),
        ]
        var descriptor: FetchDescriptor<BookRecord>
        if let cursor {
            let distantPast = Date.distantPast
            let cursorDate = cursor.addedAt ?? distantPast
            let cursorId = cursor.uniqueId
            if let mt = mediaType {
                descriptor = FetchDescriptor<BookRecord>(
                    predicate: #Predicate {
                        $0.providerId == providerId && $0.mediaType == mt && !$0.isDeleted && !$0.isHidden
                            && (($0.addedAt ?? distantPast) < cursorDate
                                || (($0.addedAt ?? distantPast) == cursorDate && $0.uniqueId < cursorId))
                    },
                    sortBy: sort
                )
            } else {
                descriptor = FetchDescriptor<BookRecord>(
                    predicate: #Predicate {
                        $0.providerId == providerId && !$0.isDeleted && !$0.isHidden
                            && (($0.addedAt ?? distantPast) < cursorDate
                                || (($0.addedAt ?? distantPast) == cursorDate && $0.uniqueId < cursorId))
                    },
                    sortBy: sort
                )
            }
        } else {
            if let mt = mediaType {
                descriptor = FetchDescriptor<BookRecord>(
                    predicate: #Predicate {
                        $0.providerId == providerId && $0.mediaType == mt && !$0.isDeleted && !$0.isHidden
                    },
                    sortBy: sort
                )
            } else {
                descriptor = FetchDescriptor<BookRecord>(
                    predicate: #Predicate {
                        $0.providerId == providerId && !$0.isDeleted && !$0.isHidden
                    },
                    sortBy: sort
                )
            }
        }
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
    }

    func fetchPagedForLibrary(libraryId: String, providerId: String, offset: Int, limit: Int) throws -> [Book] {
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate {
                $0.libraryId == libraryId && $0.providerId == providerId && !$0.isDeleted && !$0.isHidden
            },
            sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
        )
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
    }

    private func backfillSearchTextIfNeeded() throws {
        let flag = "imagine.searchTextBackfilled.v1"
        if UserDefaults.standard.bool(forKey: flag) { return }
        let pageSize = 2000
        var offset = 0
        while true {
            try Task.checkCancellation()
            var d = FetchDescriptor<BookRecord>(sortBy: [SortDescriptor(\.uniqueId)])
            d.fetchLimit = pageSize
            d.fetchOffset = offset
            let page = try modelContext.fetch(d)
            if page.isEmpty { break }
            for r in page where r.searchText.isEmpty {
                r.searchText = BookRecord.makeSearchText(title: r.title, author: r.author, narrator: r.narrator, series: r.series)
            }
            try modelContext.save()
            offset += page.count
            if page.count < pageSize { break }
        }
        UserDefaults.standard.set(true, forKey: flag)
    }

    func searchBooks(query: String, limit: Int) throws -> [Book] {
        return try searchBooks(query: query, libraryId: nil, providerId: nil, limit: limit)
    }

    func searchBooks(query: String, mediaType: String, limit: Int) throws -> [Book] {
        try backfillSearchTextIfNeeded()
        let needle = query.lowercased()
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { record in
                record.mediaType == mediaType
                    && !record.isDeleted && !record.isHidden
                    && record.searchText.contains(needle)
            },
            sortBy: [SortDescriptor(\.title)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
    }

    func searchBooks(query: String, libraryId: String?, providerId: String?, limit: Int) throws -> [Book] {
        try backfillSearchTextIfNeeded()

        let needle = query.lowercased()
        var descriptor: FetchDescriptor<BookRecord>
        if let libraryId, let providerId {
            descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { record in
                    record.libraryId == libraryId && record.providerId == providerId
                        && !record.isDeleted && !record.isHidden
                        && record.searchText.contains(needle)
                },
                sortBy: [SortDescriptor(\.title)]
            )
        } else {
            descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { record in
                    !record.isDeleted && !record.isHidden
                        && record.searchText.contains(needle)
                },
                sortBy: [SortDescriptor(\.title)]
            )
        }
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
    }
}
