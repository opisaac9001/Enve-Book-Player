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

        let firstPage: BooklorePage<BookloreBookSummary>
        let firstPageData: Data
        do {
            let data = try await fetchAppBooksPageData(libraryId: libraryId, page: 0)
            firstPageData = data
            firstPage = try JSONDecoder().decode(BooklorePage<BookloreBookSummary>.self, from: data)
        } catch {
            if Self.isCancellation(error) { throw error }
            return try await switchToLegacyBooksAPI(
                reason: "Mobile app books request failed (\(error.localizedDescription))",
                libraryId: libraryId
            )
        }

        if firstPage.rawItemCount == 0 {
            return try await switchToLegacyBooksAPI(
                reason: "Mobile app books returned an empty first page",
                libraryId: libraryId,
                expectedBookIds: []
            )
        }

        var appBookIds = Set(firstPage.content.map { $0.id.stringValue })
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
                    let stagedPage = try JSONDecoder().decode(BooklorePage<BookloreBookSummary>.self, from: data)
                    guard stagedPage.page == page,
                        stagedPage.totalPages == firstPage.totalPages,
                        stagedPage.totalElements == firstPage.totalElements
                    else {
                        throw ProviderError.invalidResponse
                    }
                    appBookIds.formUnion(stagedPage.content.map { $0.id.stringValue })
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
                            (page, try await self.fetchAppBooksPageData(libraryId: libraryId, page: page))
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
                        let decoded = try JSONDecoder().decode(BooklorePage<BookloreBookSummary>.self, from: data)
                        guard decoded.page == page,
                            decoded.totalPages == firstPage.totalPages,
                            decoded.totalElements == firstPage.totalElements
                        else {
                            throw ProviderError.invalidResponse
                        }
                        appBookIds.formUnion(decoded.content.map { $0.id.stringValue })
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
                    reason: "Mobile app books page batch failed (\(error.localizedDescription))",
                    libraryId: libraryId,
                    expectedBookIds: appBookIds
                )
            }
            missingOffset = endOffset
        }

        var allBooks: [Book] = []
        var snapshotIsComplete = true
        let context = catalogMapperContext(libraryId: libraryId)
        // Returns false when the server has no batch format endpoint so the snapshot can switch tiers.
        func append(_ page: BooklorePage<BookloreBookSummary>) async throws -> Bool {
            if !page.rejectedItems.isEmpty { snapshotIsComplete = false }
            rejectedContent.update(
                connection: connection,
                libraryId: libraryId,
                acceptedItemIdentifiers: Set(page.content.map { $0.id.stringValue }),
                rejectedItems: page.rejectedItems,
                fallbackScope: "page-\(page.page)"
            )
            switch try await resolveCatalogFormats(
                page.content.map { BookloreCatalogMapper.book(from: $0, context: context) }
            ) {
            case .batchEndpointUnsupported:
                return false
            case .resolved(let books, let complete):
                if !complete { snapshotIsComplete = false }
                allBooks.append(contentsOf: books)
                onBatch?(
                    LibraryFetchBatchResult(
                        books: books,
                        loadedSoFar: allBooks.count,
                        totalCount: firstPage.totalElements
                    )
                )
                return true
            }
        }

        for page in 0..<firstPage.totalPages {
            guard let data = pageData[page] else {
                return try await switchToLegacyBooksAPI(
                    reason: "Mobile app books snapshot is missing page \(page)",
                    libraryId: libraryId,
                    expectedBookIds: appBookIds
                )
            }
            let decoded: BooklorePage<BookloreBookSummary>
            do {
                decoded = try JSONDecoder().decode(BooklorePage<BookloreBookSummary>.self, from: data)
            } catch {
                return try await switchToLegacyBooksAPI(
                    reason: "Mobile app books staged page decode failed (\(error.localizedDescription))",
                    libraryId: libraryId,
                    expectedBookIds: appBookIds
                )
            }
            guard try await append(decoded) else {
                return try await switchToLegacyBooksAPI(
                    reason: "Mobile app books lack the batch format endpoint",
                    libraryId: libraryId,
                    expectedBookIds: appBookIds
                )
            }
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

    func catalogFingerprint(for page: BooklorePage<BookloreBookSummary>) -> String {
        let identity = page.content.map { $0.id.stringValue }.joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func fetchAppBooksPageData(libraryId: String, page: Int) async throws -> Data {
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
        if page == 0 {
            AppLogger.network.info("[Booklore] GET \(request.url?.redacted.absoluteString ?? "<nil>")")
        }

        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Mobile app books returned HTTP \(response.statusCode)")
        }
        try guardJSON(data, response: response, endpoint: "/api/v1/app/books")
        return data
    }

    var supportsRemoteBrowsing: Bool { supportsTransactionalCatalogImport }
}
