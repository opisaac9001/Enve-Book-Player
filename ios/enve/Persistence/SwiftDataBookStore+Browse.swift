import Foundation
import Logging
import SwiftData

extension SwiftDataBookStore {
    func browseSlices(source: String) async -> [BookBrowseSlice] {
        await read("browseSlices(source:)", fallback: []) { try await $0.fetchBrowseSlices(source: source) }
    }

    func browseSlices(mediaType: String) async -> [BookBrowseSlice] {
        await read("browseSlices(mediaType:)", fallback: []) {
            try await $0.fetchBrowseSlices(mediaType: mediaType)
        }
    }

    func browseAuthorAggregates(mediaType: String) async -> [BrowseAuthorAggregate] {
        let worker = await makeBackgroundWorker()
        do {
            return try await worker.fetchBrowseAuthorAggregates(mediaType: mediaType)
        } catch {
            AppLogger.general.error("BookStore.browseAuthorAggregates failed: \(error)")
            return []
        }
    }

    func browseNarratorAggregates(mediaType: String) async -> [BrowseNarratorAggregate] {
        await read("browseNarratorAggregates", fallback: []) {
            try await $0.fetchBrowseNarratorAggregates(mediaType: mediaType)
        }
    }

    func browseSeriesAggregates(mediaType: String) async -> [BrowseSeriesAggregate] {
        await read("browseSeriesAggregates", fallback: []) {
            try await $0.fetchBrowseSeriesAggregates(mediaType: mediaType)
        }
    }

    func browseSeriesAggregates(mediaType: String, providerId: UUID, libraryId: String?) async -> [BrowseSeriesAggregate] {
        await read("browseSeriesAggregates(providerId:)", fallback: []) {
            try await $0.fetchBrowseSeriesAggregates(mediaType: mediaType, providerId: providerId, libraryId: libraryId)
        }
    }

    func books(byAuthor author: String, mediaType: String, limit: Int) async -> [Book] {
        await read("books(byAuthor:)", fallback: []) {
            try await $0.fetchBooksByAuthor(author: author, mediaType: mediaType, limit: limit)
        }
    }

    func books(byAuthorNames authorNames: [String], mediaType: String, limit: Int) async -> [Book] {
        await read("books(byAuthorNames:)", fallback: []) {
            try await $0.fetchBooksByAuthorNames(authorNames: authorNames, mediaType: mediaType, limit: limit)
        }
    }

    func books(byNarrator narrator: String, mediaType: String, limit: Int) async -> [Book] {
        await read("books(byNarrator:)", fallback: []) {
            try await $0.fetchBooksByNarrator(narrator: narrator, mediaType: mediaType, limit: limit)
        }
    }

    func books(bySeries series: String, mediaType: String, limit: Int) async -> [Book] {
        await read("books(bySeries:)", fallback: []) {
            try await $0.fetchBooksBySeries(series: series, mediaType: mediaType, limit: limit)
        }
    }

    func books(bySeriesNames seriesNames: [String], mediaType: String, limit: Int) async -> [Book] {
        await read("books(bySeriesNames:)", fallback: []) {
            try await $0.fetchBooksBySeriesNames(seriesNames: seriesNames, mediaType: mediaType, limit: limit)
        }
    }

    func books(inSeries seriesName: String) async -> [Book] {
        await read("books(inSeries)", fallback: []) { try await $0.fetchBooksInSeries(seriesName) }
    }

    func books(inSeriesNames seriesNames: [String]) async -> [Book] {
        await read("books(inSeriesNames)", fallback: []) { try await $0.fetchBooksInSeriesNames(seriesNames) }
    }
}

