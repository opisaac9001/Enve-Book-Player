import Foundation
import Logging

extension BookloreProvider {
    func fetchCurrentUser() async throws -> GrimmoryUser {
        let request = try makeRequest(path: "/api/v1/users/me")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch user (HTTP \(response.statusCode))")
        }

        guard let user = try? JSONDecoder().decode(GrimmoryUser.self, from: data) else {
            throw ProviderError.decodingFailed
        }
        return user
    }

    func fetchGrimmoryShelves() async throws -> [GrimmoryShelf] {
        guard !useLegacyRestAPI, !useKomgaFallback else { return [] }
        return try await fetchShelfSummaries().map {
            GrimmoryShelf(
                id: $0.id,
                name: $0.name,
                bookCount: $0.bookCount,
                icon: $0.icon,
                publicShelf: $0.publicShelf
            )
        }
    }

    func fetchReadingSessions(limit: Int = 20, recentBooks: Int = 25) async throws -> [GrimmoryReadingSessionEntry] {
        guard !useLegacyRestAPI, !useKomgaFallback else { return [] }

        let activeBooks = ((try? await fetchRecentBooks(limit: recentBooks)) ?? []).filter { $0.lastReadTime != nil }
        guard !activeBooks.isEmpty else { return [] }
        return await readingSessionClient.fetchSessions(
            bookIds: activeBooks.map(\.bookId),
            limit: limit
        )
    }

    private func fetchBooksFromStableCatalogForStats() async throws -> [GrimmoryRecentBook] {
        let request = try makeRequest(path: "/api/v1/books")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else { return [] }

        struct CatalogPrimaryFile: Decodable {
            let bookType: String?
            let fileName: String?
        }
        struct CatalogMetadata: Decodable {
            let title: String?
            let authors: [String]?
        }
        struct CatalogBook: Decodable {
            let id: FlexibleID
            let addedOn: String?
            let metadata: CatalogMetadata?
            let primaryFile: CatalogPrimaryFile?
        }

        guard let books = try? JSONDecoder().decode([CatalogBook].self, from: data) else {
            return []
        }

        let base = normalize(connection.url)
        return books.map { book in
            let mediaType = BookloreBookMapper.mediaType(from: book.primaryFile?.bookType)
            let fallbackPath = fallbackCoverPath(for: book.id.stringValue, mediaType: mediaType)
            let resolvedTitle =
                mediaType == .audiobook
                ? (BookloreBookMapper.title(fromPrimaryFileName: book.primaryFile?.fileName) ?? book.metadata?.title ?? "Unknown")
                : (book.metadata?.title ?? "Unknown")
            return GrimmoryRecentBook(
                bookId: Int(book.id.stringValue) ?? 0,
                title: resolvedTitle,
                author: BookloreBookMapper.displayAuthor(from: book.metadata?.authors),
                readProgress: nil,
                lastReadTime: book.addedOn,
                readStatus: nil,
                coverURL: "\(base)\(fallbackPath)"
            )
        }
    }

    func fetchRecentBooks(limit: Int = 10) async throws -> [GrimmoryRecentBook] {
        guard !useLegacyRestAPI, !useKomgaFallback else { return [] }

        let page: BooklorePage<BookloreLegacyBook>
        do {
            let data = try await fetchBrowsePageData(
                facets: [],
                sort: "-lastReadTime",
                page: 0,
                size: min(limit, catalogPageSize)
            )
            page = try JSONDecoder().decode(BooklorePage<BookloreLegacyBook>.self, from: data)
        } catch {
            if Self.isCancellation(error) { throw error }
            AppLogger.network.warning("[Booklore] fetchRecentBooks: books page failed, using the stable catalog")
            return try await Array(fetchBooksFromStableCatalogForStats().prefix(limit))
        }
        return page.content.map { recentBook(from: $0) }
    }

    // Stops at the first never-read book so large libraries don't page through every title.
    func fetchAllBooksForStats() async throws -> [GrimmoryRecentBook] {
        guard !useLegacyRestAPI, !useKomgaFallback else { return [] }

        guard let recent = try await fetchStatsBookPages(facets: [], sort: "-lastReadTime", stopAtNeverRead: true) else {
            return try await fetchBooksFromStableCatalogForStats()
        }
        let finished = try await fetchStatsBookPages(facets: ["read_status:READ"], sort: nil, stopAtNeverRead: false) ?? []
        var seen = Set(recent.map(\.bookId))
        return recent + finished.filter { seen.insert($0.bookId).inserted }
    }

    private func fetchStatsBookPages(
        facets: [String],
        sort: String?,
        stopAtNeverRead: Bool
    ) async throws -> [GrimmoryRecentBook]? {
        var page = 0
        var allBooks: [GrimmoryRecentBook] = []

        while true {
            let request = try browsePageRequest(facets: facets, sort: sort, page: page, size: 50)
            let (data, response) = try await performAuthorizedRequest(request)
            guard response.statusCode == 200,
                let result = try? JSONDecoder().decode(BooklorePage<BookloreLegacyBook>.self, from: data)
            else {
                return page == 0 ? nil : allBooks
            }
            let readBooks = stopAtNeverRead ? result.content.filter { $0.lastReadTime != nil } : result.content
            if readBooks.isEmpty { break }

            allBooks.append(contentsOf: readBooks.map { recentBook(from: $0) })

            if readBooks.count < result.content.count || !result.hasNext { break }
            page += 1
            if page > 50 { break }
        }
        return allBooks
    }

    private func recentBook(from book: BookloreLegacyBook) -> GrimmoryRecentBook {
        let mediaType = BookloreBookMapper.mediaType(from: BookloreCatalogMapper.resolvedFileType(file: book.primaryFile))
        let title =
            mediaType == .audiobook
            ? (BookloreBookMapper.title(fromPrimaryFileName: book.primaryFile?.fileName) ?? book.metadata?.title ?? "Unknown")
            : (book.metadata?.title ?? "Unknown")
        let bookId = book.id.stringValue
        return GrimmoryRecentBook(
            bookId: Int(bookId) ?? 0,
            title: title,
            author: BookloreBookMapper.displayAuthor(from: book.metadata?.authors),
            readProgress: BookloreBookMapper.fraction(fromPercent: book.readProgressPercent),
            lastReadTime: book.lastReadTime,
            readStatus: book.readStatus,
            coverURL: "\(normalize(connection.url))\(fallbackCoverPath(for: bookId, mediaType: mediaType))"
        )
    }
}
