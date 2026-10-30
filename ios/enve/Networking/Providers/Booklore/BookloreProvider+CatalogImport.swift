import Foundation
import Logging

extension BookloreProvider {
    func completeCatalogSync(libraryId: String) {
        catalogCheckpoints.clear(connectionId: connection.id, libraryId: libraryId)
    }

    var supportsTransactionalCatalogImport: Bool {
        !useLegacyRestAPI && !useLegacyCatalogFallback && !useKomgaFallback
    }

    func openCatalogImport(libraryId: String) async throws -> GrimmoryCatalogImportSession {
        guard supportsTransactionalCatalogImport else {
            throw ProviderError.notImplemented
        }

        let firstPageData = try await fetchAppBooksPageData(libraryId: libraryId, page: 0)
        let firstPage = try JSONDecoder().decode(BooklorePage<BookloreBookSummary>.self, from: firstPageData)
        guard firstPage.rawItemCount > 0 else { throw ProviderError.invalidResponse }
        rejectedContent.update(
            connection: connection,
            libraryId: libraryId,
            acceptedItemIdentifiers: Set(firstPage.content.map { $0.id.stringValue }),
            rejectedItems: firstPage.rejectedItems,
            fallbackScope: "page-0"
        )

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
        if prepared.resumed {
            AppLogger.network.info(
                "[Booklore] Resuming committed catalog import for library \(libraryId): \(prepared.checkpoint.committedPages?.count ?? 0)/\(firstPage.totalPages) pages"
            )
        }
        return GrimmoryCatalogImportSession(
            libraryId: libraryId,
            checkpoint: prepared.checkpoint,
            isComplete: firstPage.rejectedItems.isEmpty
        )
    }

    func bindCatalogImport(
        _ session: GrimmoryCatalogImportSession,
        to reconciliation: ReconciliationStart
    ) throws {
        try catalogCheckpoints.bindReconciliation(reconciliation, checkpoint: &session.checkpoint)
    }

    func nextCatalogImportBatch(_ session: GrimmoryCatalogImportSession) async throws -> GrimmoryCatalogImportBatch? {
        let committedPages = session.checkpoint.committedPages ?? []
        let pendingPages = (0..<session.totalPages).filter { !committedPages.contains($0) }
        guard !pendingPages.isEmpty else { return nil }
        let requestedPages = Array(pendingPages.prefix(pageConcurrency))

        var dataByPage: [Int: Data] = [:]
        var pagesToFetch: [Int] = []
        for page in requestedPages {
            if session.checkpoint.completedPages.contains(page),
                let data = try? catalogCheckpoints.pageData(
                    connectionId: connection.id,
                    libraryId: session.libraryId,
                    page: page
                )
            {
                dataByPage[page] = data
            } else {
                pagesToFetch.append(page)
            }
        }

        if !pagesToFetch.isEmpty {
            let fetched = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for page in pagesToFetch {
                    group.addTask {
                        (page, try await self.fetchAppBooksPageData(libraryId: session.libraryId, page: page))
                    }
                }
                var result: [(Int, Data)] = []
                for try await page in group { result.append(page) }
                return result
            }
            for (page, data) in fetched {
                try catalogCheckpoints.recordPage(data, page: page, checkpoint: &session.checkpoint)
                dataByPage[page] = data
            }
        }

        var books: [Book] = []
        let context = catalogMapperContext(libraryId: session.libraryId)
        for pageNumber in requestedPages {
            guard let data = dataByPage[pageNumber] else { throw ProviderError.invalidResponse }
            let page = try JSONDecoder().decode(BooklorePage<BookloreBookSummary>.self, from: data)
            guard page.page == pageNumber,
                page.totalPages == session.totalPages,
                page.totalElements == session.totalElements
            else { throw ProviderError.invalidResponse }
            if !page.rejectedItems.isEmpty { session.isComplete = false }
            rejectedContent.update(
                connection: connection,
                libraryId: session.libraryId,
                acceptedItemIdentifiers: Set(page.content.map { $0.id.stringValue }),
                rejectedItems: page.rejectedItems,
                fallbackScope: "page-\(pageNumber)"
            )
            books.append(contentsOf: page.content.map { BookloreCatalogMapper.book(from: $0, context: context) })
        }

        switch try await resolveCatalogFormats(books) {
        case .resolved(let resolvedBooks, let complete):
            books = resolvedBooks
            if !complete { session.isComplete = false }
        case .batchEndpointUnsupported:
            _ = try await switchToLegacyBooksAPI(
                reason: "Mobile app books lack the batch format endpoint",
                libraryId: session.libraryId,
                expectedBookIds: Set(books.map(\.id))
            )
            throw ProviderError.serverError("Grimmory batch format endpoint is unavailable")
        }
        let companions = makeCompanionAudiobooks(forEbooks: &books)
        books.append(contentsOf: companions)
        books = try validateCatalogIdentities(books, session: session)

        let loadedSoFar = (session.checkpoint.committedBookCount ?? 0) + books.count
        return GrimmoryCatalogImportBatch(
            pages: requestedPages,
            books: books,
            loadedSoFar: loadedSoFar,
            totalCount: max(session.totalElements, loadedSoFar)
        )
    }

    func markCatalogImportBatchCommitted(
        _ batch: GrimmoryCatalogImportBatch,
        session: GrimmoryCatalogImportSession
    ) throws {
        try catalogCheckpoints.markCommitted(
            pages: batch.pages,
            bookCount: batch.books.count,
            checkpoint: &session.checkpoint
        )
    }

    private func validateCatalogIdentities(
        _ books: [Book],
        session: GrimmoryCatalogImportSession
    ) throws -> [Book] {
        var result: [Book] = []
        result.reserveCapacity(books.count)
        for book in books {
            guard book.providerId == connection.id else { throw ProviderError.invalidResponse }
            let normalizedTitle = book.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normalizedAuthor = (book.author ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let signature = "\(book.mediaType.rawValue)|\(normalizedTitle)|\(normalizedAuthor)"
            if let prior = session.seenIdentities[book.uniqueId] {
                guard prior == signature else {
                    throw ProviderError.serverError("Grimmory returned conflicting books for identity \(book.uniqueId)")
                }
                continue
            }
            session.seenIdentities[book.uniqueId] = signature
            result.append(book)
        }
        return result
    }
}
