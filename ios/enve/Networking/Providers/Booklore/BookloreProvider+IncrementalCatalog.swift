import Foundation
import Logging

extension BookloreProvider {
    func fetchRecentCatalogPage(libraryId: String, page: Int, size: Int) async throws -> LibraryCatalogPage {
        try Task.checkCancellation()
        let data = try await fetchBrowsePageData(
            facets: ["library:\(libraryId)"],
            sort: "-addedOn",
            page: page,
            size: min(size, catalogPageSize)
        )
        let result = try decodeLibraryPage(data, libraryId: libraryId)
        guard result.page == page, result.rejectedItems.isEmpty,
            !result.content.isEmpty || !result.hasNext
        else { throw ProviderError.invalidResponse }

        let context = catalogMapperContext(libraryId: libraryId)
        var books = result.content.map { BookloreCatalogMapper.book(from: $0, context: context) }
        let sourceBookIDs = Set(books.map(\.uniqueId))
        let companions = makeCompanionAudiobooks(forEbooks: &books)
        books.append(contentsOf: companions)
        return LibraryCatalogPage(books: books, totalCount: result.totalElements,
            isLast: !result.hasNext, sourceBookIDs: sourceBookIDs)
    }

    func fetchBooksDelta(libraryId: String, since: Date) async throws -> (books: [Book], cursor: Date)? {
        if useLegacyRestAPI || useLegacyCatalogFallback || useKomgaFallback {
            return nil
        }

        var page = 0
        var collected: [Book] = []
        var maxSeen: Date = since
        var expectedTotal: Int?
        let context = catalogMapperContext(libraryId: libraryId)

        while true {
            let result: BooklorePage<BookloreLegacyBook>
            do {
                let data = try await fetchLibraryPageData(libraryId: libraryId, page: page)
                result = try decodeLibraryPage(data, libraryId: libraryId)
            } catch {
                if Self.isCancellation(error) { throw error }
                return nil
            }

            guard result.page == page, result.rejectedItems.isEmpty,
                expectedTotal == nil || expectedTotal == result.totalElements,
                !result.content.isEmpty || !result.hasNext
            else { return nil }
            expectedTotal = result.totalElements

            if result.content.isEmpty { break }

            var pageHadNew = false
            var pageMaxSeen: Date = .distantPast
            for record in result.content {
                guard let addedDate = record.addedOn?.date else { continue }
                if addedDate > pageMaxSeen { pageMaxSeen = addedDate }
                if addedDate > since {
                    collected.append(BookloreCatalogMapper.book(from: record, context: context))
                    pageHadNew = true
                }
            }
            if pageMaxSeen > maxSeen { maxSeen = pageMaxSeen }

            if !pageHadNew { break }
            if !result.hasNext { break }
            page += 1
        }

        let companions = makeCompanionAudiobooks(forEbooks: &collected)
        collected.append(contentsOf: companions)
        AppLogger.network.info("[Booklore] Delta: \(collected.count) new books since \(since)")
        return (collected, maxSeen)
    }

    // Preserves cancellation; any other legacy-tier failure degrades to an empty recents list.
    private func switchToLegacyRecentBooks(reason: String, libraryId: String, limit: Int) async throws -> [Book] {
        do {
            let all = try await switchToLegacyBooksAPI(reason: reason, libraryId: libraryId).books
            return Array(all.prefix(limit))
        } catch {
            if Self.isCancellation(error) { throw error }
            return []
        }
    }

    func fetchRecentBooks(libraryId: String, limit: Int) async throws -> [Book] {
        if useLegacyRestAPI {
            do {
                let all = try await fetchBooksViaLegacyAPI(libraryId: libraryId).books
                return Array(all.prefix(limit))
            } catch {
                if Self.isCancellation(error) { throw error }
                return []
            }
        }
        if useKomgaFallback {
            return try await fetchRecentBooksViaKomga(libraryId: libraryId, limit: limit)
        }

        let result: BooklorePage<BookloreLegacyBook>
        do {
            let data = try await fetchBrowsePageData(
                facets: ["library:\(libraryId)"],
                sort: "-addedOn",
                page: 0,
                size: min(limit, catalogPageSize)
            )
            result = try decodeLibraryPage(data, libraryId: libraryId)
        } catch {
            if Self.isCancellation(error) { throw error }
            return try await switchToLegacyRecentBooks(
                reason: "Recent books request failed (\(error.localizedDescription))",
                libraryId: libraryId,
                limit: limit
            )
        }

        if result.content.isEmpty {
            return try await switchToLegacyRecentBooks(reason: "Recent books returned empty page", libraryId: libraryId, limit: limit)
        }

        let context = catalogMapperContext(libraryId: libraryId)
        var books = result.content.map { BookloreCatalogMapper.book(from: $0, context: context) }
        let companions = makeCompanionAudiobooks(forEbooks: &books)
        books.append(contentsOf: companions)
        let audiobookIndices = books.indices.filter { books[$0].mediaType == .audiobook }
        if !audiobookIndices.isEmpty {
            await withTaskGroup(of: (Int, Book).self) { group in
                for idx in audiobookIndices {
                    let book = books[idx]
                    group.addTask {
                        let enriched = await self.enrichListedAudiobook(book)
                        return (idx, enriched)
                    }
                }
                for await (idx, enriched) in group {
                    books[idx] = enriched
                }
            }
        }

        return books
    }
}
