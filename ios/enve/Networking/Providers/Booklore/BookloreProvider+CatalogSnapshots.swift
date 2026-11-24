import CryptoKit
import Foundation
import Logging

extension BookloreProvider {
    func fetchLibraries() async throws -> [Library] {
        if connection.token == nil || connection.token?.isEmpty == true,
            let username = connection.username,
            let password = connection.password,
            !username.isEmpty
        {
            try await loginCoalesced(username: username, password: password)
            AppLogger.network.info("[Booklore] Pre-fetched JWT so cover thumbnails will be authenticated")
        }

        if useLegacyRestAPI || useLegacyCatalogFallback {
            return try await fetchLibrariesViaLegacyAPI()
        }

        if useKomgaFallback {
            return try await fetchLibrariesViaKomga()
        }

        return try await fetchLibrariesViaLegacyAPI()
    }

    func fetchBooks(libraryId: String) async throws -> [Book] {
        try await fetchCatalogSnapshot(libraryId: libraryId, onBatch: nil).books
    }

    func makeCatalogBatchSource(
        libraryId: String,
        resumeAfter: String?,
        expectedSnapshotIdentifier: String?
    ) async throws -> LibraryCatalogBatchSource {
        let snapshot = try await fetchCatalogSnapshot(libraryId: libraryId, onBatch: nil)
        return LibraryCatalogBatchSource.snapshot(
            books: snapshot.books,
            isComplete: snapshot.isComplete,
            resumeAfter: resumeAfter,
            expectedSnapshotIdentifier: expectedSnapshotIdentifier
        )
    }

    func fetchBooks(libraryId: String, onBatch: ((_ batch: LibraryFetchBatchResult) -> Void)?) async throws -> [Book] {
        try await fetchCatalogSnapshot(libraryId: libraryId, onBatch: onBatch).books
    }

