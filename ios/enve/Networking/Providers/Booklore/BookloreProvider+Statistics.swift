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

        func makeAppBooksRequest(sort: String) throws -> URLRequest {
            try makeRequest(
                path: "/api/v1/app/books",
                queryItems: [
                    URLQueryItem(name: "page", value: "0"),
                    URLQueryItem(name: "size", value: String(limit)),
                    URLQueryItem(name: "sort", value: sort),
                    URLQueryItem(name: "dir", value: "desc"),
                ]
            )
        }

        var (data, response) = try await performAuthorizedRequest(try makeAppBooksRequest(sort: "lastReadTime"))
        if response.statusCode != 200 {

            AppLogger.network.warning(
                "[Booklore] fetchRecentBooks: lastReadTime sort returned HTTP \(response.statusCode), retrying with addedOn sort"
            )
            let fallback = try await performAuthorizedRequest(try makeAppBooksRequest(sort: "addedOn"))
            if fallback.1.statusCode == 200 {
                (data, response) = fallback
            } else {
                return try await Array(fetchBooksFromStableCatalogForStats().prefix(limit))
            }
        }

        struct AppBook: Decodable {
            let id: FlexibleID
            let title: String?
            let authors: [String]?
            let authorNames: [String]?
            let readProgress: Double?
            let lastReadTime: String?
            let readStatus: String?
            let thumbnailUrl: String?
            let primaryFileType: String?
            let primaryFileName: String?
            let primaryFile: BooklorePrimaryFile?
        }
        struct PageResponse: Decodable { let content: [AppBook] }

        let books: [AppBook]
        if let page = try? JSONDecoder().decode(PageResponse.self, from: data) {
            books = page.content
        } else if let arr = try? JSONDecoder().decode([AppBook].self, from: data) {
            books = arr
        } else {
            return try await Array(fetchBooksFromStableCatalogForStats().prefix(limit))
        }

        let base = normalize(connection.url)
        return books.map { book in
            let resolvedType = BookloreCatalogMapper.resolvedFileType(primaryFileType: book.primaryFileType, primaryFile: book.primaryFile)
            let mediaType = BookloreBookMapper.mediaType(from: resolvedType)
            let fallbackPath = fallbackCoverPath(for: book.id.stringValue, mediaType: mediaType)
            let resolvedCoverURL =
                absoluteURL(from: book.thumbnailUrl, mediaType: mediaType)
                ?? absoluteURL(from: fallbackPath, mediaType: mediaType)
            let resolvedTitle =
                mediaType == .audiobook
                ? (BookloreBookMapper.title(fromPrimaryFileName: book.primaryFileName ?? book.primaryFile?.fileName) ?? book.title ?? "Unknown")
                : (book.title ?? "Unknown")
            return GrimmoryRecentBook(
                bookId: Int(book.id.stringValue) ?? 0,
                title: resolvedTitle,
                author: BookloreBookMapper.displayAuthor(from: book.authors ?? book.authorNames),
                readProgress: BookloreBookMapper.fraction(fromReadProgress: book.readProgress),
                lastReadTime: book.lastReadTime,
                readStatus: book.readStatus,
                coverURL: resolvedCoverURL?.absoluteString ?? "\(base)\(fallbackPath)"
            )
        }
    }

    // Stops at the first never-read book so large libraries don't page through every title.
    func fetchAllBooksForStats() async throws -> [GrimmoryRecentBook] {
        guard !useLegacyRestAPI, !useKomgaFallback else { return [] }

        guard let recent = try await fetchStatsBookPages(
            filter: [URLQueryItem(name: "sort", value: "lastReadTime"), URLQueryItem(name: "dir", value: "desc")],
            stopAtNeverRead: true
        ) else {
            return try await fetchBooksFromStableCatalogForStats()
        }
        let finished = try await fetchStatsBookPages(filter: [URLQueryItem(name: "status", value: "READ")], stopAtNeverRead: false) ?? []
        var seen = Set(recent.map(\.bookId))
        return recent + finished.filter { seen.insert($0.bookId).inserted }
    }

    private func fetchStatsBookPages(filter: [URLQueryItem], stopAtNeverRead: Bool) async throws -> [GrimmoryRecentBook]? {
        var page = 0
        var allBooks: [GrimmoryRecentBook] = []
        let base = normalize(connection.url)

        while true {
            let request = try makeRequest(
                path: "/api/v1/app/books",
                queryItems: [
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "size", value: "50"),
                ] + filter
            )
            let (data, response) = try await performAuthorizedRequest(request)
            guard response.statusCode == 200 else {
                return page == 0 ? nil : allBooks
            }

            struct AppBook: Decodable {
                let id: FlexibleID
                let title: String?
                let authors: [String]?
                let authorNames: [String]?
                let readProgress: Double?
                let lastReadTime: String?
                let readStatus: String?
                let thumbnailUrl: String?
                let primaryFileType: String?
                let primaryFileName: String?
                let primaryFile: BooklorePrimaryFile?
            }
            struct PageResponse: Decodable {
                let content: [AppBook]
                let last: Bool?
                let hasNext: Bool?
            }

            guard let pageResp = try? JSONDecoder().decode(PageResponse.self, from: data) else {
                return page == 0 ? nil : allBooks
            }
            let readBooks = stopAtNeverRead ? pageResp.content.filter { $0.lastReadTime != nil } : pageResp.content
            if readBooks.isEmpty { break }

            allBooks.append(
                contentsOf: readBooks.map { book in
                    let resolvedType = BookloreCatalogMapper.resolvedFileType(primaryFileType: book.primaryFileType, primaryFile: book.primaryFile)
                    let mediaType = BookloreBookMapper.mediaType(from: resolvedType)
                    let fallbackPath = fallbackCoverPath(for: book.id.stringValue, mediaType: mediaType)
                    let resolvedCoverURL =
                        absoluteURL(from: book.thumbnailUrl, mediaType: mediaType)
                        ?? absoluteURL(from: fallbackPath, mediaType: mediaType)
                    let resolvedTitle =
                        mediaType == .audiobook
                        ? (BookloreBookMapper.title(fromPrimaryFileName: book.primaryFileName ?? book.primaryFile?.fileName) ?? book.title ?? "Unknown")
                        : (book.title ?? "Unknown")
                    return GrimmoryRecentBook(
                        bookId: Int(book.id.stringValue) ?? 0,
                        title: resolvedTitle,
                        author: BookloreBookMapper.displayAuthor(from: book.authors ?? book.authorNames),
                        readProgress: BookloreBookMapper.fraction(fromReadProgress: book.readProgress),
                        lastReadTime: book.lastReadTime,
                        readStatus: book.readStatus,
                        coverURL: resolvedCoverURL?.absoluteString ?? "\(base)\(fallbackPath)"
                    )
                }
            )

            if readBooks.count < pageResp.content.count || pageResp.last == true || pageResp.hasNext == false { break }
            page += 1
            if page > 50 { break }
        }
        return allBooks
    }
}
