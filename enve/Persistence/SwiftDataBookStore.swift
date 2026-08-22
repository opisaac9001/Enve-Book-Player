import Foundation
import Logging
import SwiftData

final class SwiftDataBookStore: BookStoreRepository, @unchecked Sendable {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    @ModelActor
    actor Worker {
        private func deduplicatedBooks(_ books: [Book]) -> [Book] {
            var indexByUniqueId: [String: Int] = [:]
            var result: [Book] = []
            result.reserveCapacity(books.count)

            for book in books {
                if let index = indexByUniqueId[book.uniqueId] {
                    result[index] = book
                } else {
                    indexByUniqueId[book.uniqueId] = result.count
                    result.append(book)
                }
            }

            if result.count != books.count {
                AppLogger.general.warning("BookStore deduplicated \(books.count - result.count) repeated uniqueId value(s) before saving")
            }
            return result
        }

        func fetchAllBooks() throws -> [Book] {
            let pageSize = 1000
            var books: [Book] = []
            var offset = 0
            while true {
                var descriptor = FetchDescriptor<BookRecord>(
                    predicate: #Predicate { !$0.isDeleted },
                    sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
                )
                descriptor.fetchLimit = pageSize
                descriptor.fetchOffset = offset
                let page = try modelContext.fetch(descriptor)
                if page.isEmpty { break }
                books.append(contentsOf: page.compactMap { $0.toBook() })
                if page.count < pageSize { break }
                offset += pageSize
            }
            if books.count > 5000 {
                AppLogger.general.warning(
                    "BookStore.fetchAllBooks materialized \(books.count) books; caller should migrate to fetchPaged or a projection for memory safety"
                )
            }
            return books
        }

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

        func fetchBrowseAuthorAggregates(mediaType: String) throws -> [BrowseAuthorAggregate] {
            let localMediaType = mediaType
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate<BookRecord> { record in
                    record.mediaType == localMediaType && !record.isDeleted
                }
            )
            descriptor.propertiesToFetch = [\BookRecord.author, \BookRecord.authors, \BookRecord.thumb]
            let rows = try modelContext.fetch(descriptor)

            let namesByRow = rows.map { row in (row, authorNames(for: row)) }
            let canonicalMap = NameNormalizer.buildCanonicalMap(from: namesByRow.flatMap(\.1))

            struct Acc {
                var count: Int = 0
                var thumb: String?
                var matchingNames = Set<String>()
            }
            var bucket: [String: Acc] = [:]
            for (row, authors) in namesByRow where !authors.isEmpty {
                let rawLookupName = row.author?.trimmingCharacters(in: .whitespacesAndNewlines)
                for author in Set(authors) {
                    let displayName = NameNormalizer.canonicalName(for: author, using: canonicalMap)
                    var acc = bucket[displayName, default: Acc()]
                    acc.count += 1
                    if let rawLookupName, !rawLookupName.isEmpty { acc.matchingNames.insert(rawLookupName) }
                    acc.matchingNames.insert(author)
                    if acc.thumb == nil, let t = row.thumb, !t.isEmpty { acc.thumb = t }
                    bucket[displayName] = acc
                }
            }
            return bucket.map {
                BrowseAuthorAggregate(
                    name: $0.key,
                    bookCount: $0.value.count,
                    representativeThumb: $0.value.thumb,
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

        func fetchBrowseSeriesAggregates(mediaType: String) throws -> [BrowseSeriesAggregate] {
            let localMediaType = mediaType
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate<BookRecord> { record in
                    record.mediaType == localMediaType && !record.isDeleted
                }
            )
            descriptor.propertiesToFetch = [
                \BookRecord.series,
                \BookRecord.thumb,
                \BookRecord.currentTime,
                \BookRecord.duration,
                \BookRecord.ebookProgress,
                \BookRecord.isFinished,
            ]
            let rows = try modelContext.fetch(descriptor)

            struct Acc {
                var count: Int = 0
                var completedCount: Int = 0
                var thumb: String?
                var matchingNames = Set<String>()
            }
            var bucket: [String: Acc] = [:]
            for row in rows {
                guard let raw = row.series?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !raw.isEmpty
                else { continue }
                let displayName = NameNormalizer.normalizeSeriesName(raw)
                var acc = bucket[displayName, default: Acc()]
                acc.count += 1
                let progress = localMediaType == "ebook"
                    ? row.ebookProgress ?? 0
                    : row.duration.map { $0 > 0 ? row.currentTime / $0 : 0 } ?? 0
                if row.isFinished || progress >= 0.99 {
                    acc.completedCount += 1
                }
                acc.matchingNames.insert(raw)
                if acc.thumb == nil, let t = row.thumb, !t.isEmpty { acc.thumb = t }
                bucket[displayName] = acc
            }
            return bucket.map {
                BrowseSeriesAggregate(
                    name: $0.key,
                    bookCount: $0.value.count,
                    completedBookCount: $0.value.completedCount,
                    representativeThumb: $0.value.thumb,
                    matchingNames: $0.value.matchingNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                )
            }
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

        func fetchBooksByWorkKey(_ key: String) throws -> [Book] {
            guard !key.isEmpty else { return [] }
            try backfillWorkKeysIfNeeded()
            let localKey = key
            let descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate<BookRecord> { record in
                    record.workKey == localKey && !record.isDeleted
                },
                sortBy: [SortDescriptor(\.title)]
            )
            return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
        }

        func fetchBooksByEditionKey(_ key: String) throws -> [Book] {
            guard !key.isEmpty else { return [] }
            try backfillWorkKeysIfNeeded()
            let localKey = key
            let descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate<BookRecord> { record in
                    record.editionKey == localKey && !record.isDeleted
                }
            )
            return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
        }

        func fetchBooksWithIdentifiers(limit: Int) throws -> [Book] {
            try backfillWorkKeysIfNeeded()
            var d1 = FetchDescriptor<BookRecord>(
                predicate: #Predicate<BookRecord> { $0.isbn != nil && !$0.isDeleted }
            )
            d1.fetchLimit = limit
            var d2 = FetchDescriptor<BookRecord>(
                predicate: #Predicate<BookRecord> { $0.asin != nil && !$0.isDeleted }
            )
            d2.fetchLimit = limit
            var seen = Set<String>()
            var result: [Book] = []
            for record in try modelContext.fetch(d1) + (try modelContext.fetch(d2)) {
                let hasISBN = !(record.isbn ?? "").isEmpty
                let hasASIN = !(record.asin ?? "").isEmpty
                guard hasISBN || hasASIN, seen.insert(record.uniqueId).inserted,
                    let book = record.toBook()
                else { continue }
                result.append(book)
            }
            return result
        }

        func fetchWorkSlices() throws -> [WorkSlice] {
            try backfillWorkKeysIfNeeded()
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate<BookRecord> { record in
                    !record.isDeleted && !record.isHidden && record.workKey != ""
                }
            )
            descriptor.propertiesToFetch = [\.uniqueId, \.stableId, \.workKey, \.source, \.thumb, \.bookDescription]
            return try modelContext.fetch(descriptor).map { record in
                var score = 0
                if record.source == "local" { score += 4 }
                if record.thumb?.isEmpty == false { score += 2 }
                if record.bookDescription?.isEmpty == false { score += 1 }
                return WorkSlice(uniqueId: record.uniqueId, stableId: record.stableId, workKey: record.workKey, score: score)
            }
        }

        func fetchActiveBooks(excludingSource: String, minProgress: Double) throws -> [Book] {
            let descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate<BookRecord> { record in !record.isDeleted },
                sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
            )
            let result = try modelContext.fetch(descriptor).compactMap { $0.toBook() }
            AppLogger.general.info("BookStore.activeBooks: \(result.count) books loaded from cache")
            return result
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

