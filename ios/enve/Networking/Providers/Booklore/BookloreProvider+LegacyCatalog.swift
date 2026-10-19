import Foundation
import Logging

extension BookloreProvider {
    func fetchLibrariesViaKomga() async throws -> [Library] {
        let request = try makeKomgaBasicRequest(path: "/komga/api/v1/libraries")
        AppLogger.network.info("[Booklore/Komga] GET \(request.url?.redacted.absoluteString ?? "<nil>")")
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await send(request)
        } catch {
            if shouldFallbackFromKomga(error) {
                AppLogger.network.error("[Booklore/Komga] Request failed (\(error.localizedDescription)) - switching to legacy REST API")
                demoteKomgaToLegacyREST()
                return try await fetchLibrariesViaLegacyAPI()
            }
            throw error
        }
        if response.statusCode == 401 {
            AppLogger.network.info("[Booklore/Komga] 401 - no OPDS credentials, switching to legacy REST API")
            demoteKomgaToLegacyREST()
            return try await fetchLibrariesViaLegacyAPI()
        }
        guard response.statusCode == 200 else {
            AppLogger.network.info("[Booklore/Komga] HTTP \(response.statusCode) - switching to legacy REST API")
            demoteKomgaToLegacyREST()
            return try await fetchLibrariesViaLegacyAPI()
        }
        let libraries = try JSONDecoder().decode([KomgaLibrary].self, from: data)
        AppLogger.network.info("[Booklore/Komga] Found \(libraries.count) libraries")
        return libraries.map {
            Library(id: $0.id, name: $0.name, type: "book", providerId: connection.id)
        }
    }

    func fetchBooksViaKomga(libraryId: String) async throws -> (books: [Book], isComplete: Bool) {
        var page = 0
        var allBooks: [Book] = []
        var isComplete = true
        while true {
            let request = try makeKomgaBasicRequest(
                path: "/komga/api/v1/books",
                queryItems: [
                    URLQueryItem(name: "library_id", value: libraryId),
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "size", value: String(pageSize)),
                ]
            )
            if page == 0 { AppLogger.network.info("[Booklore/Komga] GET \(request.url?.redacted.absoluteString ?? "<nil>")") }
            let (data, response): (Data, HTTPURLResponse)
            do {
                (data, response) = try await send(request)
            } catch {
                if shouldFallbackFromKomga(error) {
                    AppLogger.network.error(
                        "[Booklore/Komga] Books request failed (\(error.localizedDescription)) - switching to legacy REST API"
                    )
                    demoteKomgaToLegacyREST()
                    return try await fetchBooksViaLegacyAPI(libraryId: libraryId)
                }
                throw error
            }
            if response.statusCode == 401 {
                AppLogger.network.info("[Booklore/Komga] Books request returned 401 - switching to legacy REST API")
                demoteKomgaToLegacyREST()
                return try await fetchBooksViaLegacyAPI(libraryId: libraryId)
            }
            guard response.statusCode == 200 else {
                AppLogger.network.info("[Booklore/Komga] Books request returned HTTP \(response.statusCode) - switching to legacy REST API")
                demoteKomgaToLegacyREST()
                return try await fetchBooksViaLegacyAPI(libraryId: libraryId)
            }
            let result: KomgaPage<KomgaBook>
            do {
                result = try JSONDecoder().decode(KomgaPage<KomgaBook>.self, from: data)
            } catch {
                AppLogger.network.error("[Booklore/Komga] Books decode failed (page \(page)): \(String(describing: error))")
                throw error
            }
            if !result.rejectedItems.isEmpty { isComplete = false }
            rejectedContent.update(
                connection: connection,
                libraryId: libraryId,
                acceptedItemIdentifiers: Set(result.content.map(\.id)),
                rejectedItems: result.rejectedItems,
                fallbackScope: "komga-page-\(page)"
            )
            allBooks.append(contentsOf: result.content.map { mapKomgaBookToBook($0, libraryId: libraryId) })
            let isLast = result.last ?? (page >= result.totalPages - 1)
            if isLast || result.rawItemCount == 0 { break }
            page += 1
        }
        return (allBooks, isComplete)
    }

    func fetchRecentBooksViaKomga(libraryId: String, limit: Int) async throws -> [Book] {
        let request = try makeKomgaBasicRequest(
            path: "/komga/api/v1/books",
            queryItems: [
                URLQueryItem(name: "library_id", value: libraryId),
                URLQueryItem(name: "page", value: "0"),
                URLQueryItem(name: "size", value: String(min(limit, pageSize))),
            ]
        )
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await send(request)
        } catch {
            if shouldFallbackFromKomga(error) {
                AppLogger.network.error(
                    "[Booklore/Komga] Recent books request failed (\(error.localizedDescription)) - switching to legacy REST API"
                )
                demoteKomgaToLegacyREST()
                let all = (try? await fetchBooksViaLegacyAPI(libraryId: libraryId))?.books ?? []
                return Array(all.prefix(limit))
            }
            throw error
        }
        guard response.statusCode == 200 else {
            if response.statusCode == 401 {
                AppLogger.network.info("[Booklore/Komga] Recent books returned 401 - switching to legacy REST API")
            } else {
                AppLogger.network.info("[Booklore/Komga] Recent books returned HTTP \(response.statusCode) - switching to legacy REST API")
            }
            demoteKomgaToLegacyREST()
            let all = (try? await fetchBooksViaLegacyAPI(libraryId: libraryId))?.books ?? []
            return Array(all.prefix(limit))
        }
        let result = try JSONDecoder().decode(KomgaPage<KomgaBook>.self, from: data)
        rejectedContent.update(
            connection: connection,
            libraryId: libraryId,
            acceptedItemIdentifiers: Set(result.content.map(\.id)),
            rejectedItems: result.rejectedItems,
            fallbackScope: "komga-recent"
        )
        return result.content.map { mapKomgaBookToBook($0, libraryId: libraryId) }
    }

    private func shouldFallbackFromKomga(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return nsError.code == NSURLErrorCancelled || nsError.code == NSURLErrorUserCancelledAuthentication
                || nsError.code == NSURLErrorUserAuthenticationRequired
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled, .userCancelledAuthentication, .userAuthenticationRequired:
                return true
            default:
                break
            }
        }

        return false
    }

    func switchToLegacyBooksAPI(reason: String, libraryId: String) async throws -> (books: [Book], isComplete: Bool) {
        AppLogger.network.info(
            "[Booklore] \(reason) - using legacy catalog endpoint for library \(libraryId) while preserving app feature endpoints"
        )
        useKomgaFallback = false
        useLegacyCatalogFallback = true
        return try await fetchBooksViaLegacyAPI(libraryId: libraryId)
    }

    func mapKomgaBookToBook(_ book: KomgaBook, libraryId: String) -> Book {
        let title = book.metadata?.title ?? book.name
        let author = BookloreBookMapper.displayAuthor(from: book.metadata?.authors?.map { $0.name })
        let komgaAuthors: [String]? = book.metadata?.authors?.compactMap { $0.name.isEmpty ? nil : $0.name }
        let seriesInfo: SeriesInfo? = {
            guard let seriesTitle = book.seriesTitle, !seriesTitle.isEmpty else { return nil }
            return SeriesInfo(name: seriesTitle, sequence: book.metadata?.number)
        }()
        let coverURL = absoluteURL(from: "/komga/api/v1/books/\(book.id)/thumbnail")
        let detectedMediaType: AppMediaType
        if let mimeType = book.media?.mediaType?.lowercased(),
            mimeType.hasPrefix("audio/")
        {
            detectedMediaType = .audiobook
        } else {
            detectedMediaType = .ebook
        }
        return Book(
            id: book.id,
            title: title,
            author: author,
            authors: komgaAuthors,
            narrator: nil,
            seriesInfo: seriesInfo,
            duration: 0,
            coverURL: coverURL,
            mediaType: detectedMediaType,
            description: book.metadata?.summary ?? book.summary,
            genres: [],
            chapters: [],
            publisher: nil,
            progress: 0,
            currentTime: 0,
            isFinished: false,
            lastUpdate: book.created?.date ?? Date(),
            libraryId: book.libraryId ?? libraryId,
            providerId: connection.id,
            source: .booklore,
            rawMetadata: nil
        )
    }

    func fetchLibrariesViaLegacyAPI() async throws -> [Library] {
        let request = try makeRequest(path: "/api/v1/libraries")
        AppLogger.network.info("[Booklore/Legacy] GET \(request.url?.redacted.absoluteString ?? "<nil>")")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Legacy API: failed to fetch libraries (HTTP \(response.statusCode))")
        }
        let libraries = try JSONDecoder().decode([BookloreLegacyLibrary].self, from: data)
        AppLogger.network.info("[Booklore/Legacy] Found \(libraries.count) libraries")
        return
            libraries
            .filter { lib in
                guard let formats = lib.allowedFormats, !formats.isEmpty else { return true }
                return formats.contains {
                    ["EPUB", "PDF", "CBX", "CBR", "CBZ", "FB2", "MOBI", "AZW3", "AUDIOBOOK"].contains($0.uppercased())
                }
            }
            .map {
                Library(
                    id: $0.id.stringValue,
                    name: $0.name,
                    type: BookloreBookMapper.libraryType(from: $0.allowedFormats),
                    providerId: connection.id
                )
            }
    }

    func fetchBooksViaLegacyAPI(libraryId: String) async throws -> (books: [Book], isComplete: Bool) {
        let request = try makeRequest(path: "/api/v1/libraries/\(libraryId)/book")
        AppLogger.network.info("[Booklore/Legacy] GET \(request.url?.redacted.absoluteString ?? "<nil>")")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Legacy API: failed to fetch books (HTTP \(response.statusCode))")
        }
        let decoded: LossyDecodableArray<BookloreLegacyBook>
        do {
            decoded = try JSONDecoder().decode(LossyDecodableArray<BookloreLegacyBook>.self, from: data)
        } catch {
            AppLogger.network.error("[Booklore/Legacy] Books decode failed: \(String(describing: error))")
            throw error
        }
        let books = decoded.values
        rejectedContent.update(
            connection: connection,
            libraryId: libraryId,
            acceptedItemIdentifiers: Set(books.map { $0.id.stringValue }),
            rejectedItems: decoded.rejectedItems,
            fallbackScope: "legacy"
        )
        AppLogger.network.info("[Booklore/Legacy] Fetched \(books.count) books for library \(libraryId)")
        let context = catalogMapperContext(libraryId: libraryId)
        return (books.map { BookloreCatalogMapper.book(from: $0, context: context) }, decoded.rejectedItems.isEmpty)
    }
}