extension SwiftDataBookStore.Worker {
    func fetchBrowseSlices(source: String) throws -> [BookBrowseSlice] {

        let localSource = source
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate<BookRecord> { record in
                record.source == localSource && !record.isDeleted
            }
        )
        descriptor.propertiesToFetch = [
            \BookRecord.bookId, \BookRecord.mediaType, \BookRecord.author, \BookRecord.narrator, \BookRecord.series, \BookRecord.genres,
            \BookRecord.thumb,
        ]
        return try modelContext.fetch(descriptor).map {
            BookBrowseSlice(
                id: $0.bookId,
                mediaType: $0.mediaType,
                author: $0.author,
                narrator: $0.narrator,
                series: $0.series,
                genres: $0.genres,
                thumb: $0.thumb
            )
        }
    }

    func fetchBrowseSlices(mediaType: String) throws -> [BookBrowseSlice] {
        let localMediaType = mediaType
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate<BookRecord> { record in
                record.mediaType == localMediaType && !record.isDeleted && !record.isHidden
            }
        )
        descriptor.propertiesToFetch = [
            \BookRecord.bookId, \BookRecord.mediaType, \BookRecord.author, \BookRecord.narrator, \BookRecord.series, \BookRecord.genres,
            \BookRecord.thumb,
        ]
        return try modelContext.fetch(descriptor).map {
            BookBrowseSlice(
                id: $0.bookId,
                mediaType: $0.mediaType,
                author: $0.author,
                narrator: $0.narrator,
                series: $0.series,
                genres: $0.genres,
                thumb: $0.thumb
            )
        }
    }

    func fetchBrowseAuthorAggregates(mediaType: String, pageSize: Int = 1000) throws -> [BrowseAuthorAggregate] {
        struct Row {
            let uniqueId: String
            let lookupName: String?
            let thumb: String?
            let authors: [String]
        }

        let localMediaType = mediaType
        var rows: [Row] = []
        var lowerBound = ""
        while true {
            guard !Task.isCancelled else { return [] }
            let cursor = lowerBound
            // Lexical order keeps the sort consistent with the SQL `>` keyset predicate.
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate<BookRecord> { record in
                    record.mediaType == localMediaType && !record.isDeleted && record.uniqueId > cursor
                },
                sortBy: [SortDescriptor(\.uniqueId, comparator: .lexical)]
            )
            descriptor.fetchLimit = pageSize
            descriptor.propertiesToFetch = [\BookRecord.uniqueId, \BookRecord.author, \BookRecord.authors, \BookRecord.thumb]
            let page = try autoreleasepool {
                try modelContext.fetch(descriptor).map { record in
                    let lookupName = record.author?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return Row(
                        uniqueId: record.uniqueId,
                        lookupName: lookupName?.isEmpty == false ? lookupName : nil,
                        thumb: record.thumb?.isEmpty == false ? record.thumb : nil,
                        authors: authorNames(for: record)
                    )
                }
            }
            rows += page
            guard page.count == pageSize, let last = page.last else { break }
            lowerBound = last.uniqueId
        }

        let canonicalMap = NameNormalizer.buildCanonicalMap(from: rows.flatMap(\.authors))

        struct Acc {
            var count = 0
            var thumb: String?
            var bookUniqueID: String
            var matchingNames = Set<String>()
        }
        var bucket: [String: Acc] = [:]
        for row in rows {
            for author in row.authors {
                let displayName = NameNormalizer.canonicalName(for: author, using: canonicalMap)
                var acc = bucket[displayName] ?? Acc(thumb: row.thumb, bookUniqueID: row.uniqueId)
                acc.count += 1
                if let lookupName = row.lookupName { acc.matchingNames.insert(lookupName) }
                acc.matchingNames.insert(author)
                if acc.thumb == nil, let thumb = row.thumb {
                    acc.thumb = thumb
                    acc.bookUniqueID = row.uniqueId
                }
                bucket[displayName] = acc
            }
        }
        return bucket.map {
            BrowseAuthorAggregate(
                name: $0.key,
                bookCount: $0.value.count,
                representativeThumb: $0.value.thumb,
                representativeBookUniqueID: $0.value.bookUniqueID,
                matchingNames: $0.value.matchingNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            )
        }
    }

    func fetchBrowseNarratorAggregates(mediaType: String) throws -> [BrowseNarratorAggregate] {
        let localMediaType = mediaType
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate<BookRecord> { record in
                record.mediaType == localMediaType && !record.isDeleted
            }
        )
        descriptor.propertiesToFetch = [\BookRecord.narrator, \BookRecord.thumb]
        let rows = try modelContext.fetch(descriptor)

        struct Acc { var count: Int = 0; var thumb: String? = nil }
        var bucket: [String: Acc] = [:]
        for row in rows {
            guard let raw = row.narrator?.trimmingCharacters(in: .whitespacesAndNewlines),
                !raw.isEmpty
            else { continue }
            var acc = bucket[raw, default: Acc()]
            acc.count += 1
            if acc.thumb == nil, let t = row.thumb, !t.isEmpty { acc.thumb = t }
            bucket[raw] = acc
        }
        return bucket.map { BrowseNarratorAggregate(name: $0.key, bookCount: $0.value.count, representativeThumb: $0.value.thumb) }
    }

    func fetchBooksByAuthor(author: String, mediaType: String, limit: Int) throws -> [Book] {
        let localAuthor = author
        let localMediaType = mediaType
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate<BookRecord> { record in
                record.author == localAuthor
                    && record.mediaType == localMediaType
                    && !record.isDeleted
            },
            sortBy: [SortDescriptor(\.seriesSequence), SortDescriptor(\.title)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
    }

    func fetchBooksByAuthorNames(authorNames: [String], mediaType: String, limit: Int) throws -> [Book] {
        guard limit > 0 else { return [] }
        let names = normalizedLookupNames(authorNames)
        var books: [Book] = []
        var seen = Set<String>()

        for name in names where books.count < limit {
            let localAuthor = name
            let localMediaType = mediaType
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate<BookRecord> { record in
                    record.author == localAuthor
                        && record.mediaType == localMediaType
                        && !record.isDeleted
                },
                sortBy: [SortDescriptor(\.seriesSequence), SortDescriptor(\.title)]
            )
            descriptor.fetchLimit = limit - books.count
            for book in try modelContext.fetch(descriptor).compactMap({ $0.toBook() })
            where seen.insert(book.stableId).inserted {
                books.append(book)
            }
        }

        return books.sorted(by: seriesOrder)
    }

    func fetchBooksByNarrator(narrator: String, mediaType: String, limit: Int) throws -> [Book] {
        let localNarrator = narrator
        let localMediaType = mediaType
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate<BookRecord> { record in
                record.narrator == localNarrator
                    && record.mediaType == localMediaType
                    && !record.isDeleted
            },
            sortBy: [SortDescriptor(\.title)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
    }

    func fetchBooksBySeries(series: String, mediaType: String, limit: Int) throws -> [Book] {
        let localSeries = series
        let localMediaType = mediaType
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate<BookRecord> { record in
                record.series == localSeries
                    && record.mediaType == localMediaType
                    && !record.isDeleted
            },
            sortBy: [SortDescriptor(\.seriesSequence), SortDescriptor(\.title)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
    }

    func fetchBooksBySeriesNames(seriesNames: [String], mediaType: String, limit: Int) throws -> [Book] {
        guard limit > 0 else { return [] }
        let names = normalizedLookupNames(seriesNames)
        var books: [Book] = []
        var seen = Set<String>()

        for name in names where books.count < limit {
            let localSeries = name
            let localMediaType = mediaType
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate<BookRecord> { record in
                    record.series == localSeries
                        && record.mediaType == localMediaType
                        && !record.isDeleted
                },
                sortBy: [SortDescriptor(\.seriesSequence), SortDescriptor(\.title)]
            )
            descriptor.fetchLimit = limit - books.count
            for book in try modelContext.fetch(descriptor).compactMap({ $0.toBook() })
            where seen.insert(book.stableId).inserted {
                books.append(book)
            }
        }

        return books.sorted(by: seriesOrder)
    }

    func fetchBooksInSeries(_ seriesName: String) throws -> [Book] {
        let normalizedSeries = NameNormalizer.normalizeSeriesName(seriesName)
        let descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate<BookRecord> { record in
                record.series != nil && !record.isDeleted
            }
        )
        return try modelContext.fetch(descriptor)
            .filter { record in
                guard let series = record.series else { return false }
                return NameNormalizer.normalizeSeriesName(series) == normalizedSeries
            }
            .compactMap { $0.toBook() }
            .sorted(by: seriesOrder)
    }

    func fetchBooksInSeriesNames(_ seriesNames: [String]) throws -> [Book] {
        let names = normalizedLookupNames(seriesNames)
        var books: [Book] = []
        var seen = Set<String>()

        for name in names {
            let localSeries = name
            let descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate<BookRecord> { record in
                    record.series == localSeries && !record.isDeleted
                },
                sortBy: [SortDescriptor(\.seriesSequence), SortDescriptor(\.title)]
            )
            for book in try modelContext.fetch(descriptor).compactMap({ $0.toBook() })
            where seen.insert(book.stableId).inserted {
                books.append(book)
            }
        }

        return books.sorted(by: seriesOrder)
    }

    private func normalizedLookupNames(_ names: [String]) -> [String] {
        Array(Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func authorNames(for row: BookRecord) -> [String] {
        let source = row.authors?.isEmpty == false ? row.authors ?? [] : splitAuthorDisplay(row.author)
        var seen = Set<String>()
        return source.compactMap { raw -> String? in
            let cleaned = cleanAuthorName(raw)
            guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { return nil }
            return cleaned
        }
    }

    private func splitAuthorDisplay(_ author: String?) -> [String] {
        guard let author = author?.trimmingCharacters(in: .whitespacesAndNewlines),
            !author.isEmpty
        else { return [] }
        return author.components(separatedBy: ",")
    }

    private func cleanAuthorName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let rolePatterns = [
            #"\s*[-\x{2013}\x{2014}]\s*(?:translator|editor|illustrator|adapter|contributor)\s*$"#,
            #"\s*\((?:translator|editor|illustrator|adapter|contributor)\)\s*$"#,
        ]
        for pattern in rolePatterns {
            name = name.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func seriesOrder(_ lhs: Book, _ rhs: Book) -> Bool {
        let l = lhs.seriesSequence.flatMap(Double.init) ?? lhs.seriesNumber.map(Double.init) ?? .greatestFiniteMagnitude
        let r = rhs.seriesSequence.flatMap(Double.init) ?? rhs.seriesNumber.map(Double.init) ?? .greatestFiniteMagnitude
        if l != r { return l < r }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}
