import Foundation
import Logging

extension BookloreProvider {
    func fetchBooksDelta(libraryId: String, since: Date) async throws -> (books: [Book], cursor: Date)? {
        if useLegacyRestAPI || useLegacyCatalogFallback || useKomgaFallback {
            return nil
        }

        var page = 0
        var collected: [Book] = []
        var maxSeen: Date = since
        let context = catalogMapperContext(libraryId: libraryId)

        while true {
            let request = try makeRequest(
                path: "/api/v1/app/books",
                queryItems: [
                    URLQueryItem(name: "libraryId", value: libraryId),
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "size", value: String(pageSize)),
                    URLQueryItem(name: "sort", value: "addedOn"),
                    URLQueryItem(name: "dir", value: "desc"),
                ]
            )
            let (data, response): (Data, HTTPURLResponse)
            do {
                (data, response) = try await performAuthorizedRequest(request)
            } catch {
                if Self.isCancellation(error) { throw error }
                return nil
            }
            guard response.statusCode == 200 else { return nil }
            do {
                try guardJSON(data, response: response, endpoint: "/api/v1/app/books")
            } catch { return nil }

            let result: BooklorePage<BookloreBookSummary>
            do {
                result = try JSONDecoder().decode(BooklorePage<BookloreBookSummary>.self, from: data)
            } catch { return nil }

            if result.content.isEmpty { break }

            var pageHadNew = false
            var pageMaxSeen: Date = .distantPast
            for summary in result.content {
                guard let addedDate = summary.addedOn?.date else { continue }
                if addedDate > pageMaxSeen { pageMaxSeen = addedDate }
                if addedDate > since {
                    collected.append(BookloreCatalogMapper.book(from: summary, context: context))
                    pageHadNew = true
                }
            }
            if pageMaxSeen > maxSeen { maxSeen = pageMaxSeen }

            if !pageHadNew { break }
            if !result.hasNext { break }
            page += 1
        }

        // A nil delta persists nothing and leaves the cursor untouched.
        do {
            switch try await resolveCatalogFormats(collected) {
            case .batchEndpointUnsupported:
                return nil
            case .resolved(let books, let complete):
                guard complete else { return nil }
                collected = books
            }
        } catch {
            if Self.isCancellation(error) { throw error }
            return nil
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

        let request = try makeRequest(
            path: "/api/v1/app/books",
            queryItems: [
                URLQueryItem(name: "libraryId", value: libraryId),
                URLQueryItem(name: "page", value: "0"),
                URLQueryItem(name: "size", value: String(min(limit, pageSize))),
                URLQueryItem(name: "sort", value: "addedOn"),
                URLQueryItem(name: "dir", value: "desc"),
            ]
        )
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await performAuthorizedRequest(request)
        } catch {
            if Self.isCancellation(error) { throw error }
            return try await switchToLegacyRecentBooks(
                reason: "Recent books request failed (\(error.localizedDescription))",
                libraryId: libraryId,
                limit: limit
            )
        }
        guard response.statusCode == 200 else {
            return try await switchToLegacyRecentBooks(
                reason: "Recent books returned HTTP \(response.statusCode)",
                libraryId: libraryId,
                limit: limit
            )
        }

        do {
            try guardJSON(data, response: response, endpoint: "/api/v1/app/books")
        } catch {
            return try await switchToLegacyRecentBooks(reason: "Recent books returned non-JSON/HTML", libraryId: libraryId, limit: limit)
        }

        let result: BooklorePage<BookloreBookSummary>
        do {
            result = try JSONDecoder().decode(BooklorePage<BookloreBookSummary>.self, from: data)
        } catch {
            return try await switchToLegacyRecentBooks(reason: "Recent books decode failed", libraryId: libraryId, limit: limit)
        }

        if result.content.isEmpty {
            return try await switchToLegacyRecentBooks(reason: "Recent books returned empty page", libraryId: libraryId, limit: limit)
        }

        let context = catalogMapperContext(libraryId: libraryId)
        var books: [Book]
        // Unresolved summaries are dropped so the recents merge never sees summary-only formats.
        switch try await resolveCatalogFormats(
            result.content.map { BookloreCatalogMapper.book(from: $0, context: context) }
        ) {
        case .batchEndpointUnsupported:
            return try await switchToLegacyRecentBooks(
                reason: "Recent books lack the batch format endpoint",
                libraryId: libraryId,
                limit: limit
            )
        case .resolved(let resolved, _):
            books = resolved
        }
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
