import Foundation
import Logging

class KomgaProvider: IncrementalCatalogProvider, EbookProgressPushing, EbookDownloadProvider,
    ServerPageProvider, @unchecked Sendable
{
    var connection: ServerConnection
    private let pageSize = 100

    init(connection: ServerConnection) {
        self.connection = connection
    }

    func validateConnection() async throws -> Bool {
        let request = try makeRequest(path: "/api/v1/libraries")
        let (_, response) = try await send(request)
        return response.statusCode == 200
    }

    func fetchLibraries() async throws -> [Library] {
        let request = try makeRequest(path: "/api/v1/libraries")
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch libraries (HTTP \(response.statusCode))")
        }
        let libraries = try JSONDecoder().decode([KomgaLibrary].self, from: data)
        return libraries.map {
            Library(id: $0.id, name: $0.name, type: "book", providerId: connection.id)
        }
    }

    func fetchBooks(libraryId: String) async throws -> [Book] {
        var allBooks: [Book] = []
        let source = try await makeCatalogBatchSource(
            libraryId: libraryId,
            resumeAfter: nil,
            expectedSnapshotIdentifier: nil
        )
        while let batch = try await source.next() { allBooks.append(contentsOf: batch.books) }
        return allBooks
    }

    func makeCatalogBatchSource(
        libraryId: String,
        resumeAfter: String?,
        expectedSnapshotIdentifier: String?
    ) async throws -> LibraryCatalogBatchSource {
        let firstPage = try await fetchCatalogPage(libraryId: libraryId, page: 0)
        return LibraryCatalogBatchSource.paged(
            firstPage: firstPage,
            pageSize: pageSize,
            pageConcurrency: 6,
            resumeAfter: resumeAfter,
            expectedSnapshotIdentifier: expectedSnapshotIdentifier,
            fetchPage: { try await self.fetchCatalogPage(libraryId: libraryId, page: $0) }
        )
    }

    private func fetchCatalogPage(libraryId: String, page: Int) async throws -> LibraryCatalogPage {
        let request = try makeRequest(
            path: "/api/v1/books",
            queryItems: [
                URLQueryItem(name: "library_id", value: libraryId),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "size", value: String(pageSize)),
            ]
        )
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch books (HTTP \(response.statusCode))")
        }
        let result = try JSONDecoder().decode(KomgaPage<KomgaBook>.self, from: data)
        if page == 0 {
            AppLogger.network.debug(
                "[Komga] library=\(libraryId) totalElements=\(result.totalElements) totalPages=\(result.totalPages) firstPageCount=\(result.content.count)"
            )
        }
        return LibraryCatalogPage(
            books: result.content.map { mapToBook($0, libraryId: libraryId) },
            totalCount: result.totalElements,
            isLast: result.last ?? (result.content.isEmpty || page >= result.totalPages - 1)
        )
    }

    func fetchRecentBooks(libraryId: String, limit: Int) async throws -> [Book] {
        let request = try makeRequest(
            path: "/api/v1/books/latest",
            queryItems: [
                URLQueryItem(name: "page", value: "0"),
                URLQueryItem(name: "size", value: String(min(limit, pageSize))),
            ]
        )
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch recent books (HTTP \(response.statusCode))")
        }
        let result = try JSONDecoder().decode(KomgaPage<KomgaBook>.self, from: data)
        return result.content.map { mapToBook($0, libraryId: libraryId) }
    }

    func fetchBooksDelta(libraryId: String, since: Date) async throws -> (books: [Book], cursor: Date)? {
        var page = 0
        var collected: [Book] = []
        var maxSeen: Date = since

        var iterationCeiling = 5_000
        var iter = 0

        while iter < iterationCeiling {
            iter += 1
            let request: URLRequest
            do {
                request = try makeRequest(
                    path: "/api/v1/books",
                    queryItems: [
                        URLQueryItem(name: "library_id", value: libraryId),
                        URLQueryItem(name: "page", value: String(page)),
                        URLQueryItem(name: "size", value: String(pageSize)),
                        URLQueryItem(name: "sort", value: "created,desc"),
                    ]
                )
            } catch { return nil }

            let (data, response): (Data, HTTPURLResponse)
            do {
                (data, response) = try await send(request)
            } catch { return nil }
            guard response.statusCode == 200 else { return nil }

            let result: KomgaPage<KomgaBook>
            do {
                result = try JSONDecoder().decode(KomgaPage<KomgaBook>.self, from: data)
            } catch { return nil }
            if result.content.isEmpty { break }
            if page == 0, result.totalPages > 0 {
                iterationCeiling = min(result.totalPages + 5, iterationCeiling)
            }

            var pageHadNew = false
            var pageMaxSeen: Date = .distantPast
            for komgaBook in result.content {
                let created = komgaBook.created ?? .distantPast
                if created > pageMaxSeen { pageMaxSeen = created }
                if created > since {
                    collected.append(mapToBook(komgaBook, libraryId: libraryId))
                    pageHadNew = true
                }
            }
            if pageMaxSeen > maxSeen { maxSeen = pageMaxSeen }

            if !pageHadNew { break }
            let isLast = result.last ?? (page >= result.totalPages - 1)
            if isLast { break }
            page += 1
        }

        return (collected, maxSeen)
    }

    func fetchCollections(libraryId: String?) async throws -> [Collection] {
        var page = 0
        var allCollections: [Collection] = []
        var iterationCeiling = 5_000
        var iter = 0
        while iter < iterationCeiling {
            iter += 1
            let request = try makeRequest(
                path: "/api/v1/collections",
                queryItems: [
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "size", value: String(pageSize)),
                ]
            )
            let (data, response) = try await send(request)
            guard response.statusCode == 200 else { break }
            let result = try JSONDecoder().decode(KomgaPage<KomgaCollection>.self, from: data)
            if page == 0, result.totalPages > 0 {
                iterationCeiling = min(result.totalPages + 5, iterationCeiling)
            }
            for item in result.content {
                let bookIds = item.seriesIds ?? []
                allCollections.append(
                    Collection(
                        id: item.id,
                        name: item.name,
                        description: nil,
                        books: bookIds,
                        bookCount: bookIds.count,
                        iconName: "square.stack.3d.down.right.fill",
                        color: "orange",
                        providerId: connection.id
                    )
                )
            }
            if result.content.count < pageSize { break }
            let isLast = result.last ?? (page >= result.totalPages - 1)
            if isLast || result.content.isEmpty { break }
            page += 1
        }
        return allCollections
    }

    func fetchSeries(libraryId: String) async throws -> [Series] {
        let request = try makeRequest(
            path: "/api/v1/series",
            queryItems: [
                URLQueryItem(name: "library_id", value: libraryId),
                URLQueryItem(name: "page", value: "0"),
                URLQueryItem(name: "size", value: "500"),
            ]
        )
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else { return [] }
        let result = try JSONDecoder().decode(KomgaPage<KomgaSeries>.self, from: data)
        return result.content.map {
            Series(
                id: $0.id,
                name: $0.metadata?.title ?? $0.name,
                description: nil,
                books: [],
                bookSequences: [:],
                bookCount: $0.booksCount ?? 0,
                libraryId: libraryId,
                providerId: connection.id
            )
        }
    }

    func fetchUserMediaProgress(libraryId: String) async throws -> [UserMediaProgress] {
        let books = try await fetchInProgressBooks(
            libraryId: libraryId.isEmpty ? nil : libraryId,
            limit: pageSize
        )
        return books.compactMap { progressSnapshot(from: $0) }
    }

    func fetchFullBookDetails(bookId: String, libraryId: String) async throws -> Book {
        let request = try makeRequest(path: "/api/v1/books/\(bookId)")
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch book details (HTTP \(response.statusCode))")
        }
        let book = try JSONDecoder().decode(KomgaBook.self, from: data)
        return mapToBook(book, libraryId: libraryId)
    }

    func fetchComicCredits(bookId: String) async throws -> ComicCredits {
        let request = try makeRequest(path: "/api/v1/books/\(bookId)")
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch book details (HTTP \(response.statusCode))")
        }
        let book = try JSONDecoder().decode(KomgaBook.self, from: data)

        var byRole: [String: [String]] = [:]
        for author in book.metadata?.authors ?? [] {
            let name = author.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            byRole[author.role.lowercased(), default: []].append(name)
        }
        let roles = ComicCredits.orderedRoles(from: byRole)

        var releaseDate: Date?
        if let raw = book.metadata?.releaseDate {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd"
            releaseDate = formatter.date(from: String(raw.prefix(10)))
        }

        return ComicCredits(
            roles: roles,
            releaseDate: releaseDate,
            pageCount: (book.media?.pagesCount ?? 0) > 0 ? book.media?.pagesCount : nil
        )
    }

    func getAudioURL(for book: Book) -> URL? { nil }
    func getStreamingHeaders() -> [String: String] { authHeaders() }

    func startPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo {
        throw ProviderError.notImplemented
    }

    func updatePlaybackProgress(
        book: Book,
        sessionId: String?,
        currentTime: TimeInterval,
        isFinished: Bool,
        timeListened: TimeInterval
    ) async throws {
    }

    func downloadEbook(for book: Book, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        if let cached = LocalEbookImporter.shared.cachedEbook(forBookId: book.id) {
            onProgress?(1)
            return cached
        }

        let request = try makeRequest(
            path: "/api/v1/books/\(book.id)/file",
            accept:
                "application/epub+zip, application/pdf, application/vnd.comicbook+zip, application/vnd.comicbook-rar, application/octet-stream, */*;q=0.8"
        )
        AppLogger.network.debug(
            "[Komga] Starting download bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) endpoint=\(request.url?.redacted.absoluteString ?? "nil")"
        )

        let progressHandler: @Sendable (Double) -> Void = onProgress ?? { _ in }
        let credential: URLCredential? = {
            guard let username = connection.username,
                let password = connection.password,
                !username.isEmpty
            else { return nil }
            return URLCredential(user: username, password: password, persistence: .forSession)
        }()
        let delegate = URLSessionDownloadProgressDelegate(progressHandler: progressHandler, credential: credential)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 3600
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (tempURL, httpResponse) = try await delegate.awaitResult {
                session.downloadTask(with: request)
            }
            AppLogger.network.info(
                "[Komga] Download task completed: status=\(httpResponse.statusCode) mimeType=\(httpResponse.mimeType ?? "nil")"
            )
            guard httpResponse.statusCode == 200 else {
                try? FileManager.default.removeItem(at: tempURL)
                throw ProviderError.serverError("Failed to download ebook (HTTP \(httpResponse.statusCode))")
            }
            let ext = detectEbookExtension(response: httpResponse) ?? "epub"
            let filename = "\(book.title.replacingOccurrences(of: "/", with: "-")).\(ext)"
            return try LocalEbookImporter.shared.cacheRemoteEbook(
                tempURL: tempURL,
                preferredFilename: filename,
                bookIdentifier: book.id
            )
        } catch {
            AppLogger.network.error("[Komga] Download failed: \(error)")
            throw error
        }
    }

    func updateEbookProgress(for book: Book, progress: Double, epubLocator: String?) async throws {
        let totalPages = try await fetchPageCount(for: book)
        guard totalPages > 0 else {
            throw ProviderError.serverError("Komga returned zero pages for book \(book.id)")
        }
        let currentPage = max(1, Int(progress * Double(totalPages)))
        let body: [String: Any] = [
            "page": currentPage,
            "completed": progress >= 0.99,
        ]
        var request = try makeRequest(path: "/api/v1/books/\(book.id)/read-progress")
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await send(request)
        guard (200...299).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to update progress (HTTP \(response.statusCode))")
        }
    }

    func fetchEbookProgress(for book: Book) async throws -> (progress: Double, locator: String?, updatedAt: Date?, isAbandoned: Bool)? {
        let request = try makeRequest(path: "/api/v1/books/\(book.id)")
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch Komga progress (HTTP \(response.statusCode))")
        }
        let komgaBook = try JSONDecoder().decode(KomgaBook.self, from: data)
        guard let snapshot = progressSnapshot(from: komgaBook) else { return nil }
        return (
            progress: snapshot.ebookProgress ?? snapshot.progress,
            locator: nil,
            updatedAt: snapshot.lastUpdate,
            isAbandoned: false
        )
    }

    func fetchRecentProgress(limit: Int, launchOptimized: Bool) async throws -> [UserMediaProgress] {
        let size = min(max(limit, 1), launchOptimized ? 40 : pageSize)
        let books = try await fetchInProgressBooks(libraryId: nil, limit: size)
        return books.compactMap { progressSnapshot(from: $0) }
    }

    var capabilities: ProviderCapabilities {
        [
            .fullImport, .pagedImport, .deltaImport,
            .recentBooks, .series, .collections,
            .ebookProgressPull, .ebookProgressPush,
            .downloads, .coverAuthHeader,
            .serverPageStreaming, .backgroundOperation,
        ]
    }

    func fetchPageCount(for book: Book) async throws -> Int {
        let request = try makeRequest(path: "/api/v1/books/\(book.id)/pages")
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch page list (HTTP \(response.statusCode))")
        }
        let pages = try JSONDecoder().decode([KomgaPageInfo].self, from: data)
        return pages.count
    }

    func fetchPage(_ pageNumber: Int, for book: Book) async throws -> Data {
        let request = try makeRequest(
            path: "/api/v1/books/\(book.id)/pages/\(pageNumber)",
            accept: "image/jpeg, image/png, image/webp, */*"
        )
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch page \(pageNumber) (HTTP \(response.statusCode))")
        }
        return data
    }

    private func makeRequest(path: String, queryItems: [URLQueryItem] = [], accept: String = "application/json") throws -> URLRequest {
        let base = normalize(connection.url)
        guard var components = URLComponents(string: "\(base)\(path)") else {
            throw ProviderError.invalidURL
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw ProviderError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(accept, forHTTPHeaderField: "Accept")
        for (key, value) in authHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private func authHeaders() -> [String: String] {
        var headers = connection.customHeaders ?? [:]
        if let token = connection.token?.trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty,
            !hasHeader("X-API-Key", in: headers)
        {
            headers["X-API-Key"] = token
        }
        if let username = connection.username,
            let password = connection.password,
            !username.isEmpty,
            connection.token?.isEmpty != false,
            !hasHeader("Authorization", in: headers),
            let data = "\(username):\(password)".data(using: .utf8)
        {
            headers["Authorization"] = "Basic \(data.base64EncodedString())"
        }
        return headers
    }

    private func hasHeader(_ name: String, in headers: [String: String]) -> Bool {
        headers.keys.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw ProviderError.unauthorized
        }
        return (data, httpResponse)
    }

    private func normalize(_ urlString: String) -> String {
        var str = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasSuffix("/") { str.removeLast() }
        if !str.hasPrefix("http") { str = "http://\(str)" }
        return str
    }

    private func coverURL(bookId: String) -> URL? {
        let base = normalize(connection.url)
        return URL(string: "\(base)/api/v1/books/\(bookId)/thumbnail")
    }

    private func fetchInProgressBooks(libraryId: String?, limit: Int) async throws -> [KomgaBook] {
        var queryItems = [
            URLQueryItem(name: "page", value: "0"),
            URLQueryItem(name: "size", value: String(min(limit, pageSize))),
            URLQueryItem(name: "read_status", value: "IN_PROGRESS"),
            URLQueryItem(name: "sort", value: "readProgress.lastModified,desc"),
        ]
        if let libraryId, !libraryId.isEmpty {
            queryItems.append(URLQueryItem(name: "library_id", value: libraryId))
        }
        let request = try makeRequest(path: "/api/v1/books", queryItems: queryItems)
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch Komga read progress (HTTP \(response.statusCode))")
        }
        let result = try JSONDecoder().decode(KomgaPage<KomgaBook>.self, from: data)
        return result.content.filter { $0.readProgress != nil }
    }

    private func progressSnapshot(from book: KomgaBook) -> UserMediaProgress? {
        guard let readProgress = book.readProgress else { return nil }
        let totalPages = max(book.media?.pagesCount ?? 0, 0)
        let currentPage = max(readProgress.page, 0)
        let fraction = totalPages > 0 ? min(max(Double(currentPage) / Double(totalPages), 0), 1) : (readProgress.completed ? 1 : 0)
        guard fraction > 0 || readProgress.completed else { return nil }
        return UserMediaProgress(
            id: "\(connection.id)_\(book.id)",
            libraryItemId: book.id,
            providerId: connection.id,
            episodeId: nil,
            currentTime: 0,
            progress: fraction,
            isFinished: readProgress.completed,
            duration: 0,
            lastUpdate: readProgress.lastModified ?? readProgress.readDate ?? readProgress.created ?? .distantPast,
            ebookProgress: fraction
        )
    }

    private func mimeToExtension(_ mime: String) -> String? {
        switch mime.lowercased() {
        case "application/epub+zip": return "epub"
        case "application/pdf": return "pdf"
        case "application/x-cbz", "application/vnd.comicbook+zip", "application/zip", "application/x-zip-compressed": return "cbz"
        case "application/x-cbr", "application/vnd.comicbook-rar", "application/x-rar-compressed", "application/vnd.rar": return "cbr"
        default: return nil
        }
    }

    private func detectEbookExtension(response: HTTPURLResponse) -> String? {
        if let mimeType = response.mimeType,
            let ext = mimeToExtension(mimeType)
        {
            return ext
        }

        if let suggested = response.suggestedFilename,
            let ext = fileExtension(from: suggested)
        {
            return ext
        }

        if let contentDisposition = response.value(forHTTPHeaderField: "Content-Disposition"),
            let ext = fileExtension(from: contentDisposition)
        {
            return ext
        }

        return nil
    }

    private func fileExtension(from value: String) -> String? {
        let normalized = value.lowercased()
        for ext in EbookFormat.allExtensions where normalized.contains(".\(ext)") {
            return ext
        }
        return nil
    }

    private func mapToBook(_ book: KomgaBook, libraryId: String) -> Book {
        let metadataTitle = book.metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let seriesTitle = book.seriesTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let issueNumber =
            book.metadata?.number?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? book.number?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let seriesSequence = Self.seriesSequence(
            issueNumber: issueNumber,
            numberSort: book.metadata?.numberSort
        )
        let originalTitle = metadataTitle ?? book.name
        let title: String
        if let seriesTitle,
            let issueNumber,
            Self.isIssueNumberOnlyTitle(originalTitle, issueNumber: issueNumber)
        {
            title = "\(seriesTitle) - \(issueNumber)"
        } else {
            title = originalTitle
        }
        let authors = book.metadata?.authors?
            .map(\.name)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let author = authors?.joined(separator: ", ").nonEmpty ?? "Unknown Author"
        let seriesInfo: SeriesInfo? = {
            guard let seriesTitle else { return nil }
            return SeriesInfo(name: seriesTitle, sequence: seriesSequence)
        }()
        let detectedMediaType: AppMediaType
        if let mimeType = book.media?.mediaType?.lowercased(), mimeType.hasPrefix("audio/") {
            detectedMediaType = .audiobook
        } else {
            detectedMediaType = .ebook
        }

        let comicFormat: String? = {
            guard let ext = book.media?.mediaType.flatMap(mimeToExtension),
                ext == EbookFormat.cbz.rawValue || ext == EbookFormat.cbr.rawValue
            else { return nil }
            return ext
        }()
        return Book(
            id: book.id,
            title: title,
            author: author,
            authors: authors,
            narrator: nil,
            seriesInfo: seriesInfo,
            duration: 0,
            coverURL: coverURL(bookId: book.id),
            mediaType: detectedMediaType,
            ebookFormat: comicFormat,
            dateAdded: book.created,
            description: book.metadata?.summary?.nonEmpty ?? book.summary,
            genres: book.metadata?.tags,
            chapters: [],
            publisher: nil,
            progress: 0,
            currentTime: 0,
            isFinished: false,
            lastUpdate: book.lastModified ?? book.created ?? Date(),
            libraryId: book.libraryId ?? libraryId,
            providerId: connection.id,
            source: .komga,
            rawMetadata: nil
        )
    }

    private static func isIssueNumberOnlyTitle(_ title: String, issueNumber: String) -> Bool {
        func normalizedIssueNumber(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                .lowercased()
        }

        let normalizedTitle = normalizedIssueNumber(title)
        return !normalizedTitle.isEmpty && normalizedTitle == normalizedIssueNumber(issueNumber)
    }

    private static func seriesSequence(issueNumber: String?, numberSort: Double?) -> String? {
        guard let numberSort else { return issueNumber }
        if let issueNumber,
            let parsedNumber = Double(issueNumber.replacingOccurrences(of: ",", with: ".")),
            parsedNumber == numberSort
        {
            return issueNumber
        }
        return String(format: "%g", numberSort)
    }

    private struct KomgaLibrary: Decodable {
        let id: String
        let name: String
    }

    private struct KomgaPage<T: Decodable>: Decodable {
        let content: [T]
        let totalElements: Int
        let totalPages: Int
        let last: Bool?
    }

    private struct KomgaBook: Decodable {
        let id: String
        let seriesId: String
        let seriesTitle: String?
        let libraryId: String?
        let name: String
        let number: String?
        let created: Date?
        let lastModified: Date?
        let summary: String?
        let media: KomgaMedia?
        let metadata: KomgaMetadata?
        let readProgress: KomgaReadProgress?

        enum CodingKeys: String, CodingKey {
            case id, seriesId, seriesTitle, libraryId, name, number, created, lastModified, summary, media, metadata, readProgress
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            id = try Self.decodeFlexibleId(container, key: .id) ?? "unknown"
            seriesId = try Self.decodeFlexibleId(container, key: .seriesId) ?? ""
            libraryId = try Self.decodeFlexibleId(container, key: .libraryId)
            seriesTitle = try container.decodeIfPresent(String.self, forKey: .seriesTitle)
            number = try Self.decodeFlexibleId(container, key: .number)
            summary = try container.decodeIfPresent(String.self, forKey: .summary)
            media = try? container.decodeIfPresent(KomgaMedia.self, forKey: .media)
            metadata = try? container.decodeIfPresent(KomgaMetadata.self, forKey: .metadata)
            readProgress = try? container.decodeIfPresent(KomgaReadProgress.self, forKey: .readProgress)
            if let epoch = try? container.decode(String.self, forKey: .created) {
                created = Self.parseDate(epoch)
            } else {
                created = nil
            }
            if let value = try? container.decode(String.self, forKey: .lastModified) {
                lastModified = Self.parseDate(value)
            } else {
                lastModified = nil
            }
        }

        private static func decodeFlexibleId(_ container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> String? {
            if let s = try? container.decode(String.self, forKey: key) { return s }
            if let i = try? container.decode(Int.self, forKey: key) { return String(i) }
            return nil
        }

        private static func parseDate(_ value: String) -> Date? {
            if let date = ISO8601DateFormatter.enveKomgaFractional.date(from: value) {
                return date
            }
            return ISO8601DateFormatter.enveKomga.date(from: value)
        }
    }

    private struct KomgaSeries: Decodable {
        let id: String
        let name: String
        let booksCount: Int?
        let metadata: KomgaSeriesMetadata?
    }

    private struct KomgaSeriesMetadata: Decodable {
        let title: String?
    }

    private struct KomgaMedia: Decodable {
        let pagesCount: Int?
        let mediaType: String?
    }

    private struct KomgaReadProgress: Decodable {
        let page: Int
        let completed: Bool
        let readDate: Date?
        let created: Date?
        let lastModified: Date?

        enum CodingKeys: String, CodingKey {
            case page, completed, readDate, created, lastModified
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            page = try container.decodeIfPresent(Int.self, forKey: .page) ?? 0
            completed = try container.decodeIfPresent(Bool.self, forKey: .completed) ?? false
            readDate = Self.decodeDate(container, key: .readDate)
            created = Self.decodeDate(container, key: .created)
            lastModified = Self.decodeDate(container, key: .lastModified)
        }

        private static func decodeDate(
            _ container: KeyedDecodingContainer<CodingKeys>,
            key: CodingKeys
        ) -> Date? {
            guard let rawDate = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
            return ISO8601DateFormatter.enveKomgaFractional.date(from: rawDate)
                ?? ISO8601DateFormatter.enveKomga.date(from: rawDate)
        }
    }

    private struct KomgaMetadata: Decodable {
        let title: String?
        let summary: String?
        let number: String?
        let numberSort: Double?
        let authors: [KomgaAuthor]?
        let tags: [String]?
        let releaseDate: String?
    }

    private struct KomgaAuthor: Decodable {
        let name: String
        let role: String
    }

    private struct KomgaCollection: Decodable {
        let id: String
        let name: String
        let seriesIds: [String]?
    }

    private struct KomgaPageInfo: Decodable {
        let number: Int?
        let fileName: String?
        let mediaType: String?
        let width: Int?
        let height: Int?
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension ISO8601DateFormatter {
    static let enveKomga: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let enveKomgaFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