    private func fetchCatalogSnapshot(
        libraryId: String,
        onBatch: ((_ batch: LibraryFetchBatchResult) -> Void)?
    ) async throws -> (books: [Book], isComplete: Bool) {
        if useLegacyRestAPI {
            return try await fetchBooksViaLegacyAPI(libraryId: libraryId)
        }
        if useLegacyCatalogFallback {
            let legacy = try await fetchBooksViaLegacyAPI(libraryId: libraryId)
            var legacyBooks = legacy.books
            var companions = makeCompanionAudiobooks(forEbooks: &legacyBooks)
            if !companions.isEmpty {
                await withTaskGroup(of: (Int, Book).self) { group in
                    for idx in companions.indices {
                        let book = companions[idx]
                        group.addTask { (idx, await self.enrichListedAudiobook(book)) }
                    }
                    for await (idx, enriched) in group {
                        companions[idx] = enriched
                    }
                }
                legacyBooks.append(contentsOf: companions)
                AppLogger.network.info("[Booklore] Emitted \(companions.count) companion audiobook entries (legacy-catalog tier)")
            }
            return (legacyBooks, legacy.isComplete)
        }
        if useKomgaFallback {
            return try await fetchBooksViaKomga(libraryId: libraryId)
        }

        let firstPage: BooklorePage<BookloreLegacyBook>
        let firstPageData: Data
        do {
            let data = try await fetchLibraryPageData(libraryId: libraryId, page: 0)
            firstPageData = data
            firstPage = try decodeLibraryPage(data, libraryId: libraryId)
        } catch {
            if Self.isCancellation(error) { throw error }
            return try await switchToLegacyBooksAPI(
                reason: "Books page request failed (\(error.localizedDescription))",
                libraryId: libraryId
            )
        }

        if firstPage.rawItemCount == 0 {
            return try await switchToLegacyBooksAPI(
                reason: "Books page returned an empty first page",
                libraryId: libraryId,
                expectedBookIds: []
            )
        }

        var pageBookIds = Set(firstPage.content.map { $0.id.stringValue })
        var checkpoint: GrimmoryCatalogCheckpoint?
        do {
            let prepared = try catalogCheckpoints.prepare(
                connectionId: connection.id,
                libraryId: libraryId,
                serverIdentity: connection.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased(),
                totalPages: firstPage.totalPages,
                totalElements: firstPage.totalElements,
                pageSize: firstPage.size,
                firstPageFingerprint: catalogFingerprint(for: firstPage),
                firstPageData: firstPageData
            )
            checkpoint = prepared.checkpoint
            if prepared.resumed {
                AppLogger.network.info(
                    "[Booklore] Resuming catalog checkpoint for library \(libraryId) with \(prepared.checkpoint.completedPages.count)/\(firstPage.totalPages) pages staged"
                )
            }
        } catch {
            AppLogger.network.warning("[Booklore] Catalog checkpoint unavailable: \(error.localizedDescription)")
        }

        var pageData: [Int: Data] = [0: firstPageData]
        if var current = checkpoint {
            for page in current.completedPages.sorted() where page > 0 && page < firstPage.totalPages {
                do {
                    let data = try catalogCheckpoints.pageData(
                        connectionId: connection.id,
                        libraryId: libraryId,
                        page: page
                    )
                    let stagedPage = try decodeLibraryPage(data, libraryId: libraryId)
                    guard stagedPage.page == page,
                        stagedPage.totalPages == firstPage.totalPages,
                        stagedPage.totalElements == firstPage.totalElements
                    else {
                        throw ProviderError.invalidResponse
                    }
                    pageBookIds.formUnion(stagedPage.content.map { $0.id.stringValue })
                    pageData[page] = data
                } catch {
                    catalogCheckpoints.discardPage(page: page, checkpoint: &current)
                    AppLogger.network.warning("[Booklore] Discarded invalid staged catalog page \(page)")
                }
            }
            checkpoint = current
        }

        let missingPages = (1..<firstPage.totalPages).filter { pageData[$0] == nil }
        var missingOffset = 0
        while missingOffset < missingPages.count {
            let endOffset = min(missingOffset + pageConcurrency, missingPages.count)
            let requestedPages = Array(missingPages[missingOffset..<endOffset])
            do {
                let pages = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                    for page in requestedPages {
                        group.addTask {
                            (page, try await self.fetchLibraryPageData(libraryId: libraryId, page: page))
                        }
                    }

                    var loaded: [(Int, Data)] = []
                    loaded.reserveCapacity(requestedPages.count)
                    for try await page in group {
                        loaded.append(page)
                    }
                    return loaded.sorted { $0.0 < $1.0 }
                }

                for (page, data) in pages {
                    do {
                        let decoded = try decodeLibraryPage(data, libraryId: libraryId)
                        guard decoded.page == page,
                            decoded.totalPages == firstPage.totalPages,
                            decoded.totalElements == firstPage.totalElements
                        else {
                            throw ProviderError.invalidResponse
                        }
                        pageBookIds.formUnion(decoded.content.map { $0.id.stringValue })
                        pageData[page] = data
                        if var current = checkpoint {
                            do {
                                try catalogCheckpoints.recordPage(data, page: page, checkpoint: &current)
                                checkpoint = current
                            } catch {
                                checkpoint = nil
                                AppLogger.network.warning(
                                    "[Booklore] Could not persist catalog page \(page): \(error.localizedDescription)"
                                )
                            }
                        }
                    } catch {
                        AppLogger.network.error("[Booklore] Book page decode failed (page \(page)): \(String(describing: error))")
                        throw error
                    }
                }
            } catch {
                if Self.isCancellation(error) { throw error }
                return try await switchToLegacyBooksAPI(
                    reason: "Books page batch failed (\(error.localizedDescription))",
                    libraryId: libraryId,
                    expectedBookIds: pageBookIds
                )
            }
            missingOffset = endOffset
        }