        func fetchFirstBooksForLibrary(libraryId: String, providerId: String, limit: Int) throws -> [Book] {
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.libraryId == libraryId && $0.providerId == providerId && !$0.isDeleted
                },
                sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
            )
            descriptor.fetchLimit = limit
            let books = try modelContext.fetch(descriptor).compactMap { $0.toBook() }
            if books.count == limit {
                AppLogger.general.warning(
                    "BookStore.firstBooksForLibrary returned exactly limit=\(limit) - more rows likely exist; caller should paginate"
                )
            }
            return books
        }

        func fetchBooksWithIds(_ ids: [String]) throws -> [Book] {
            guard !ids.isEmpty else { return [] }
            let idSet = Set(ids)
            let descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { record in
                    !record.isDeleted && (idSet.contains(record.bookId) || idSet.contains(record.stableId))
                }
            )
            return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
        }

        func fetchBookByUniqueId(_ uid: String) throws -> Book? {
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { $0.uniqueId == uid }
            )
            descriptor.fetchLimit = 1
            return try modelContext.fetch(descriptor).first?.toBook()
        }

        func fetchBookByStableId(_ sid: String) throws -> Book? {
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { $0.stableId == sid && !$0.isDeleted }
            )
            descriptor.fetchLimit = 1
            return try modelContext.fetch(descriptor).first?.toBook()
        }

        func fetchAbsorbedStableIds() throws -> Set<String> {
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { $0.readAloudSourceStableId != nil && !$0.isDeleted }
            )
            descriptor.propertiesToFetch = [\BookRecord.readAloudSourceStableId, \BookRecord.linkedAudiobookStableId]
            var ids = Set<String>()
            for record in try modelContext.fetch(descriptor) {
                if let s = record.readAloudSourceStableId, !s.isEmpty { ids.insert(s) }
                if let a = record.linkedAudiobookStableId, !a.isEmpty { ids.insert(a) }
            }
            return ids
        }

        func fetchExistingAudiobookStableIds(from candidates: Set<String>) throws -> Set<String> {
            guard !candidates.isEmpty else { return [] }
            let audioType = "audiobook"
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.mediaType == audioType && !$0.isDeleted && candidates.contains($0.stableId)
                }
            )
            descriptor.propertiesToFetch = [\BookRecord.stableId]
            return Set(try modelContext.fetch(descriptor).map { $0.stableId })
        }

        func fetchBooksByIds(ids: Set<String>) throws -> [String: Book] {
            guard !ids.isEmpty else { return [:] }
            let safeIds = ids.filter { !$0.isEmpty }
            guard !safeIds.isEmpty else { return [:] }

            let bookIdDescriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { safeIds.contains($0.bookId) }
            )
            var lookup = [String: Book](minimumCapacity: safeIds.count * 2)
            for record in try modelContext.fetch(bookIdDescriptor) {
                guard let book = record.toBook() else { continue }
                lookup[record.bookId] = book
            }
            for id in safeIds {
                if lookup.keys.contains(id) { continue }
                let lookupId = id
                var d = FetchDescriptor<BookRecord>(
                    predicate: #Predicate { $0.partKey == lookupId }
                )
                d.fetchLimit = 1
                if let record = try modelContext.fetch(d).first, let book = record.toBook() {
                    lookup[id] = book
                }
            }
            return lookup
        }

        func fetchBooksByUniqueIds(ids: Set<String>) throws -> [String: Book] {
            guard !ids.isEmpty else { return [:] }
            let descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { ids.contains($0.uniqueId) }
            )
            var lookup = [String: Book](minimumCapacity: ids.count)
            for record in try modelContext.fetch(descriptor) {
                guard let book = record.toBook() else { continue }
                lookup[record.uniqueId] = book
            }
            return lookup
        }

        func fetchBooksByStableIds(ids: Set<String>) throws -> [String: Book] {
            guard !ids.isEmpty else { return [:] }
            let safeIds = ids.filter { !$0.isEmpty }
            guard !safeIds.isEmpty else { return [:] }

            let descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { !$0.isDeleted && safeIds.contains($0.stableId) }
            )
            var lookup = [String: Book](minimumCapacity: safeIds.count)
            for record in try modelContext.fetch(descriptor) {
                guard let book = record.toBook() else { continue }
                lookup[record.stableId] = book
            }
            return lookup
        }

        func fetchBooksByAnyIds(ids: Set<String>) throws -> [String: Book] {
            guard !ids.isEmpty else { return [:] }
            let safeIds = ids.filter { !$0.isEmpty }
            guard !safeIds.isEmpty else { return [:] }

            let descriptors = [
                FetchDescriptor<BookRecord>(
                    predicate: #Predicate { !$0.isDeleted && safeIds.contains($0.bookId) }
                ),
                FetchDescriptor<BookRecord>(
                    predicate: #Predicate { !$0.isDeleted && safeIds.contains($0.stableId) }
                ),
                FetchDescriptor<BookRecord>(
                    predicate: #Predicate { !$0.isDeleted && safeIds.contains($0.uniqueId) }
                ),
                FetchDescriptor<BookRecord>(
                    predicate: #Predicate { !$0.isDeleted && safeIds.contains($0.ratingKey) }
                ),
            ]
            var lookup = [String: Book](minimumCapacity: safeIds.count)
            for descriptor in descriptors {
                for record in try modelContext.fetch(descriptor) {
                    guard let book = record.toBook() else { continue }
                    if safeIds.contains(record.bookId) { lookup[record.bookId] = book }
                    if safeIds.contains(record.stableId) { lookup[record.stableId] = book }
                    if safeIds.contains(record.uniqueId) { lookup[record.uniqueId] = book }
                    if safeIds.contains(record.ratingKey) { lookup[record.ratingKey] = book }
                }
            }
            return lookup
        }

        func fetchSmartCandidates(rules ruleGroup: SmartCollectionRuleGroup, limit: Int?) throws -> [Book] {
            let predicate = SmartCollectionPredicateBuilder.build(ruleGroup: ruleGroup)
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: predicate,
                sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
            )
            if let limit { descriptor.fetchLimit = limit }
            return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
        }

        func fetchSmartCountIfExpressible(rules ruleGroup: SmartCollectionRuleGroup) throws -> Int? {
            for rule in ruleGroup.rules {
                switch rule.field {
                case .genre, .isDownloaded:
                    return nil
                default:
                    continue
                }
            }
            let predicate = SmartCollectionPredicateBuilder.build(ruleGroup: ruleGroup)
            let descriptor = FetchDescriptor<BookRecord>(predicate: predicate)
            return try modelContext.fetchCount(descriptor)
        }

        func fetchContinueListening(limit: Int) throws -> [Book] {
            let audioType = "audiobook"
            let readStatus = "READ"

            var audioDescriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.mediaType == audioType
                        && !$0.isFinished
                        && !$0.isDeleted
                        && !$0.isHidden
                        && !$0.hideFromContinue
                        && $0.currentTime > 0
                        && ($0.serverReadStatus == nil || $0.serverReadStatus != readStatus)
                },
                sortBy: [SortDescriptor(\.lastUpdate, order: .reverse)]
            )
            audioDescriptor.fetchLimit = limit

            return try modelContext.fetch(audioDescriptor).compactMap { $0.toBook() }
        }

        func fetchContinueReading(limit: Int) throws -> [Book] {
            let ebookType = "ebook"
            let readStatus = "READ"

            var progressDescriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.mediaType == ebookType
                        && !$0.isFinished
                        && !$0.isDeleted
                        && !$0.isHidden
                        && !$0.hideFromContinue
                        && $0.ebookProgress != nil
                        && ($0.serverReadStatus == nil || $0.serverReadStatus != readStatus)
                },
                sortBy: [SortDescriptor(\.lastUpdate, order: .reverse)]
            )
            progressDescriptor.fetchLimit = limit

            var linkedAudiobookDescriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.mediaType == ebookType
                        && !$0.isFinished
                        && !$0.isDeleted
                        && !$0.isHidden
                        && !$0.hideFromContinue
                        && $0.currentTime > 0
                        && $0.linkedAudiobookStableId != nil
                        && ($0.serverReadStatus == nil || $0.serverReadStatus != readStatus)
                },
                sortBy: [SortDescriptor(\.lastUpdate, order: .reverse)]
            )
            linkedAudiobookDescriptor.fetchLimit = limit

            var readAloudDescriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.mediaType == ebookType
                        && !$0.isFinished
                        && !$0.isDeleted
                        && !$0.isHidden
                        && !$0.hideFromContinue
                        && $0.currentTime > 0
                        && $0.readAloudSourceStableId != nil
                        && ($0.serverReadStatus == nil || $0.serverReadStatus != readStatus)
                },
                sortBy: [SortDescriptor(\.lastUpdate, order: .reverse)]
            )
            readAloudDescriptor.fetchLimit = limit

            var mediaOverlayDescriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.mediaType == ebookType
                        && !$0.isFinished
                        && !$0.isDeleted
                        && !$0.isHidden
                        && !$0.hideFromContinue
                        && $0.currentTime > 0
                        && $0.epub3HasMediaOverlay
                        && ($0.serverReadStatus == nil || $0.serverReadStatus != readStatus)
                },
                sortBy: [SortDescriptor(\.lastUpdate, order: .reverse)]
            )
            mediaOverlayDescriptor.fetchLimit = limit

            let progressBooks = try modelContext.fetch(progressDescriptor).compactMap { $0.toBook() }.filter {
                ($0.ebookProgress ?? 0) > 0.001
            }
            let linkedBooks = try modelContext.fetch(linkedAudiobookDescriptor).compactMap { $0.toBook() }
            let readAloudBooks = try modelContext.fetch(readAloudDescriptor).compactMap { $0.toBook() }
            let mediaOverlayBooks = try modelContext.fetch(mediaOverlayDescriptor).compactMap { $0.toBook() }
            var seen = Set<String>()
            return (progressBooks + linkedBooks + readAloudBooks + mediaOverlayBooks)
                .filter { seen.insert($0.stableId).inserted }
                .sorted { $0.lastUpdate > $1.lastUpdate }
                .prefix(limit)
                .map { $0 }
        }

        func fetchRecent(mediaType: String, limit: Int) throws -> [Book] {
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.mediaType == mediaType && !$0.isDeleted && !$0.isHidden
                },
                sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
            )
            descriptor.fetchLimit = limit
            return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
        }

        func fetchDownloadedEbooks(limit: Int) throws -> [Book] {
            let ebookType = "ebook"
            let localSource = Book.BookSource.local.rawValue
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.mediaType == ebookType
                        && !$0.isDeleted
                        && !$0.isHidden
                        && ($0.ebookFileURLPath != nil || ($0.source == localSource && $0.filePath != nil))
                },
                sortBy: [SortDescriptor(\.lastUpdate, order: .reverse)]
            )
            descriptor.fetchLimit = limit
            let fetched = try modelContext.fetch(descriptor).compactMap { $0.toBook() }

            let docs = URL.documentsDirectory
            let serverRoot = docs.appendingPathComponent("Ebooks").path
            let localRoot = docs.appendingPathComponent("Ebooks/local").path
            let readaloudRoot = docs.appendingPathComponent("Ebooks/readaloud").path
            return fetched.filter { book in
                if book.source == .local { return true }
                guard let url = book.ebookFileURL, FileManager.default.fileExists(atPath: url.path) else { return false }
                let p = url.path
                return p.hasPrefix(serverRoot) || p.hasPrefix(localRoot) || p.hasPrefix(readaloudRoot)
            }
        }

        func fetchBook(byBookId id: String) throws -> Book? {
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { $0.bookId == id }
            )
            descriptor.fetchLimit = 1
            return try modelContext.fetch(descriptor).first.flatMap { $0.toBook() }
        }

        func fetchBooks(source src: String, providerIdString pid: String) throws -> [Book] {
            let descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.source == src && $0.providerId == pid && !$0.isDeleted && !$0.isHidden
                },
                sortBy: [SortDescriptor(\.title)]
            )
            return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
        }

        func fetchBooks(source src: String, providerIdString pid: String, mediaType mt: String) throws -> [Book] {
            let descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.source == src && $0.providerId == pid && $0.mediaType == mt
                        && !$0.isDeleted && !$0.isHidden
                },
                sortBy: [SortDescriptor(\.title)]
            )
            return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
        }

        func fetchAllBookUniqueIds() throws -> [String] {
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { !$0.isDeleted && !$0.isHidden }
            )
            descriptor.propertiesToFetch = [\BookRecord.uniqueId]
            return try modelContext.fetch(descriptor).map { $0.uniqueId }
        }

        func fetchAllBookIds() throws -> [String] {
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { !$0.isDeleted && !$0.isHidden }
            )
            descriptor.propertiesToFetch = [\BookRecord.bookId]
            return try modelContext.fetch(descriptor).map { $0.bookId }
        }

        func fetchBookCountsBySource() throws -> [(source: String, count: Int)] {
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { !$0.isDeleted }
            )
            descriptor.propertiesToFetch = [\BookRecord.source]
            let records = try modelContext.fetch(descriptor)
            var counts: [String: Int] = [:]
            for r in records { counts[r.source, default: 0] += 1 }
            return counts.map { ($0.key, $0.value) }.sorted { $0.count > $1.count }
        }

        func fetchBookCountsBySection(source src: String) throws -> [(libraryId: String, providerId: String, count: Int)] {
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { $0.source == src && !$0.isDeleted }
            )
            descriptor.propertiesToFetch = [\BookRecord.libraryId, \BookRecord.providerId]
            let records = try modelContext.fetch(descriptor)
            var counts: [String: (lib: String, prov: String, n: Int)] = [:]
            for r in records {
                let key = "\(r.providerId)|\(r.libraryId)"
                if let existing = counts[key] {
                    counts[key] = (existing.lib, existing.prov, existing.n + 1)
                } else {
                    counts[key] = (r.libraryId, r.providerId, 1)
                }
            }
            return counts.values.map { ($0.lib, $0.prov, $0.n) }.sorted { $0.count > $1.count }
        }

        func deleteBooksFromUnknownProviders(validProviderIds: Set<String>) throws -> Int {
            let predicate = #Predicate<BookRecord> { record in
                record.source != "local" && record.source != "smb"
                    && !validProviderIds.contains(record.providerId)
            }
            let count = try modelContext.fetchCount(FetchDescriptor<BookRecord>(predicate: predicate))
            guard count > 0 else { return 0 }
            try modelContext.delete(model: BookRecord.self, where: predicate)
            try modelContext.save()
            return count
        }

        func deleteBooksFromInactiveLibraries(
            validProviderIds: Set<String>,
            restrictedLibraryIds: [String: Set<String>]
        ) throws -> Int {
            var totalDeleted = 0

            let unknownPredicate = #Predicate<BookRecord> { record in
                record.source != "local" && record.source != "smb"
                    && !validProviderIds.contains(record.providerId)
            }
            let unknownCount = try modelContext.fetchCount(FetchDescriptor<BookRecord>(predicate: unknownPredicate))
            if unknownCount > 0 {
                try modelContext.delete(model: BookRecord.self, where: unknownPredicate)
                totalDeleted += unknownCount
            }

            for (providerId, allowedLibraryIds) in restrictedLibraryIds {
                let pid = providerId
                let allowed = allowedLibraryIds
                let restrictedPredicate = #Predicate<BookRecord> { record in
                    record.providerId == pid
                        && record.source != "local" && record.source != "smb"
                        && !allowed.contains(record.libraryId)
                }
                let count = try modelContext.fetchCount(FetchDescriptor<BookRecord>(predicate: restrictedPredicate))
                if count > 0 {
                    try modelContext.delete(model: BookRecord.self, where: restrictedPredicate)
                    totalDeleted += count
                }
            }

            if totalDeleted > 0 {
                try modelContext.save()
            }
            return totalDeleted
        }

        func fetchBooks(backendId bid: String, source src: String?) throws -> [Book] {
            let descriptor: FetchDescriptor<BookRecord>
            if let src {
                descriptor = FetchDescriptor<BookRecord>(
                    predicate: #Predicate {
                        $0.backendId == bid && $0.source == src && !$0.isDeleted && !$0.isHidden
                    },
                    sortBy: [SortDescriptor(\.title)]
                )
            } else {
                descriptor = FetchDescriptor<BookRecord>(
                    predicate: #Predicate {
                        $0.backendId == bid && !$0.isDeleted && !$0.isHidden
                    },
                    sortBy: [SortDescriptor(\.title)]
                )
            }
            return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
        }

        func fetchFirstBooksWithReadAloudSource(limit: Int) throws -> [Book] {
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.readAloudSourceStableId != nil && !$0.isDeleted && !$0.isHidden
                },
                sortBy: [SortDescriptor(\.title)]
            )
            descriptor.fetchLimit = limit
            return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
        }

        func fetchFirstBooksWithoutReadAloudSource(limit: Int) throws -> [Book] {
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.readAloudSourceStableId == nil && !$0.isDeleted && !$0.isHidden
                },
                sortBy: [SortDescriptor(\.title)]
            )
            descriptor.fetchLimit = limit
            let books = try modelContext.fetch(descriptor).compactMap { $0.toBook() }
            if books.count == limit {
                AppLogger.general.warning(
                    "BookStore.firstBooksWithoutReadAloudSource returned exactly limit=\(limit) - more rows likely exist"
                )
            }
            return books
        }

        func fetchBookCountWithReadAloudSource() throws -> Int {
            let descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.readAloudSourceStableId != nil && !$0.isDeleted && !$0.isHidden
                }
            )
            return try modelContext.fetchCount(descriptor)
        }

        func hasBook(stableId sid: String, requireWithoutReadAloudSource: Bool) throws -> Bool {
            var descriptor: FetchDescriptor<BookRecord>
            if requireWithoutReadAloudSource {
                descriptor = FetchDescriptor<BookRecord>(
                    predicate: #Predicate {
                        $0.stableId == sid && $0.readAloudSourceStableId == nil
                            && !$0.isDeleted && !$0.isHidden
                    }
                )
            } else {
                descriptor = FetchDescriptor<BookRecord>(
                    predicate: #Predicate {
                        $0.stableId == sid && !$0.isDeleted && !$0.isHidden
                    }
                )
            }
            descriptor.fetchLimit = 1
            return try modelContext.fetchCount(descriptor) > 0
        }

        func fetchBookPresence() throws -> BookPresence {
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { !$0.isDeleted && !$0.isHidden }
            )
            descriptor.propertiesToFetch = [
                \BookRecord.libraryId, \BookRecord.providerId,
                \BookRecord.source, \BookRecord.backendId,
                \BookRecord.readAloudSourceStableId,
            ]
            var libraryKeys = Set<String>()
            var smbBackendIds = Set<String>()
            var hasReadAloud = false
            for record in try modelContext.fetch(descriptor) {
                if record.readAloudSourceStableId != nil { hasReadAloud = true }
                if record.source == "smb" {
                    if let id = record.backendId { smbBackendIds.insert(id) }
                } else {
                    libraryKeys.insert("\(record.libraryId)|\(record.providerId)")
                }
            }
            return BookPresence(libraryKeys: libraryKeys, smbBackendIds: smbBackendIds, hasReadAloud: hasReadAloud)
        }

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

        private func backfillSortKeysIfNeeded() throws {
            let flag = "imagine.bookSortKeysBackfilled.v1"
            if UserDefaults.standard.bool(forKey: flag) { return }
            let pageSize = 2000
            var offset = 0
            while true {
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

        private nonisolated static func sortDescriptors(for descriptors: [BookStoreSortDescriptor]) -> [SortDescriptor<BookRecord>] {
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

        func fetchFirstBooksByMediaType(mediaType: String, limit: Int) throws -> [Book] {
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.mediaType == mediaType && !$0.isDeleted && !$0.isHidden
                },
                sortBy: [SortDescriptor(\.title)]
            )
            descriptor.fetchLimit = limit
            let books = try modelContext.fetch(descriptor).compactMap { $0.toBook() }
            if books.count == limit {
                AppLogger.general.warning(
                    "BookStore.firstBooks(mediaType:\(mediaType)) returned exactly limit=\(limit) - more rows likely exist; caller should paginate"
                )
            }
            return books
        }

        func fetchTitleAuthorPairs() throws -> [(title: String, author: String)] {
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { !$0.isDeleted && !$0.isHidden }
            )
            descriptor.propertiesToFetch = [\BookRecord.title, \BookRecord.author]
            return try modelContext.fetch(descriptor).map { ($0.title, $0.author ?? "") }
        }

        func fetchBookCountByMediaType(_ mediaType: String) throws -> Int {
            let descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.mediaType == mediaType && !$0.isDeleted && !$0.isHidden
                }
            )
            return try modelContext.fetchCount(descriptor)
        }

        func fetchFirstBooksBySource(source: String, mediaType: String, limit: Int) throws -> [Book] {
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.source == source && $0.mediaType == mediaType && !$0.isDeleted
                },
                sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
            )
            descriptor.fetchLimit = limit
            let books = try modelContext.fetch(descriptor).compactMap { $0.toBook() }
            if books.count == limit {
                AppLogger.general.warning(
                    "BookStore.firstBooks(source:\(source),mediaType:\(mediaType)) returned exactly limit=\(limit) - more rows likely exist; caller should paginate"
                )
            }
            return books
        }

        func fetchBooksWithProgress(providerId: String) throws -> [Book] {
            let descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.providerId == providerId
                        && !$0.isDeleted
                        && ($0.currentTime > 0 || $0.ebookProgress != nil || $0.isFinished || $0.hideFromContinue)
                }
            )
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

        func backfillWorkKeysIfNeeded() throws {
            let flag = "imagine.workKeysBackfilled.v1"
            if UserDefaults.standard.bool(forKey: flag) { return }
            let pageSize = 2000
            var offset = 0
            while true {
                var d = FetchDescriptor<BookRecord>(sortBy: [SortDescriptor(\.uniqueId)])
                d.fetchLimit = pageSize
                d.fetchOffset = offset
                let page = try modelContext.fetch(d)
                if page.isEmpty { break }
                for r in page where r.workKey.isEmpty {
                    guard let book = r.toBook() else { continue }
                    r.workKey = WorkIdentity.workKey(for: book)
                    r.editionKey = WorkIdentity.editionKey(for: book)
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

        func upsert(_ books: [Book]) throws {
            let books = deduplicatedBooks(books)
            guard !books.isEmpty else { return }

            let incomingIds = Set(books.map(\.uniqueId))
            let descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { incomingIds.contains($0.uniqueId) }
            )
            let existingRecords = try modelContext.fetch(descriptor)
            var existingByUniqueId = Dictionary(
                existingRecords.map { ($0.uniqueId, $0) },
                uniquingKeysWith: { _, new in new }
            )
            for book in books {
                if let existing = existingByUniqueId[book.uniqueId] {
                    existing.update(from: book)
                } else {
                    let record = BookRecord(from: book)
                    modelContext.insert(record)
                    existingByUniqueId[book.uniqueId] = record
                }
            }
            try modelContext.save()
        }

        func replaceLibrary(books: [Book], libraryId: String, providerId: String, allowSparseResult: Bool) throws {
            let books = deduplicatedBooks(books)

            let start = beginReconciliation(libraryId: libraryId, providerId: providerId)

            let pageSize = 500
            for chunkStart in stride(from: 0, to: books.count, by: pageSize) {
                let chunkEnd = Swift.min(chunkStart + pageSize, books.count)
                try upsertReconciledPage(books: Array(books[chunkStart..<chunkEnd]), generation: start.generation)
            }
            _ = try endReconciliation(
                libraryId: libraryId,
                providerId: providerId,
                generation: start.generation,
                existingCountBefore: start.existingCount,
                allowSparseResult: allowSparseResult
            )
        }

        func beginReconciliation(libraryId: String, providerId: String) -> ReconciliationStart {

            let generation = Int(Date().timeIntervalSinceReferenceDate * 1000)
            let descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { $0.libraryId == libraryId && $0.providerId == providerId }
            )
            let existingCount = (try? modelContext.fetchCount(descriptor)) ?? 0
            return ReconciliationStart(generation: generation, existingCount: existingCount)
        }

        func upsertReconciledPage(books: [Book], generation: Int) throws {
            let books = deduplicatedBooks(books)
            guard !books.isEmpty else { return }
            let incomingIds = Set(books.map(\.uniqueId))
            let descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { incomingIds.contains($0.uniqueId) }
            )
            let existingRecords = try modelContext.fetch(descriptor)
            var existingByUniqueId = Dictionary(
                existingRecords.map { ($0.uniqueId, $0) },
                uniquingKeysWith: { _, new in new }
            )
            for book in books {
                if let record = existingByUniqueId[book.uniqueId] {
                    record.update(from: book)
                    record.syncGeneration = generation
                } else {
                    let record = BookRecord(from: book)
                    record.syncGeneration = generation
                    modelContext.insert(record)
                    existingByUniqueId[book.uniqueId] = record
                }
            }
            try modelContext.save()
        }

        func endReconciliation(
            libraryId: String,
            providerId: String,
            generation: Int,
            existingCountBefore: Int,
            allowSparseResult: Bool = false
        ) throws -> ReconciliationOutcome {
            let incomingDescriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.libraryId == libraryId
                        && $0.providerId == providerId
                        && $0.syncGeneration == generation
                }
            )
            let incomingCount = (try? modelContext.fetchCount(incomingDescriptor)) ?? 0

            if existingCountBefore >= 100
                && incomingCount * 2 < existingCountBefore
                && !allowSparseResult
            {
                AppLogger.general.error(
                    "BookStore.endReconciliation: refusing sparse response for libraryId=\(libraryId) - incoming \(incomingCount) vs existing \(existingCountBefore). Orphans preserved."
                )
                return .refusedSparseResponse(existing: existingCountBefore, incoming: incomingCount)
            }

            let orphanDescriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.libraryId == libraryId
                        && $0.providerId == providerId
                        && $0.syncGeneration != generation
                }
            )
            let toDeleteCount = (try? modelContext.fetchCount(orphanDescriptor)) ?? 0

            try modelContext.delete(
                model: BookRecord.self,
                where: #Predicate {
                    $0.libraryId == libraryId
                        && $0.providerId == providerId
                        && $0.syncGeneration != generation
                }
            )
            try modelContext.save()

            return .completed(deleted: toDeleteCount, kept: incomingCount)
        }

        func applyDelta(books: [Book], libraryId: String, providerId: String) throws {
            let books = deduplicatedBooks(books)
            guard !books.isEmpty else { return }
            let incomingIds = Set(books.map { $0.uniqueId })
            let descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { record in
                    record.libraryId == libraryId
                        && record.providerId == providerId
                        && incomingIds.contains(record.uniqueId)
                }
            )
            let existingRecords = try modelContext.fetch(descriptor)
            var existingByUniqueId = Dictionary(
                existingRecords.map { ($0.uniqueId, $0) },
                uniquingKeysWith: { _, new in new }
            )

            for book in books {
                if let record = existingByUniqueId[book.uniqueId] {
                    record.update(from: book)
                } else {
                    let record = BookRecord(from: book)
                    modelContext.insert(record)
                    existingByUniqueId[book.uniqueId] = record
                }
            }
            try modelContext.save()
        }

        func loadCursor(providerId: String, libraryId: String) throws -> LibrarySyncCursorSnapshot? {
            let descriptor = FetchDescriptor<LibrarySyncCursor>(
                predicate: #Predicate { $0.providerId == providerId && $0.libraryId == libraryId }
            )
            guard let row = try modelContext.fetch(descriptor).first else { return nil }
            return LibrarySyncCursorSnapshot(
                providerId: row.providerId,
                libraryId: row.libraryId,
                lastSyncedAt: row.lastSyncedAt,
                lastFullReconciledAt: row.lastFullReconciledAt
            )
        }

        func saveCursor(providerId: String, libraryId: String, lastSyncedAt: Date, lastFullReconciledAt: Date?) throws {
            let descriptor = FetchDescriptor<LibrarySyncCursor>(
                predicate: #Predicate { $0.providerId == providerId && $0.libraryId == libraryId }
            )
            if let existing = try modelContext.fetch(descriptor).first {
                existing.lastSyncedAt = lastSyncedAt
                if let full = lastFullReconciledAt {
                    existing.lastFullReconciledAt = full
                }
            } else {
                modelContext.insert(
                    LibrarySyncCursor(
                        providerId: providerId,
                        libraryId: libraryId,
                        lastSyncedAt: lastSyncedAt,
                        lastFullReconciledAt: lastFullReconciledAt ?? .distantPast
                    )
                )
            }
            try modelContext.save()
        }

        func updateProgress(uniqueId uid: String, currentTime: TimeInterval, isFinished: Bool, lastUpdate: Date) throws {
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { $0.uniqueId == uid }
            )
            descriptor.fetchLimit = 1
            guard let record = try modelContext.fetch(descriptor).first else { return }
            guard lastUpdate >= record.lastUpdate else { return }
            record.currentTime = currentTime
            record.isFinished = isFinished
            record.lastUpdate = lastUpdate
            record.refreshSortKeys()
            try modelContext.save()
        }

        func applyAuthoritativeProgress(_ updates: [AuthoritativeProgressUpdate]) throws {
            guard !updates.isEmpty else { return }
            let uniqueIds = Set(updates.map(\.bookUniqueId))

            let bookDescriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { uniqueIds.contains($0.uniqueId) }
            )
            var booksByUniqueId: [String: BookRecord] = [:]
            for record in try modelContext.fetch(bookDescriptor) {
                booksByUniqueId[record.uniqueId] = record
            }

            let progressDescriptor = FetchDescriptor<MediaProgressRecord>(
                predicate: #Predicate { uniqueIds.contains($0.bookUniqueId) }
            )
            var progressByUniqueId: [String: MediaProgressRecord] = [:]
            for record in try modelContext.fetch(progressDescriptor) {
                progressByUniqueId[record.bookUniqueId] = record
            }

            for update in updates {
                if let book = booksByUniqueId[update.bookUniqueId] {
                    book.currentTime = update.currentTime
                    book.ebookProgress = update.ebookProgress
                    book.epubLocator = update.epubLocator
                    book.isFinished = update.isFinished
                    book.lastUpdate = update.lastUpdate
                    book.hideFromContinue = update.hideFromContinue
                    book.serverReadStatus = update.serverReadStatus
                    book.refreshSortKeys()
                }

                if let progress = progressByUniqueId[update.bookUniqueId] {
                    progress.stableId = update.stableId
                    progress.currentTime = update.currentTime
                    progress.duration = update.duration
                    progress.ebookProgress = update.ebookProgress
                    progress.epubLocator = update.epubLocator
                    progress.isFinished = update.isFinished
                    progress.lastUpdate = update.lastUpdate
                    progress.hideFromContinue = update.hideFromContinue
                } else {
                    let progress = MediaProgressRecord(
                        bookUniqueId: update.bookUniqueId,
                        stableId: update.stableId,
                        currentTime: update.currentTime,
                        duration: update.duration,
                        ebookProgress: update.ebookProgress,
                        epubLocator: update.epubLocator,
                        isFinished: update.isFinished,
                        lastUpdate: update.lastUpdate,
                        hideFromContinue: update.hideFromContinue
                    )
                    modelContext.insert(progress)
                    progressByUniqueId[update.bookUniqueId] = progress
                }
            }

            try modelContext.save()
        }

        func updateEbookProgress(
            uniqueId uid: String,
            ebookProgress: Double?,
            epubLocator: String?,
            isFinished: Bool,
            lastUpdate: Date
        ) throws {
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { $0.uniqueId == uid }
            )
            descriptor.fetchLimit = 1
            guard let record = try modelContext.fetch(descriptor).first else { return }
            guard lastUpdate >= record.lastUpdate else { return }
            record.ebookProgress = ebookProgress
            record.epubLocator = epubLocator
            record.isFinished = isFinished
            record.lastUpdate = lastUpdate
            record.refreshSortKeys()
            try modelContext.save()
        }

        func updateEbookFileURL(uniqueId uid: String, path: String?) throws {
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { $0.uniqueId == uid }
            )
            descriptor.fetchLimit = 1
            guard let record = try modelContext.fetch(descriptor).first else { return }
            record.ebookFileURLPath = path
            try modelContext.save()
        }

        func setHidden(_ hidden: Bool, stableId sid: String) throws {
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { $0.stableId == sid }
            )
            descriptor.fetchLimit = 1
            guard let record = try modelContext.fetch(descriptor).first else { return }
            record.isHidden = hidden
            try modelContext.save()
        }

        func setDeleted(_ deleted: Bool, stableId sid: String) throws {
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { $0.stableId == sid }
            )
            descriptor.fetchLimit = 1
            guard let record = try modelContext.fetch(descriptor).first else { return }
            record.isDeleted = deleted
            try modelContext.save()
        }

        func deleteBooks(uniqueIds: Set<String>) throws {
            guard !uniqueIds.isEmpty else { return }
            try modelContext.delete(model: BookRecord.self, where: #Predicate { uniqueIds.contains($0.uniqueId) })
        }

        func importLegacy(_ books: [Book], hiddenStableIds: Set<String>, deletedStableIds: Set<String>) throws {
            let batchSize = 500
            for batchStart in stride(from: 0, to: books.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, books.count)
                let batch = books[batchStart..<batchEnd]
                for book in batch {
                    let uid = book.uniqueId
                    var descriptor = FetchDescriptor<BookRecord>(
                        predicate: #Predicate { $0.uniqueId == uid }
                    )
                    descriptor.fetchLimit = 1

                    if let existing = try modelContext.fetch(descriptor).first {
                        existing.update(from: book)
                        existing.isHidden = hiddenStableIds.contains(book.stableId)
                        existing.isDeleted = deletedStableIds.contains(book.stableId)
                    } else {
                        let record = BookRecord(from: book)
                        record.isHidden = hiddenStableIds.contains(book.stableId)
                        record.isDeleted = deletedStableIds.contains(book.stableId)
                        modelContext.insert(record)
                    }
                }
                try modelContext.save()
            }
        }

        func count() throws -> Int {
            let descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { !$0.isDeleted }
            )
            return try modelContext.fetchCount(descriptor)
        }

        func count(libraryId: String, providerId: String) throws -> Int {
            let descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.libraryId == libraryId && $0.providerId == providerId && !$0.isDeleted && !$0.isHidden
                }
            )
            return try modelContext.fetchCount(descriptor)
        }

        func count(providerId: String, mediaType: String?) throws -> Int {
            let descriptor: FetchDescriptor<BookRecord>
            if let mt = mediaType {
                descriptor = FetchDescriptor<BookRecord>(
                    predicate: #Predicate {
                        $0.providerId == providerId && $0.mediaType == mt && !$0.isDeleted && !$0.isHidden
                    }
                )
            } else {
                descriptor = FetchDescriptor<BookRecord>(
                    predicate: #Predicate {
                        $0.providerId == providerId && !$0.isDeleted && !$0.isHidden
                    }
                )
            }
            return try modelContext.fetchCount(descriptor)
        }

        func hasAny() throws -> Bool {
            var descriptor = FetchDescriptor<BookRecord>()
            descriptor.fetchLimit = 1
            return try !modelContext.fetch(descriptor).isEmpty
        }

        func clearAllData() throws {
            try modelContext.delete(model: BookRecord.self)
            try modelContext.delete(model: MediaProgressRecord.self)
            try modelContext.delete(model: LinkedBookPairRecord.self)
            try modelContext.delete(model: BookmarkRecord.self)
            try modelContext.delete(model: AnnotationRecord.self)
            try modelContext.delete(model: ChapterCacheRecord.self)
        }

        func upsertProgressRecord(
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
        ) throws {
            let uid = bookUniqueId
            var descriptor = FetchDescriptor<MediaProgressRecord>(
                predicate: #Predicate { $0.bookUniqueId == uid }
            )
            descriptor.fetchLimit = 1
            if let existing = try modelContext.fetch(descriptor).first {
                guard lastUpdate >= existing.lastUpdate else { return }
                existing.stableId = stableId
                existing.currentTime = currentTime
                existing.duration = duration
                if preserveEbookPosition {
                    if let ebookProgress {
                        existing.ebookProgress = ebookProgress
                    }
                    if let epubLocator {
                        existing.epubLocator = epubLocator
                    }
                } else {
                    existing.ebookProgress = ebookProgress
                    existing.epubLocator = epubLocator
                }
                existing.isFinished = isFinished
                existing.lastUpdate = lastUpdate
                existing.hideFromContinue = hideFromContinue
            } else {
                modelContext.insert(
                    MediaProgressRecord(
                        bookUniqueId: bookUniqueId,
                        stableId: stableId,
                        currentTime: currentTime,
                        duration: duration,
                        ebookProgress: ebookProgress,
                        epubLocator: epubLocator,
                        isFinished: isFinished,
                        lastUpdate: lastUpdate,
                        hideFromContinue: hideFromContinue
                    )
                )
            }
            try modelContext.save()
        }

        func fetchProgress(forBookUniqueId uid: String) throws -> BookProgressSnapshot? {
            var descriptor = FetchDescriptor<MediaProgressRecord>(
                predicate: #Predicate { $0.bookUniqueId == uid }
            )
            descriptor.fetchLimit = 1
            guard let record = try modelContext.fetch(descriptor).first else { return nil }
            return BookProgressSnapshot(
                bookUniqueId: record.bookUniqueId,
                stableId: record.stableId,
                currentTime: record.currentTime,
                duration: record.duration,
                ebookProgress: record.ebookProgress,
                epubLocator: record.epubLocator,
                isFinished: record.isFinished,
                lastUpdate: record.lastUpdate,
                hideFromContinue: record.hideFromContinue
            )
        }

        func importProgressEntries(
            _ entries: [(
                bookUniqueId: String, stableId: String, currentTime: TimeInterval,
                duration: TimeInterval, isFinished: Bool, lastUpdate: Date
            )]
        ) throws {
            for entry in entries {
                let uid = entry.bookUniqueId
                var descriptor = FetchDescriptor<MediaProgressRecord>(
                    predicate: #Predicate { $0.bookUniqueId == uid }
                )
                descriptor.fetchLimit = 1
                if try modelContext.fetch(descriptor).first == nil {
                    modelContext.insert(
                        MediaProgressRecord(
                            bookUniqueId: entry.bookUniqueId,
                            stableId: entry.stableId,
                            currentTime: entry.currentTime,
                            duration: entry.duration,
                            ebookProgress: nil,
                            epubLocator: nil,
                            isFinished: entry.isFinished,
                            lastUpdate: entry.lastUpdate,
                            hideFromContinue: false
                        )
                    )
                }
            }
            try modelContext.save()
        }

        func upsertLinkRecord(ebookStableId: String, audiobookStableId: String, chapterOffset: Int) throws {
            let eid = ebookStableId
            var descriptor = FetchDescriptor<LinkedBookPairRecord>(
                predicate: #Predicate { $0.ebookStableId == eid }
            )
            descriptor.fetchLimit = 1
            if let existing = try modelContext.fetch(descriptor).first {
                existing.audiobookStableId = audiobookStableId
                existing.chapterOffset = chapterOffset
                existing.lastUpdate = Date()
            } else {
                modelContext.insert(
                    LinkedBookPairRecord(
                        ebookStableId: ebookStableId,
                        audiobookStableId: audiobookStableId,
                        chapterOffset: chapterOffset
                    )
                )
            }
            try modelContext.save()
        }

        func removeLinkRecord(ebookStableId eid: String) throws {
            let descriptor = FetchDescriptor<LinkedBookPairRecord>(
                predicate: #Predicate { $0.ebookStableId == eid }
            )
            for record in try modelContext.fetch(descriptor) {
                modelContext.delete(record)
            }
            try modelContext.save()
        }

        func fetchLinkedAudiobookStableId(forEbookStableId eid: String) throws -> String? {
            var descriptor = FetchDescriptor<LinkedBookPairRecord>(
                predicate: #Predicate { $0.ebookStableId == eid }
            )
            descriptor.fetchLimit = 1
            return try modelContext.fetch(descriptor).first?.audiobookStableId
        }

        func fetchLinkedEbookStableId(forAudiobookStableId aid: String) throws -> String? {
            var descriptor = FetchDescriptor<LinkedBookPairRecord>(
                predicate: #Predicate { $0.audiobookStableId == aid }
            )
            descriptor.fetchLimit = 1
            return try modelContext.fetch(descriptor).first?.ebookStableId
        }

        func fetchAllLinks() throws -> [(ebookStableId: String, audiobookStableId: String, chapterOffset: Int)] {
            let descriptor = FetchDescriptor<LinkedBookPairRecord>()
            return try modelContext.fetch(descriptor).map {
                (ebookStableId: $0.ebookStableId, audiobookStableId: $0.audiobookStableId, chapterOffset: $0.chapterOffset)
            }
        }

        func importLinks(_ links: [(ebookStableId: String, audiobookStableId: String, chapterOffset: Int)]) throws {
            for link in links {
                let eid = link.ebookStableId
                var descriptor = FetchDescriptor<LinkedBookPairRecord>(
                    predicate: #Predicate { $0.ebookStableId == eid }
                )
                descriptor.fetchLimit = 1
                if try modelContext.fetch(descriptor).first == nil {
                    modelContext.insert(
                        LinkedBookPairRecord(
                            ebookStableId: link.ebookStableId,
                            audiobookStableId: link.audiobookStableId,
                            chapterOffset: link.chapterOffset
                        )
                    )
                }
            }
            try modelContext.save()
        }

        func fetchBookmarkedBookStableIds() throws -> Set<String> {

            var descriptor = FetchDescriptor<BookmarkRecord>()
            descriptor.propertiesToFetch = [\BookmarkRecord.bookStableId]
            let rows = try modelContext.fetch(descriptor)
            return Set(rows.map { $0.bookStableId })
        }

        func fetchBookmarks(forBookStableId sid: String) throws -> [BookmarkSnapshot] {
            let descriptor = FetchDescriptor<BookmarkRecord>(
                predicate: #Predicate { $0.bookStableId == sid },
                sortBy: [SortDescriptor(\.position)]
            )
            return try modelContext.fetch(descriptor).map {
                BookmarkSnapshot(
                    id: $0.id,
                    bookStableId: $0.bookStableId,
                    title: $0.title,
                    position: $0.position,
                    timestamp: $0.timestamp,
                    note: $0.note,
                    locator: $0.locator,
                    mediaType: $0.mediaType,
                    chapterTitle: $0.chapterTitle,
                    remoteID: $0.remoteID,
                    isRemotePlaceholder: $0.isRemotePlaceholder
                )
            }
        }

        func upsertBookmarkRecord(
            id: String,
            bookStableId: String,
            title: String,
            position: Double,
            timestamp: Date,
            note: String?,
            locator: String?,
            mediaType: String,
            chapterTitle: String?,
            remoteID: Int?,
            isRemotePlaceholder: Bool
        ) throws {
            let bid = id
            var descriptor = FetchDescriptor<BookmarkRecord>(
                predicate: #Predicate { $0.id == bid }
            )
            descriptor.fetchLimit = 1
            if let existing = try modelContext.fetch(descriptor).first {
                existing.title = title
                existing.position = position
                existing.note = note
                existing.locator = locator
                existing.chapterTitle = chapterTitle
                existing.remoteID = remoteID
                existing.isRemotePlaceholder = isRemotePlaceholder
            } else {
                modelContext.insert(
                    BookmarkRecord(
                        id: id,
                        bookStableId: bookStableId,
                        title: title,
                        position: position,
                        timestamp: timestamp,
                        note: note,
                        locator: locator,
                        mediaType: mediaType,
                        chapterTitle: chapterTitle,
                        remoteID: remoteID,
                        isRemotePlaceholder: isRemotePlaceholder
                    )
                )
            }
            try modelContext.save()
        }

        func deleteBookmarkRecord(id bid: String) throws {
            var descriptor = FetchDescriptor<BookmarkRecord>(
                predicate: #Predicate { $0.id == bid }
            )
            descriptor.fetchLimit = 1
            if let record = try modelContext.fetch(descriptor).first {
                modelContext.delete(record)
            }
            try modelContext.save()
        }

        func replaceBookmarkRecords(
            forBookStableId sid: String,
            bookmarks: [(
                id: String, title: String, position: Double,
                timestamp: Date, note: String?, locator: String?,
                mediaType: String, chapterTitle: String?,
                remoteID: Int?, isRemotePlaceholder: Bool
            )]
        ) throws {
            let existing = FetchDescriptor<BookmarkRecord>(
                predicate: #Predicate { $0.bookStableId == sid }
            )
            for record in try modelContext.fetch(existing) {
                modelContext.delete(record)
            }
            for b in bookmarks {
                modelContext.insert(
                    BookmarkRecord(
                        id: b.id,
                        bookStableId: sid,
                        title: b.title,
                        position: b.position,
                        timestamp: b.timestamp,
                        note: b.note,
                        locator: b.locator,
                        mediaType: b.mediaType,
                        chapterTitle: b.chapterTitle,
                        remoteID: b.remoteID,
                        isRemotePlaceholder: b.isRemotePlaceholder
                    )
                )
            }
            try modelContext.save()
        }

        func importBookmarkRecords(
            _ bookmarks: [(
                id: String, title: String, position: Double,
                timestamp: Date, note: String?, locator: String?,
                mediaType: String, chapterTitle: String?,
                remoteID: Int?, isRemotePlaceholder: Bool
            )],
            bookStableId: String
        ) throws {
            let existingDescriptor = FetchDescriptor<BookmarkRecord>(
                predicate: #Predicate { $0.bookStableId == bookStableId }
            )
            let existingIds = Set(try modelContext.fetch(existingDescriptor).map { $0.id })
            for b in bookmarks where !existingIds.contains(b.id) {
                modelContext.insert(
                    BookmarkRecord(
                        id: b.id,
                        bookStableId: bookStableId,
                        title: b.title,
                        position: b.position,
                        timestamp: b.timestamp,
                        note: b.note,
                        locator: b.locator,
                        mediaType: b.mediaType,
                        chapterTitle: b.chapterTitle,
                        remoteID: b.remoteID,
                        isRemotePlaceholder: b.isRemotePlaceholder
                    )
                )
            }
            try modelContext.save()
        }

        func fetchAnnotations(forBookStableId sid: String) throws -> [AnnotationSnapshot] {
            let descriptor = FetchDescriptor<AnnotationRecord>(
                predicate: #Predicate { $0.bookStableId == sid },
                sortBy: [SortDescriptor(\.position)]
            )
            return try modelContext.fetch(descriptor).map {
                AnnotationSnapshot(
                    id: $0.id,
                    bookStableId: $0.bookStableId,
                    locator: $0.locator,
                    position: $0.position,
                    text: $0.text,
                    note: $0.note,
                    colorHex: $0.colorHex,
                    style: $0.style,
                    chapterTitle: $0.chapterTitle,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt,
                    remoteID: $0.remoteID,
                    isRemotePlaceholder: $0.isRemotePlaceholder
                )
            }
        }

        func upsertAnnotationRecord(
            id: String,
            bookStableId: String,
            locator: String?,
            position: Double,
            text: String,
            note: String?,
            colorHex: String,
            style: String,
            chapterTitle: String?,
            createdAt: Date,
            updatedAt: Date,
            remoteID: Int?,
            isRemotePlaceholder: Bool
        ) throws {
            let aid = id
            var descriptor = FetchDescriptor<AnnotationRecord>(
                predicate: #Predicate { $0.id == aid }
            )
            descriptor.fetchLimit = 1
            if let existing = try modelContext.fetch(descriptor).first {
                existing.locator = locator
                existing.position = position
                existing.text = text
                existing.note = note
                existing.colorHex = colorHex
                existing.style = style
                existing.chapterTitle = chapterTitle
                existing.updatedAt = updatedAt
                existing.remoteID = remoteID
                existing.isRemotePlaceholder = isRemotePlaceholder
            } else {
                modelContext.insert(
                    AnnotationRecord(
                        id: id,
                        bookStableId: bookStableId,
                        locator: locator,
                        position: position,
                        text: text,
                        note: note,
                        colorHex: colorHex,
                        style: style,
                        chapterTitle: chapterTitle,
                        createdAt: createdAt,
                        updatedAt: updatedAt,
                        remoteID: remoteID,
                        isRemotePlaceholder: isRemotePlaceholder
                    )
                )
            }
            try modelContext.save()
        }

        func deleteAnnotationRecord(id aid: String) throws {
            var descriptor = FetchDescriptor<AnnotationRecord>(
                predicate: #Predicate { $0.id == aid }
            )
            descriptor.fetchLimit = 1
            if let record = try modelContext.fetch(descriptor).first {
                modelContext.delete(record)
            }
            try modelContext.save()
        }

        func replaceAnnotationRecords(
            forBookStableId sid: String,
            annotations: [(
                id: String, locator: String?, position: Double,
                text: String, note: String?, colorHex: String,
                style: String, chapterTitle: String?,
                createdAt: Date, updatedAt: Date,
                remoteID: Int?, isRemotePlaceholder: Bool
            )]
        ) throws {
            let existing = FetchDescriptor<AnnotationRecord>(
                predicate: #Predicate { $0.bookStableId == sid }
            )
            for record in try modelContext.fetch(existing) {
                modelContext.delete(record)
            }
            for a in annotations {
                modelContext.insert(
                    AnnotationRecord(
                        id: a.id,
                        bookStableId: sid,
                        locator: a.locator,
                        position: a.position,
                        text: a.text,
                        note: a.note,
                        colorHex: a.colorHex,
                        style: a.style,
                        chapterTitle: a.chapterTitle,
                        createdAt: a.createdAt,
                        updatedAt: a.updatedAt,
                        remoteID: a.remoteID,
                        isRemotePlaceholder: a.isRemotePlaceholder
                    )
                )
            }
            try modelContext.save()
        }

        func importAnnotationRecords(
            _ annotations: [(
                id: String, locator: String?, position: Double,
                text: String, note: String?, colorHex: String,
                style: String, chapterTitle: String?,
                createdAt: Date, updatedAt: Date,
                remoteID: Int?, isRemotePlaceholder: Bool
            )],
            bookStableId: String
        ) throws {
            let existingDescriptor = FetchDescriptor<AnnotationRecord>(
                predicate: #Predicate { $0.bookStableId == bookStableId }
            )
            let existingIds = Set(try modelContext.fetch(existingDescriptor).map { $0.id })
            for a in annotations where !existingIds.contains(a.id) {
                modelContext.insert(
                    AnnotationRecord(
                        id: a.id,
                        bookStableId: bookStableId,
                        locator: a.locator,
                        position: a.position,
                        text: a.text,
                        note: a.note,
                        colorHex: a.colorHex,
                        style: a.style,
                        chapterTitle: a.chapterTitle,
                        createdAt: a.createdAt,
                        updatedAt: a.updatedAt,
                        remoteID: a.remoteID,
                        isRemotePlaceholder: a.isRemotePlaceholder
                    )
                )
            }
            try modelContext.save()
        }

        func fetchVocabEntries(forBookStableId sid: String) throws -> [VocabEntrySnapshot] {
            let descriptor = FetchDescriptor<VocabEntryRecord>(
                predicate: #Predicate { $0.bookStableId == sid },
                sortBy: [SortDescriptor(\.lookedUpAt, order: .reverse)]
            )
            return try modelContext.fetch(descriptor).map { snap($0) }
        }

        func fetchAllVocabEntries() throws -> [VocabEntrySnapshot] {
            let descriptor = FetchDescriptor<VocabEntryRecord>(
                sortBy: [SortDescriptor(\.lookedUpAt, order: .reverse)]
            )
            return try modelContext.fetch(descriptor).map { snap($0) }
        }

        private func snap(_ r: VocabEntryRecord) -> VocabEntrySnapshot {
            VocabEntrySnapshot(
                id: r.id,
                bookStableId: r.bookStableId,
                word: r.word,
                sentence: r.sentence,
                sentenceBefore: r.sentenceBefore,
                sentenceAfter: r.sentenceAfter,
                locator: r.locator,
                position: r.position,
                chapterTitle: r.chapterTitle,
                definitionSnapshot: r.definitionSnapshot,
                userNote: r.userNote,
                lookedUpAt: r.lookedUpAt,
                tags: r.tags,
                sourceLanguage: r.sourceLanguage,
                studyBox: r.studyBox,
                nextReviewAt: r.nextReviewAt,
                lastReviewedAt: r.lastReviewedAt,
                reviewStreak: r.reviewStreak
            )
        }

        func upsertVocabEntryRecord(
            id: String,
            bookStableId: String,
            word: String,
            sentence: String,
            sentenceBefore: String,
            sentenceAfter: String,
            locator: String?,
            position: Double,
            chapterTitle: String?,
            definitionSnapshot: String?,
            userNote: String?,
            lookedUpAt: Date,
            tags: String,
            sourceLanguage: String?,
            studyBox: Int,
            nextReviewAt: Date?,
            lastReviewedAt: Date?,
            reviewStreak: Int
        ) throws {
            let vid = id
            var descriptor = FetchDescriptor<VocabEntryRecord>(
                predicate: #Predicate { $0.id == vid }
            )
            descriptor.fetchLimit = 1
            if let existing = try modelContext.fetch(descriptor).first {
                existing.word = word
                existing.sentence = sentence
                existing.sentenceBefore = sentenceBefore
                existing.sentenceAfter = sentenceAfter
                existing.locator = locator
                existing.position = position
                existing.chapterTitle = chapterTitle
                existing.definitionSnapshot = definitionSnapshot
                existing.userNote = userNote
                existing.tags = tags
                existing.sourceLanguage = sourceLanguage
                existing.studyBox = studyBox
                existing.nextReviewAt = nextReviewAt
                existing.lastReviewedAt = lastReviewedAt
                existing.reviewStreak = reviewStreak
            } else {
                modelContext.insert(
                    VocabEntryRecord(
                        id: id,
                        bookStableId: bookStableId,
                        word: word,
                        sentence: sentence,
                        sentenceBefore: sentenceBefore,
                        sentenceAfter: sentenceAfter,
                        locator: locator,
                        position: position,
                        chapterTitle: chapterTitle,
                        definitionSnapshot: definitionSnapshot,
                        userNote: userNote,
                        lookedUpAt: lookedUpAt,
                        tags: tags,
                        sourceLanguage: sourceLanguage,
                        studyBox: studyBox,
                        nextReviewAt: nextReviewAt,
                        lastReviewedAt: lastReviewedAt,
                        reviewStreak: reviewStreak
                    )
                )
            }
            try modelContext.save()
        }

        func deleteVocabEntryRecord(id vid: String) throws {
            var descriptor = FetchDescriptor<VocabEntryRecord>(
                predicate: #Predicate { $0.id == vid }
            )
            descriptor.fetchLimit = 1
            if let record = try modelContext.fetch(descriptor).first {
                modelContext.delete(record)
            }
            try modelContext.save()
        }

        func fetchCachedChapters(forBookStableId sid: String) throws -> [Chapter]? {
            var descriptor = FetchDescriptor<ChapterCacheRecord>(
                predicate: #Predicate { $0.bookStableId == sid }
            )
            descriptor.fetchLimit = 1
            return try modelContext.fetch(descriptor).first?.toChapters()
        }

        func cacheChapterRecords(_ chapters: [Chapter], forBookStableId sid: String) throws {
            var descriptor = FetchDescriptor<ChapterCacheRecord>(
                predicate: #Predicate { $0.bookStableId == sid }
            )
            descriptor.fetchLimit = 1
            if let existing = try modelContext.fetch(descriptor).first {
                existing.chaptersJSON = (try? JSONEncoder().encode(chapters)) ?? Data()
                existing.lastUpdate = Date()
            } else {
                modelContext.insert(ChapterCacheRecord(bookStableId: sid, chapters: chapters))
            }
            try modelContext.save()
        }
    }

    private func makeWorker() -> Worker {
        Worker(modelContainer: container)
    }

    func allBooks() async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchAllBooks()
        } catch {
            AppLogger.general.error("BookStore.allBooks failed: \(error)")
            return []
        }
    }

    func browseSlices(source: String) async -> [BookBrowseSlice] {
        let worker = makeWorker()
        do {
            return try await worker.fetchBrowseSlices(source: source)
        } catch {
            AppLogger.general.error("BookStore.browseSlices(source:) failed: \(error)")
            return []
        }
    }

    func browseSlices(mediaType: String) async -> [BookBrowseSlice] {
        let worker = makeWorker()
        do {
            return try await worker.fetchBrowseSlices(mediaType: mediaType)
        } catch {
            AppLogger.general.error("BookStore.browseSlices(mediaType:) failed: \(error)")
            return []
        }
    }

    func browseAuthorAggregates(mediaType: String) async -> [BrowseAuthorAggregate] {
        let worker = makeWorker()
        do {
            return try await worker.fetchBrowseAuthorAggregates(mediaType: mediaType)
        } catch {
            AppLogger.general.error("BookStore.browseAuthorAggregates failed: \(error)")
            return []
        }
    }

    func browseNarratorAggregates(mediaType: String) async -> [BrowseNarratorAggregate] {
        let worker = makeWorker()
        do {
            return try await worker.fetchBrowseNarratorAggregates(mediaType: mediaType)
        } catch {
            AppLogger.general.error("BookStore.browseNarratorAggregates failed: \(error)")
            return []
        }
    }

    func browseSeriesAggregates(mediaType: String) async -> [BrowseSeriesAggregate] {
        let worker = makeWorker()
        do {
            return try await worker.fetchBrowseSeriesAggregates(mediaType: mediaType)
        } catch {
            AppLogger.general.error("BookStore.browseSeriesAggregates failed: \(error)")
            return []
        }
    }

    func books(byAuthor author: String, mediaType: String, limit: Int) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchBooksByAuthor(author: author, mediaType: mediaType, limit: limit)
        } catch {
            AppLogger.general.error("BookStore.books(byAuthor:) failed: \(error)")
            return []
        }
    }

    func books(byAuthorNames authorNames: [String], mediaType: String, limit: Int) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchBooksByAuthorNames(authorNames: authorNames, mediaType: mediaType, limit: limit)
        } catch {
            AppLogger.general.error("BookStore.books(byAuthorNames:) failed: \(error)")
            return []
        }
    }

    func books(byNarrator narrator: String, mediaType: String, limit: Int) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchBooksByNarrator(narrator: narrator, mediaType: mediaType, limit: limit)
        } catch {
            AppLogger.general.error("BookStore.books(byNarrator:) failed: \(error)")
            return []
        }
    }

    func books(bySeries series: String, mediaType: String, limit: Int) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchBooksBySeries(series: series, mediaType: mediaType, limit: limit)
        } catch {
            AppLogger.general.error("BookStore.books(bySeries:) failed: \(error)")
            return []
        }
    }

    func books(bySeriesNames seriesNames: [String], mediaType: String, limit: Int) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchBooksBySeriesNames(seriesNames: seriesNames, mediaType: mediaType, limit: limit)
        } catch {
            AppLogger.general.error("BookStore.books(bySeriesNames:) failed: \(error)")
            return []
        }
    }

    func books(workKey key: String) async -> [Book] {
        guard !key.isEmpty else { return [] }
        let worker = makeWorker()
        do {
            return try await worker.fetchBooksByWorkKey(key)
        } catch {
            AppLogger.general.error("BookStore.books(workKey:) failed: \(error)")
            return []
        }
    }

    func books(editionKey key: String) async -> [Book] {
        guard !key.isEmpty else { return [] }
        let worker = makeWorker()
        do {
            return try await worker.fetchBooksByEditionKey(key)
        } catch {
            AppLogger.general.error("BookStore.books(editionKey:) failed: \(error)")
            return []
        }
    }

    func booksWithIdentifiers(limit: Int) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchBooksWithIdentifiers(limit: limit)
        } catch {
            AppLogger.general.error("BookStore.booksWithIdentifiers failed: \(error)")
            return []
        }
    }

    func workSlices() async -> [WorkSlice] {
        let worker = makeWorker()
        do {
            return try await worker.fetchWorkSlices()
        } catch {
            AppLogger.general.error("BookStore.workSlices failed: \(error)")
            return []
        }
    }

    func activeBooks(excludingSource: String, minProgressThreshold: Double) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchActiveBooks(excludingSource: excludingSource, minProgress: minProgressThreshold)
        } catch {
            AppLogger.general.error("BookStore.activeBooks failed: \(error)")
            return []
        }
    }

    func books(inSeries seriesName: String) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchBooksInSeries(seriesName)
        } catch {
            AppLogger.general.error("BookStore.books(inSeries) failed: \(error)")
            return []
        }
    }

    func books(inSeriesNames seriesNames: [String]) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchBooksInSeriesNames(seriesNames)
        } catch {
            AppLogger.general.error("BookStore.books(inSeriesNames) failed: \(error)")
            return []
        }
    }

    func firstBooks(libraryId: String, providerId: UUID, limit: Int) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchFirstBooksForLibrary(libraryId: libraryId, providerId: providerId.uuidString, limit: limit)
        } catch {
            AppLogger.general.error("BookStore.books(library) failed: \(error)")
            return []
        }
    }

    func titleAuthorPairs() async -> [(title: String, author: String)] {
        let worker = makeWorker()
        do {
            return try await worker.fetchTitleAuthorPairs()
        } catch {
            AppLogger.general.error("BookStore.titleAuthorPairs failed: \(error)")
            return []
        }
    }

    func firstBooks(mediaType: String, limit: Int) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchFirstBooksByMediaType(mediaType: mediaType, limit: limit)
        } catch {
            AppLogger.general.error("BookStore.firstBooks(mediaType:) failed: \(error)")
            return []
        }
    }

    func bookCount(mediaType: String) async -> Int {
        let worker = makeWorker()
        do {
            return try await worker.fetchBookCountByMediaType(mediaType)
        } catch {
            AppLogger.general.error("BookStore.bookCount(mediaType:) failed: \(error)")
            return 0
        }
    }

    func firstBooks(source: String, mediaType: String, limit: Int) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchFirstBooksBySource(source: source, mediaType: mediaType, limit: limit)
        } catch {
            AppLogger.general.error("BookStore.firstBooks(source:mediaType:) failed: \(error)")
            return []
        }
    }

    func book(byBookId id: String) async -> Book? {
        let worker = makeWorker()
        do { return try await worker.fetchBook(byBookId: id) } catch {
            AppLogger.general.error("BookStore.book(byBookId:) failed: \(error)")
            return nil
        }
    }

    func book(byAnyId id: String) async -> Book? {
        if let b = await book(uniqueId: id) { return b }
        if let b = await book(stableId: id) { return b }
        return await book(byBookId: id)
    }

    func books(source: String, providerId: UUID) async -> [Book] {
        let worker = makeWorker()
        do { return try await worker.fetchBooks(source: source, providerIdString: providerId.uuidString) } catch {
            AppLogger.general.error("BookStore.books(source:providerId:) failed: \(error)")
            return []
        }
    }

    func books(source: String, providerId: UUID, mediaType: String) async -> [Book] {
        let worker = makeWorker()
        do { return try await worker.fetchBooks(source: source, providerIdString: providerId.uuidString, mediaType: mediaType) } catch {
            AppLogger.general.error("BookStore.books(source:providerId:mediaType:) failed: \(error)")
            return []
        }
    }

    func books(backendId: String, source: String?) async -> [Book] {
        let worker = makeWorker()
        do { return try await worker.fetchBooks(backendId: backendId, source: source) } catch {
            AppLogger.general.error("BookStore.books(backendId:source:) failed: \(error)")
            return []
        }
    }

    func firstBooksWithReadAloudSource(limit: Int) async -> [Book] {
        let worker = makeWorker()
        do { return try await worker.fetchFirstBooksWithReadAloudSource(limit: limit) } catch {
            AppLogger.general.error("BookStore.firstBooksWithReadAloudSource failed: \(error)")
            return []
        }
    }

    func firstBooksWithoutReadAloudSource(limit: Int) async -> [Book] {
        let worker = makeWorker()
        do { return try await worker.fetchFirstBooksWithoutReadAloudSource(limit: limit) } catch {
            AppLogger.general.error("BookStore.firstBooksWithoutReadAloudSource failed: \(error)")
            return []
        }
    }

    func bookCountWithReadAloudSource() async -> Int {
        let worker = makeWorker()
        do { return try await worker.fetchBookCountWithReadAloudSource() } catch {
            AppLogger.general.error("BookStore.bookCountWithReadAloudSource failed: \(error)")
            return 0
        }
    }

    func hasBook(stableId: String, requiresWithoutReadAloudSource: Bool) async -> Bool {
        let worker = makeWorker()
        do { return try await worker.hasBook(stableId: stableId, requireWithoutReadAloudSource: requiresWithoutReadAloudSource) } catch {
            AppLogger.general.error("BookStore.hasBook failed: \(error)")
            return false
        }
    }

    func bookPresence() async -> BookPresence {
        let worker = makeWorker()
        do { return try await worker.fetchBookPresence() } catch {
            AppLogger.general.error("BookStore.bookPresence failed: \(error)")
            return BookPresence(libraryKeys: [], smbBackendIds: [], hasReadAloud: false)
        }
    }

    func allBookUniqueIds() async -> Set<String> {
        let worker = makeWorker()
        do { return Set(try await worker.fetchAllBookUniqueIds()) } catch {
            AppLogger.general.error("BookStore.allBookUniqueIds failed: \(error)")
            return []
        }
    }

    func allBookIds() async -> Set<String> {
        let worker = makeWorker()
        do { return Set(try await worker.fetchAllBookIds()) } catch {
            AppLogger.general.error("BookStore.allBookIds failed: \(error)")
            return []
        }
    }

    func bookCountsBySource() async -> [(source: String, count: Int)] {
        let worker = makeWorker()
        do { return try await worker.fetchBookCountsBySource() } catch {
            AppLogger.general.error("BookStore.bookCountsBySource failed: \(error)")
            return []
        }
    }

    func bookCountsBySection(source: String) async -> [(libraryId: String, providerId: String, count: Int)] {
        let worker = makeWorker()
        do { return try await worker.fetchBookCountsBySection(source: source) } catch {
            AppLogger.general.error("BookStore.bookCountsBySection failed: \(error)")
            return []
        }
    }

    @discardableResult
    func deleteBooksFromUnknownProviders(validProviderIds: Set<String>) async -> Int {
        let worker = makeWorker()
        do {
            let removed = try await worker.deleteBooksFromUnknownProviders(validProviderIds: validProviderIds)
            if removed > 0 { BookStoreChangeNotifier.notify() }
            return removed
        } catch {
            AppLogger.general.error("BookStore.deleteBooksFromUnknownProviders failed: \(error)")
            return 0
        }
    }

    @discardableResult
    func deleteBooksFromInactiveLibraries(
        validProviderIds: Set<String>,
        restrictedLibraryIds: [String: Set<String>]
    ) async -> Int {
        let worker = makeWorker()
        do {
            let removed = try await worker.deleteBooksFromInactiveLibraries(
                validProviderIds: validProviderIds,
                restrictedLibraryIds: restrictedLibraryIds
            )
            if removed > 0 { BookStoreChangeNotifier.notify() }
            return removed
        } catch {
            AppLogger.general.error("BookStore.deleteBooksFromInactiveLibraries failed: \(error)")
            return 0
        }
    }

    func books(withIds ids: [String]) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchBooksWithIds(ids)
        } catch {
            AppLogger.general.error("BookStore.books(withIds:) failed: \(error)")
            return []
        }
    }

    func book(uniqueId: String) async -> Book? {
        let worker = makeWorker()
        do {
            return try await worker.fetchBookByUniqueId(uniqueId)
        } catch {
            AppLogger.general.error("BookStore.book(uniqueId) failed: \(error)")
            return nil
        }
    }

    func book(stableId: String) async -> Book? {
        let worker = makeWorker()
        do {
            return try await worker.fetchBookByStableId(stableId)
        } catch {
            AppLogger.general.error("BookStore.book(stableId) failed: \(error)")
            return nil
        }
    }

    func booksMatching(_ collection: SmartCollection, limit: Int? = nil) async -> [Book] {
        let worker = makeWorker()
        let candidates: [Book]
        do {
            candidates = try await worker.fetchSmartCandidates(rules: collection.rules, limit: limit)
        } catch {
            AppLogger.general.error("BookStore.booksMatching failed: \(error)")
            return []
        }
        let needsPostFilter = collection.rules.rules.contains { rule in
            switch rule.field {
            case .genre, .isDownloaded: return true
            default: return false
            }
        }
        guard needsPostFilter else { return candidates }
        let rules = collection.rules
        return await MainActor.run {
            candidates.filter { Self.evaluateRulesInSwift(rules, for: $0) }
        }
    }

    func bookCountMatching(_ collection: SmartCollection) async -> Int {
        let worker = makeWorker()
        do {
            if let count = try await worker.fetchSmartCountIfExpressible(rules: collection.rules) {
                return count
            }
        } catch {
            AppLogger.general.error("BookStore.bookCountMatching count-only path failed: \(error)")
            return 0
        }

        return await booksMatching(collection, limit: nil).count
    }

    @MainActor
    private static func evaluateRulesInSwift(_ ruleGroup: SmartCollectionRuleGroup, for book: Book) -> Bool {
        if ruleGroup.rules.isEmpty { return true }
        switch ruleGroup.logicOperator {
        case .and: return ruleGroup.rules.allSatisfy { evaluateRule($0, for: book) }
        case .or: return ruleGroup.rules.contains { evaluateRule($0, for: book) }
        }
    }

    @MainActor
    private static func evaluateRule(_ rule: SmartCollectionRule, for book: Book) -> Bool {
        switch rule.field {
        case .author: return matchesString(book.author ?? "", rule)
        case .narrator: return matchesString(book.narrator ?? "", rule)
        case .genre: return book.genres?.contains(where: { matchesString($0, rule) }) ?? false
        case .progress: return matchesNumeric(book.progress ?? 0, rule)
        case .isFinished: return (book.progress ?? 0) >= 1.0
        case .isAbandoned: return book.serverReadStatus == "ABANDONED"
        case .isDownloaded: return LocalStorageManager.shared.isAudiobookDownloaded(book.downloadKey)
        case .dateAdded: return matchesDate(book.dateAdded, rule)
        case .lastPlayed: return matchesDate(book.lastPlayed, rule)
        case .duration: return matchesNumeric(book.duration ?? 0, rule)
        case .releaseYear:
            guard let publishedYear = book.publishedYear else { return false }
            return matchesNumeric(Double(publishedYear), rule)
        }
    }

    nonisolated private static func matchesString(_ value: String, _ rule: SmartCollectionRule) -> Bool {
        switch rule.operator {
        case .equals: return value.lowercased() == rule.value.lowercased()
        case .notEquals: return value.lowercased() != rule.value.lowercased()
        case .contains: return value.lowercased().contains(rule.value.lowercased())
        default: return false
        }
    }

    nonisolated private static func matchesNumeric(_ value: Double, _ rule: SmartCollectionRule) -> Bool {
        guard let ruleValue = Double(rule.value) else { return false }
        switch rule.operator {
        case .equals: return abs(value - ruleValue) < 0.001
        case .notEquals: return abs(value - ruleValue) >= 0.001
        case .greaterThan: return value > ruleValue
        case .lessThan: return value < ruleValue
        default: return false
        }
    }

    nonisolated private static func matchesDate(_ date: Date?, _ rule: SmartCollectionRule) -> Bool {
        guard let date, let days = Int(rule.value) else { return false }
        let cutoff = Date().addingTimeInterval(TimeInterval(-days * 24 * 3600))
        switch rule.operator {
        case .greaterThan: return date > cutoff
        case .lessThan: return date < cutoff
        default: return false
        }
    }

    func existingAudiobookStableIds(from candidates: Set<String>) async -> Set<String> {
        let worker = makeWorker()
        do {
            return try await worker.fetchExistingAudiobookStableIds(from: candidates)
        } catch {
            AppLogger.general.error("BookStore.existingAudiobookStableIds failed: \(error)")
            return []
        }
    }

    func absorbedStableIds() async -> Set<String> {
        let worker = makeWorker()
        do {
            return try await worker.fetchAbsorbedStableIds()
        } catch {
            AppLogger.general.error("BookStore.absorbedStableIds failed: \(error)")
            return []
        }
    }

    func booksByIds(_ ids: Set<String>) async -> [String: Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchBooksByIds(ids: ids)
        } catch {
            AppLogger.general.error("BookStore.booksByIds failed: \(error)")
            return [:]
        }
    }

    func booksByUniqueIds(_ ids: Set<String>) async -> [String: Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchBooksByUniqueIds(ids: ids)
        } catch {
            AppLogger.general.error("BookStore.booksByUniqueIds failed: \(error)")
            return [:]
        }
    }

    func booksByAnyIds(_ ids: Set<String>) async -> [String: Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchBooksByAnyIds(ids: ids)
        } catch {
            AppLogger.general.error("BookStore.booksByAnyIds failed: \(error)")
            return [:]
        }
    }

    func booksByStableIds(_ ids: Set<String>) async -> [String: Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchBooksByStableIds(ids: ids)
        } catch {
            AppLogger.general.error("BookStore.booksByStableIds failed: \(error)")
            return [:]
        }
    }

    func booksWithProgress(providerId: UUID) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchBooksWithProgress(
                providerId: providerId.uuidString
            )
        } catch {
            AppLogger.general.error("BookStore.booksWithProgress failed: \(error)")
            return []
        }
    }

    func continueListeningBooks(limit: Int) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchContinueListening(limit: limit)
        } catch {
            AppLogger.general.error("BookStore.continueListening failed: \(error)")
            return []
        }
    }

    func continueReadingBooks(limit: Int) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchContinueReading(limit: limit)
        } catch {
            AppLogger.general.error("BookStore.continueReading failed: \(error)")
            return []
        }
    }

    func recentBooks(limit: Int) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchRecent(mediaType: "audiobook", limit: limit)
        } catch {
            AppLogger.general.error("BookStore.recentBooks failed: \(error)")
            return []
        }
    }

    func recentEbooks(limit: Int) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchRecent(mediaType: "ebook", limit: limit)
        } catch {
            AppLogger.general.error("BookStore.recentEbooks failed: \(error)")
            return []
        }
    }

    func downloadedEbooks(limit: Int) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchDownloadedEbooks(limit: limit)
        } catch {
            AppLogger.general.error("BookStore.downloadedEbooks failed: \(error)")
            return []
        }
    }

    func pagedBooks(offset: Int, limit: Int, mediaType: String?) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchPaged(offset: offset, limit: limit, mediaType: mediaType)
        } catch {
            AppLogger.general.error("BookStore.pagedBooks failed: \(error)")
            return []
        }
    }

    func booksAfterUniqueId(_ cursor: String?, limit: Int) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchAfterUniqueId(cursor, limit: limit)
        } catch {
            AppLogger.general.error("BookStore.booksAfterUniqueId failed: \(error)")
            return []
        }
    }

    func pagedBooks(after cursor: Book?, limit: Int, mediaType: String?) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchPagedAfter(book: cursor, limit: limit, mediaType: mediaType)
        } catch {
            AppLogger.general.error("BookStore.pagedBooks(after:) failed: \(error)")
            return []
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
        let worker = makeWorker()
        do {
            return try await worker.searchBooks(query: query, limit: limit)
        } catch {
            AppLogger.general.error("BookStore.searchBooks failed: \(error)")
            return []
        }
    }

    func searchBooks(query: String, mediaType: String, limit: Int) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.searchBooks(query: query, mediaType: mediaType, limit: limit)
        } catch {
            AppLogger.general.error("BookStore.searchBooks(mediaType:) failed: \(error)")
            return []
        }
    }

    func searchBooks(query: String, libraryId: String?, providerId: UUID?, limit: Int) async -> [Book] {
        let worker = makeWorker()
        do {
            return try await worker.searchBooks(query: query, libraryId: libraryId, providerId: providerId?.uuidString, limit: limit)
        } catch {
            AppLogger.general.error("BookStore.searchBooks(scoped) failed: \(error)")
            return []
        }
    }

    func upsertBooks(_ books: [Book]) async {
        let valid = books.filter { !$0.uniqueId.isEmpty && !$0.stableId.isEmpty }
        if valid.count != books.count {
            AppLogger.general.error("BookStore.upsertBooks: rejected \(books.count - valid.count) book(s) with empty identity")
        }
        guard !valid.isEmpty else { return }
        let batchSize = 500
        var anyWritten = false
        for batchStart in stride(from: 0, to: valid.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, valid.count)
            let batch = Array(valid[batchStart..<batchEnd])
            let worker = makeWorker()
            do {
                try await worker.upsert(batch)
                anyWritten = true
            } catch {
                AppLogger.general.error("BookStore.upsert batch failed: \(error)")
            }
        }
        if anyWritten { BookStoreChangeNotifier.notify() }
    }

    func replaceLibrary(books: [Book], libraryId: String, providerId: UUID, allowSparseResult: Bool = false) async {
        guard !libraryId.isEmpty else {
            AppLogger.general.error("BookStore.replaceLibrary: rejecting empty libraryId")
            return
        }
        let valid = books.filter { !$0.uniqueId.isEmpty && !$0.stableId.isEmpty }
        if valid.count != books.count {
            AppLogger.general.error("BookStore.replaceLibrary: rejected \(books.count - valid.count) book(s) with empty identity")
        }
        let worker = makeWorker()
        do {
            try await worker.replaceLibrary(
                books: valid,
                libraryId: libraryId,
                providerId: providerId.uuidString,
                allowSparseResult: allowSparseResult
            )
            BookStoreChangeNotifier.notify()
        } catch {
            AppLogger.general.error("BookStore.replaceLibrary failed: \(error)")
        }
    }

    func beginReconciliation(libraryId: String, providerId: UUID) async -> ReconciliationStart {
        let worker = makeWorker()
        return await worker.beginReconciliation(libraryId: libraryId, providerId: providerId.uuidString)
    }

    func upsertReconciledPage(books: [Book], generation: Int, notifyChange: Bool) async throws {
        let valid = books.filter { !$0.uniqueId.isEmpty && !$0.stableId.isEmpty }
        if valid.count != books.count {
            throw BookStoreWriteError.invalidBookIdentity
        }
        guard !valid.isEmpty else { return }
        let worker = makeWorker()
        try await worker.upsertReconciledPage(books: valid, generation: generation)
        if notifyChange {
            BookStoreChangeNotifier.notify()
        }
    }

    func endReconciliation(
        libraryId: String,
        providerId: UUID,
        generation: Int,
        existingCountBefore: Int
    ) async throws -> ReconciliationOutcome {
        let worker = makeWorker()
        let outcome = try await worker.endReconciliation(
            libraryId: libraryId,
            providerId: providerId.uuidString,
            generation: generation,
            existingCountBefore: existingCountBefore
        )
        BookStoreChangeNotifier.notify()
        return outcome
    }

    func applyDelta(books: [Book], libraryId: String, providerId: UUID, cursor: Date) async {
        guard !libraryId.isEmpty else {
            AppLogger.general.error("BookStore.applyDelta: rejecting empty libraryId")
            return
        }
        let valid = books.filter { !$0.uniqueId.isEmpty && !$0.stableId.isEmpty }
        if valid.count != books.count {
            AppLogger.general.error("BookStore.applyDelta: rejected \(books.count - valid.count) book(s) with empty identity")
        }
        let worker = makeWorker()
        do {
            if !valid.isEmpty {
                try await worker.applyDelta(books: valid, libraryId: libraryId, providerId: providerId.uuidString)
            }
            try await worker.saveCursor(
                providerId: providerId.uuidString,
                libraryId: libraryId,
                lastSyncedAt: cursor,
                lastFullReconciledAt: nil
            )
            if !valid.isEmpty { BookStoreChangeNotifier.notify() }
        } catch {
            AppLogger.general.error("BookStore.applyDelta failed: \(error)")
        }
    }

    func loadCursor(providerId: UUID, libraryId: String) async -> LibrarySyncCursorSnapshot? {
        guard !libraryId.isEmpty else {
            AppLogger.general.error("BookStore.loadCursor: rejecting empty libraryId")
            return nil
        }
        let worker = makeWorker()
        do {
            return try await worker.loadCursor(providerId: providerId.uuidString, libraryId: libraryId)
        } catch {
            AppLogger.general.error("BookStore.loadCursor failed: \(error)")
            return nil
        }
    }

    func markFullReconciled(providerId: UUID, libraryId: String, at date: Date) async {
        guard !libraryId.isEmpty else {
            AppLogger.general.error("BookStore.markFullReconciled: rejecting empty libraryId")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.saveCursor(
                providerId: providerId.uuidString,
                libraryId: libraryId,
                lastSyncedAt: date,
                lastFullReconciledAt: date
            )
        } catch {
            AppLogger.general.error("BookStore.markFullReconciled failed: \(error)")
        }
    }

    func updateProgress(uniqueId: String, currentTime: TimeInterval, isFinished: Bool, lastUpdate: Date) async {
        guard !uniqueId.isEmpty else {
            AppLogger.general.error("BookStore.updateProgress: rejecting empty uniqueId")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.updateProgress(uniqueId: uniqueId, currentTime: currentTime, isFinished: isFinished, lastUpdate: lastUpdate)
            BookStoreChangeNotifier.notify()
        } catch {
            AppLogger.general.error("BookStore.updateProgress failed: \(error)")
        }
    }

    func applyAuthoritativeProgress(_ updates: [AuthoritativeProgressUpdate]) async {
        guard !updates.isEmpty else { return }
        let worker = makeWorker()
        do {
            try await worker.applyAuthoritativeProgress(updates)
            BookStoreChangeNotifier.notify()
        } catch {
            AppLogger.general.error("BookStore.applyAuthoritativeProgress failed: \(error)")
        }
    }

    func updateEbookProgress(uniqueId: String, ebookProgress: Double?, epubLocator: String?, isFinished: Bool, lastUpdate: Date) async {
        guard !uniqueId.isEmpty else {
            AppLogger.general.error("BookStore.updateEbookProgress: rejecting empty uniqueId")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.updateEbookProgress(
                uniqueId: uniqueId,
                ebookProgress: ebookProgress,
                epubLocator: epubLocator,
                isFinished: isFinished,
                lastUpdate: lastUpdate
            )
            BookStoreChangeNotifier.notify()
        } catch {
            AppLogger.general.error("BookStore.updateEbookProgress failed: \(error)")
        }
    }

    func updateEbookFileURL(uniqueId: String, url: URL?) async {
        guard !uniqueId.isEmpty else {
            AppLogger.general.error("BookStore.updateEbookFileURL: rejecting empty uniqueId")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.updateEbookFileURL(uniqueId: uniqueId, path: url?.path)
            BookStoreChangeNotifier.notify()
        } catch {
            AppLogger.general.error("BookStore.updateEbookFileURL failed: \(error)")
        }
    }

    func setHidden(_ hidden: Bool, stableId: String) async {
        guard !stableId.isEmpty else {
            AppLogger.general.error("BookStore.setHidden: rejecting empty stableId")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.setHidden(hidden, stableId: stableId)
            BookStoreChangeNotifier.notify()
        } catch {
            AppLogger.general.error("BookStore.setHidden failed: \(error)")
        }
    }

    func setDeleted(_ deleted: Bool, stableId: String) async {
        guard !stableId.isEmpty else {
            AppLogger.general.error("BookStore.setDeleted: rejecting empty stableId")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.setDeleted(deleted, stableId: stableId)
            BookStoreChangeNotifier.notify()
        } catch {
            AppLogger.general.error("BookStore.setDeleted failed: \(error)")
        }
    }

    func deleteBooks(uniqueIds: Set<String>) async {
        let valid = uniqueIds.filter { !$0.isEmpty }
        if valid.count != uniqueIds.count {
            AppLogger.general.error("BookStore.deleteBooks: filtered \(uniqueIds.count - valid.count) empty uniqueId(s)")
        }
        guard !valid.isEmpty else { return }
        let worker = makeWorker()
        do {
            try await worker.deleteBooks(uniqueIds: valid)
            BookStoreChangeNotifier.notify()
        } catch {
            AppLogger.general.error("BookStore.deleteBooks failed: \(error)")
        }
    }

    func importLegacyBooks(_ books: [Book], hiddenStableIds: Set<String>, deletedStableIds: Set<String>) async {
        let worker = makeWorker()
        do {
            try await worker.importLegacy(books, hiddenStableIds: hiddenStableIds, deletedStableIds: deletedStableIds)
            AppLogger.general.info("BookStore: imported \(books.count) legacy books")
        } catch {
            AppLogger.general.error("BookStore.importLegacy failed: \(error)")
        }
    }

    func bookCount() async -> Int {
        let worker = makeWorker()
        do {
            return try await worker.count()
        } catch {
            AppLogger.general.error("BookStore.count failed: \(error)")
            return 0
        }
    }

    func bookCount(libraryId: String, providerId: UUID) async -> Int {
        let worker = makeWorker()
        do {
            return try await worker.count(libraryId: libraryId, providerId: providerId.uuidString)
        } catch {
            AppLogger.general.error("BookStore.count(library) failed: \(error)")
            return 0
        }
    }

    func bookCount(providerId: UUID, mediaType: String?) async -> Int {
        let worker = makeWorker()
        do {
            return try await worker.count(providerId: providerId.uuidString, mediaType: mediaType)
        } catch {
            AppLogger.general.error("BookStore.count(provider) failed: \(error)")
            return 0
        }
    }

    func hasData() async -> Bool {
        let worker = makeWorker()
        do {
            return try await worker.hasAny()
        } catch {
            return false
        }
    }

    func clearAllData() async {
        let worker = makeWorker()
        do {
            try await worker.clearAllData()
        } catch {
            AppLogger.general.error("BookStore.clearAllData failed: \(error)")
        }
    }

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
    ) async {
        guard !bookUniqueId.isEmpty, !stableId.isEmpty else {
            AppLogger.general.error("BookStore.upsertProgress: rejecting empty bookUniqueId or stableId")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.upsertProgressRecord(
                bookUniqueId: bookUniqueId,
                stableId: stableId,
                currentTime: currentTime,
                duration: duration,
                ebookProgress: ebookProgress,
                epubLocator: epubLocator,
                isFinished: isFinished,
                lastUpdate: lastUpdate,
                hideFromContinue: hideFromContinue,
                preserveEbookPosition: preserveEbookPosition
            )
        } catch {
            AppLogger.general.error("BookStore.upsertProgress failed: \(error)")
        }
    }

    func progress(forBookUniqueId uid: String) async -> BookProgressSnapshot? {
        let worker = makeWorker()
        do {
            return try await worker.fetchProgress(forBookUniqueId: uid)
        } catch {
            AppLogger.general.error("BookStore.progress failed: \(error)")
            return nil
        }
    }

    func importLegacyProgress(
        _ entries: [(
            bookUniqueId: String, stableId: String, currentTime: TimeInterval,
            duration: TimeInterval, isFinished: Bool, lastUpdate: Date
        )]
    ) async {
        let worker = makeWorker()
        do {
            try await worker.importProgressEntries(entries)
            AppLogger.general.info("BookStore: imported \(entries.count) legacy progress entries")
        } catch {
            AppLogger.general.error("BookStore.importLegacyProgress failed: \(error)")
        }
    }

    func upsertLink(ebookStableId: String, audiobookStableId: String, chapterOffset: Int) async {
        guard !ebookStableId.isEmpty, !audiobookStableId.isEmpty else {
            AppLogger.general.error("BookStore.upsertLink: rejecting empty ebookStableId or audiobookStableId")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.upsertLinkRecord(
                ebookStableId: ebookStableId,
                audiobookStableId: audiobookStableId,
                chapterOffset: chapterOffset
            )
        } catch {
            AppLogger.general.error("BookStore.upsertLink failed: \(error)")
        }
    }

    func removeLink(ebookStableId: String) async {
        guard !ebookStableId.isEmpty else { return }
        let worker = makeWorker()
        do {
            try await worker.removeLinkRecord(ebookStableId: ebookStableId)
        } catch {
            AppLogger.general.error("BookStore.removeLink failed: \(error)")
        }
    }

    func linkedAudiobookStableId(forEbookStableId eid: String) async -> String? {
        let worker = makeWorker()
        do {
            return try await worker.fetchLinkedAudiobookStableId(forEbookStableId: eid)
        } catch {
            AppLogger.general.error("BookStore.linkedAudiobook failed: \(error)")
            return nil
        }
    }

    func linkedEbookStableId(forAudiobookStableId aid: String) async -> String? {
        let worker = makeWorker()
        do {
            return try await worker.fetchLinkedEbookStableId(forAudiobookStableId: aid)
        } catch {
            AppLogger.general.error("BookStore.linkedEbook failed: \(error)")
            return nil
        }
    }

    func allLinks() async -> [(ebookStableId: String, audiobookStableId: String, chapterOffset: Int)] {
        let worker = makeWorker()
        do {
            return try await worker.fetchAllLinks()
        } catch {
            AppLogger.general.error("BookStore.allLinks failed: \(error)")
            return []
        }
    }

    func importLegacyLinks(_ links: [(ebookStableId: String, audiobookStableId: String, chapterOffset: Int)]) async {
        let worker = makeWorker()
        do {
            try await worker.importLinks(links)
            AppLogger.general.info("BookStore: imported \(links.count) legacy links")
        } catch {
            AppLogger.general.error("BookStore.importLegacyLinks failed: \(error)")
        }
    }

    func bookmarkedBookStableIds() async -> Set<String> {
        let worker = makeWorker()
        do { return try await worker.fetchBookmarkedBookStableIds() } catch {
            AppLogger.general.error("BookStore.bookmarkedBookStableIds failed: \(error)")
            return []
        }
    }

    func bookmarks(forBookStableId sid: String) async -> [Bookmark] {
        let worker = makeWorker()
        do {
            let snapshots = try await worker.fetchBookmarks(forBookStableId: sid)
            return await MainActor.run {
                snapshots.map { s in
                    Bookmark(
                        id: s.id,
                        bookId: s.bookStableId,
                        position: s.position,
                        title: s.title,
                        note: s.note,
                        timestamp: s.timestamp,
                        locator: s.locator,
                        mediaType: AppMediaType(rawValue: s.mediaType) ?? .audiobook,
                        chapterTitle: s.chapterTitle,
                        remoteID: s.remoteID,
                        isRemotePlaceholder: s.isRemotePlaceholder
                    )
                }
            }
        } catch {
            AppLogger.general.error("BookStore.bookmarks failed: \(error)")
            return []
        }
    }

    func upsertBookmark(_ bookmark: Bookmark, bookStableId: String) async {
        guard !bookmark.id.isEmpty, !bookStableId.isEmpty else {
            AppLogger.general.error("BookStore.upsertBookmark: rejecting empty bookmark id or bookStableId")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.upsertBookmarkRecord(
                id: bookmark.id,
                bookStableId: bookStableId,
                title: bookmark.title,
                position: bookmark.position,
                timestamp: bookmark.timestamp,
                note: bookmark.note,
                locator: bookmark.locator,
                mediaType: bookmark.mediaType.rawValue,
                chapterTitle: bookmark.chapterTitle,
                remoteID: bookmark.remoteID,
                isRemotePlaceholder: bookmark.isRemotePlaceholder
            )
        } catch {
            AppLogger.general.error("BookStore.upsertBookmark failed: \(error)")
        }
    }

    func deleteBookmark(id: String) async {
        guard !id.isEmpty else {
            AppLogger.general.error("BookStore.deleteBookmark: rejecting empty id")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.deleteBookmarkRecord(id: id)
        } catch {
            AppLogger.general.error("BookStore.deleteBookmark failed: \(error)")
        }
    }

    func replaceBookmarks(forBookStableId sid: String, bookmarks: [Bookmark]) async {
        guard !sid.isEmpty else {
            AppLogger.general.error("BookStore.replaceBookmarks: rejecting empty bookStableId")
            return
        }
        let validBookmarks = bookmarks.filter { !$0.id.isEmpty }
        if validBookmarks.count != bookmarks.count {
            AppLogger.general.error(
                "BookStore.replaceBookmarks: rejected \(bookmarks.count - validBookmarks.count) bookmark(s) with empty id"
            )
        }
        let worker = makeWorker()
        do {
            let tuples = validBookmarks.map {
                (
                    id: $0.id, title: $0.title, position: $0.position, timestamp: $0.timestamp,
                    note: $0.note, locator: $0.locator, mediaType: $0.mediaType.rawValue,
                    chapterTitle: $0.chapterTitle, remoteID: $0.remoteID,
                    isRemotePlaceholder: $0.isRemotePlaceholder
                )
            }
            try await worker.replaceBookmarkRecords(forBookStableId: sid, bookmarks: tuples)
        } catch {
            AppLogger.general.error("BookStore.replaceBookmarks failed: \(error)")
        }
    }

    func importLegacyBookmarks(_ bookmarks: [Bookmark], bookStableId: String) async {
        let worker = makeWorker()
        do {
            let tuples = bookmarks.map {
                (
                    id: $0.id, title: $0.title, position: $0.position, timestamp: $0.timestamp,
                    note: $0.note, locator: $0.locator, mediaType: $0.mediaType.rawValue,
                    chapterTitle: $0.chapterTitle, remoteID: $0.remoteID,
                    isRemotePlaceholder: $0.isRemotePlaceholder
                )
            }
            try await worker.importBookmarkRecords(tuples, bookStableId: bookStableId)
            AppLogger.general.info("BookStore: imported \(bookmarks.count) legacy bookmarks for \(bookStableId)")
        } catch {
            AppLogger.general.error("BookStore.importLegacyBookmarks failed: \(error)")
        }
    }

    func annotations(forBookStableId sid: String) async -> [ReaderAnnotation] {
        let worker = makeWorker()
        do {
            let snapshots = try await worker.fetchAnnotations(forBookStableId: sid)
            return snapshots.map { s in
                ReaderAnnotation(
                    id: s.id,
                    bookId: s.bookStableId,
                    locator: s.locator,
                    position: s.position,
                    text: s.text,
                    note: s.note,
                    colorHex: s.colorHex,
                    style: ReaderAnnotationStyle(rawValue: s.style) ?? .highlight,
                    chapterTitle: s.chapterTitle,
                    createdAt: s.createdAt,
                    updatedAt: s.updatedAt,
                    remoteID: s.remoteID,
                    isRemotePlaceholder: s.isRemotePlaceholder
                )
            }
        } catch {
            AppLogger.general.error("BookStore.annotations failed: \(error)")
            return []
        }
    }

    func upsertAnnotation(_ annotation: ReaderAnnotation, bookStableId: String) async {
        guard !annotation.id.isEmpty, !bookStableId.isEmpty else {
            AppLogger.general.error("BookStore.upsertAnnotation: rejecting empty annotation id or bookStableId")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.upsertAnnotationRecord(
                id: annotation.id,
                bookStableId: bookStableId,
                locator: annotation.locator,
                position: annotation.position,
                text: annotation.text,
                note: annotation.note,
                colorHex: annotation.colorHex,
                style: annotation.style.rawValue,
                chapterTitle: annotation.chapterTitle,
                createdAt: annotation.createdAt,
                updatedAt: annotation.updatedAt,
                remoteID: annotation.remoteID,
                isRemotePlaceholder: annotation.isRemotePlaceholder
            )
        } catch {
            AppLogger.general.error("BookStore.upsertAnnotation failed: \(error)")
        }
    }

    func deleteAnnotation(id: String) async {
        guard !id.isEmpty else {
            AppLogger.general.error("BookStore.deleteAnnotation: rejecting empty id")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.deleteAnnotationRecord(id: id)
        } catch {
            AppLogger.general.error("BookStore.deleteAnnotation failed: \(error)")
        }
    }

    func replaceAnnotations(forBookStableId sid: String, annotations: [ReaderAnnotation]) async {
        guard !sid.isEmpty else {
            AppLogger.general.error("BookStore.replaceAnnotations: rejecting empty bookStableId")
            return
        }
        let validAnnotations = annotations.filter { !$0.id.isEmpty }
        if validAnnotations.count != annotations.count {
            AppLogger.general.error(
                "BookStore.replaceAnnotations: rejected \(annotations.count - validAnnotations.count) annotation(s) with empty id"
            )
        }
        let worker = makeWorker()
        do {
            let tuples = validAnnotations.map {
                (
                    id: $0.id, locator: $0.locator, position: $0.position, text: $0.text,
                    note: $0.note, colorHex: $0.colorHex, style: $0.style.rawValue,
                    chapterTitle: $0.chapterTitle, createdAt: $0.createdAt, updatedAt: $0.updatedAt,
                    remoteID: $0.remoteID, isRemotePlaceholder: $0.isRemotePlaceholder
                )
            }
            try await worker.replaceAnnotationRecords(forBookStableId: sid, annotations: tuples)
        } catch {
            AppLogger.general.error("BookStore.replaceAnnotations failed: \(error)")
        }
    }

    func importLegacyAnnotations(_ annotations: [ReaderAnnotation], bookStableId: String) async {
        let worker = makeWorker()
        do {
            let tuples = annotations.map {
                (
                    id: $0.id, locator: $0.locator, position: $0.position, text: $0.text,
                    note: $0.note, colorHex: $0.colorHex, style: $0.style.rawValue,
                    chapterTitle: $0.chapterTitle, createdAt: $0.createdAt, updatedAt: $0.updatedAt,
                    remoteID: $0.remoteID, isRemotePlaceholder: $0.isRemotePlaceholder
                )
            }
            try await worker.importAnnotationRecords(tuples, bookStableId: bookStableId)
            AppLogger.general.info("BookStore: imported \(annotations.count) legacy annotations for \(bookStableId)")
        } catch {
            AppLogger.general.error("BookStore.importLegacyAnnotations failed: \(error)")
        }
    }

    func vocabEntries(forBookStableId sid: String) async -> [VocabEntry] {
        let worker = makeWorker()
        do {
            let snapshots = try await worker.fetchVocabEntries(forBookStableId: sid)
            return snapshots.map { entryFromSnapshot($0) }
        } catch {
            AppLogger.general.error("BookStore.vocabEntries failed: \(error)")
            return []
        }
    }

    func allVocabEntries() async -> [VocabEntry] {
        let worker = makeWorker()
        do {
            let snapshots = try await worker.fetchAllVocabEntries()
            return snapshots.map { entryFromSnapshot($0) }
        } catch {
            AppLogger.general.error("BookStore.allVocabEntries failed: \(error)")
            return []
        }
    }

    func upsertVocabEntry(_ entry: VocabEntry) async {
        guard !entry.id.isEmpty, !entry.bookStableId.isEmpty else {
            AppLogger.general.error("BookStore.upsertVocabEntry: rejecting empty entry id or bookStableId")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.upsertVocabEntryRecord(
                id: entry.id,
                bookStableId: entry.bookStableId,
                word: entry.word,
                sentence: entry.sentence,
                sentenceBefore: entry.sentenceBefore,
                sentenceAfter: entry.sentenceAfter,
                locator: entry.locator,
                position: entry.position,
                chapterTitle: entry.chapterTitle,
                definitionSnapshot: entry.definitionSnapshot,
                userNote: entry.userNote,
                lookedUpAt: entry.lookedUpAt,
                tags: entry.tags,
                sourceLanguage: entry.sourceLanguage,
                studyBox: entry.studyBox,
                nextReviewAt: entry.nextReviewAt,
                lastReviewedAt: entry.lastReviewedAt,
                reviewStreak: entry.reviewStreak
            )
        } catch {
            AppLogger.general.error("BookStore.upsertVocabEntry failed: \(error)")
        }
    }

    func deleteVocabEntry(id: String) async {
        guard !id.isEmpty else {
            AppLogger.general.error("BookStore.deleteVocabEntry: rejecting empty id")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.deleteVocabEntryRecord(id: id)
        } catch {
            AppLogger.general.error("BookStore.deleteVocabEntry failed: \(error)")
        }
    }

    private func entryFromSnapshot(_ s: VocabEntrySnapshot) -> VocabEntry {
        VocabEntry(
            id: s.id,
            bookStableId: s.bookStableId,
            word: s.word,
            sentence: s.sentence,
            sentenceBefore: s.sentenceBefore,
            sentenceAfter: s.sentenceAfter,
            locator: s.locator,
            position: s.position,
            chapterTitle: s.chapterTitle,
            definitionSnapshot: s.definitionSnapshot,
            userNote: s.userNote,
            lookedUpAt: s.lookedUpAt,
            tags: s.tags,
            sourceLanguage: s.sourceLanguage,
            studyBox: s.studyBox,
            nextReviewAt: s.nextReviewAt,
            lastReviewedAt: s.lastReviewedAt,
            reviewStreak: s.reviewStreak
        )
    }

    func cachedChapters(forBookStableId sid: String) async -> [Chapter]? {
        let worker = makeWorker()
        do {
            return try await worker.fetchCachedChapters(forBookStableId: sid)
        } catch {
            AppLogger.general.error("BookStore.cachedChapters failed: \(error)")
            return nil
        }
    }

    func cacheChapters(_ chapters: [Chapter], forBookStableId sid: String) async {
        guard !sid.isEmpty else {
            AppLogger.general.error("BookStore.cacheChapters: rejecting empty bookStableId")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.cacheChapterRecords(chapters, forBookStableId: sid)
        } catch {
            AppLogger.general.error("BookStore.cacheChapters failed: \(error)")
        }
    }

}