        var allBooks: [Book] = []
        var snapshotIsComplete = true
        let context = catalogMapperContext(libraryId: libraryId)
        for page in 0..<firstPage.totalPages {
            guard let data = pageData[page] else {
                return try await switchToLegacyBooksAPI(
                    reason: "Books page snapshot is missing page \(page)",
                    libraryId: libraryId,
                    expectedBookIds: pageBookIds
                )
            }
            let decoded: BooklorePage<BookloreLegacyBook>
            do {
                decoded = try decodeLibraryPage(data, libraryId: libraryId)
            } catch {
                return try await switchToLegacyBooksAPI(
                    reason: "Books page staged page decode failed (\(error.localizedDescription))",
                    libraryId: libraryId,
                    expectedBookIds: pageBookIds
                )
            }
            if !decoded.rejectedItems.isEmpty { snapshotIsComplete = false }
            rejectedContent.update(
                connection: connection,
                libraryId: libraryId,
                acceptedItemIdentifiers: Set(decoded.content.map { $0.id.stringValue }),
                rejectedItems: decoded.rejectedItems,
                fallbackScope: "page-\(decoded.page)"
            )
            let books = decoded.content.map { BookloreCatalogMapper.book(from: $0, context: context) }
            allBooks.append(contentsOf: books)
            onBatch?(
                LibraryFetchBatchResult(
                    books: books,
                    loadedSoFar: allBooks.count,
                    totalCount: firstPage.totalElements
                )
            )
        }

        let companions = makeCompanionAudiobooks(forEbooks: &allBooks)
        if !companions.isEmpty {
            allBooks.append(contentsOf: companions)
            onBatch?(LibraryFetchBatchResult(books: companions, loadedSoFar: allBooks.count, totalCount: allBooks.count))
            AppLogger.network.info("[Booklore] Emitted \(companions.count) companion audiobook entries")
        }

        AppLogger.network.info("[Booklore] Fetched \(allBooks.count) books from library \(libraryId)")
        return (allBooks, snapshotIsComplete)
    }

    func catalogFingerprint(for page: BooklorePage<BookloreLegacyBook>) -> String {
        let identity = page.content.map { $0.id.stringValue }.joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // Grimmory rejects `id` as a caller sort key; it always appends `id` as the ascending tiebreaker.
    func browsePageRequest(
        facets: [String],
        sort: String?,
        query: String? = nil,
        page: Int,
        size: Int
    ) throws -> URLRequest {
        var queryItems = facets.map { URLQueryItem(name: "facet", value: $0) }
        if let sort {
            queryItems.append(URLQueryItem(name: "sort", value: sort))
        }
        if let query {
            queryItems.append(URLQueryItem(name: "query", value: query))
        }
        queryItems.append(URLQueryItem(name: "page", value: String(page)))
        queryItems.append(URLQueryItem(name: "size", value: String(size)))
        return try makeRequest(path: "/api/v1/books/page", queryItems: queryItems)
    }

    func fetchBrowsePageData(
        facets: [String],
        sort: String?,
        query: String? = nil,
        page: Int,
        size: Int
    ) async throws -> Data {
        let request = try browsePageRequest(facets: facets, sort: sort, query: query, page: page, size: size)
        if page == 0 {
            AppLogger.network.info("[Booklore] GET \(request.url?.redacted.absoluteString ?? "<nil>")")
        }
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Grimmory books page returned HTTP \(response.statusCode)")
        }
        try guardJSON(data, response: response, endpoint: "/api/v1/books/page")
        return data
    }

    func fetchLibraryPageData(libraryId: String, page: Int) async throws -> Data {
        try await fetchBrowsePageData(
            facets: ["library:\(libraryId)"],
            sort: "-addedOn",
            page: page,
            size: catalogPageSize
        )
    }

    // The library facet is the only scope on a browse page; a server that ignored it would leak other libraries.
    func decodeLibraryPage(_ data: Data, libraryId: String) throws -> BooklorePage<BookloreLegacyBook> {
        let page = try JSONDecoder().decode(BooklorePage<BookloreLegacyBook>.self, from: data)
        guard page.content.allSatisfy({ $0.libraryId?.stringValue == libraryId }) else {
            throw ProviderError.invalidResponse
        }
        return page
    }

    var supportsRemoteBrowsing: Bool { supportsTransactionalCatalogImport }
}
