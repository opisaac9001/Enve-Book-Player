import Foundation
import Logging

class KavitaProvider: IncrementalCatalogProvider, EbookProgressPushing, EbookDownloadProvider,
    @unchecked Sendable
{
    var connection: ServerConnection

    var capabilities: ProviderCapabilities {
        [
            .fullImport, .pagedImport,
            .recentBooks, .collections,
            .ebookProgressPush,
            .downloads, .coverAuthHeader, .backgroundOperation,
        ]
    }

    private let pageSize = 100
    private var jwtToken: String?
    private var pageCountCache: [String: Int] = [:]

    init(connection: ServerConnection) {
        self.connection = connection
        self.jwtToken = connection.token
    }

    func validateConnection() async throws -> Bool {
        try await ensureAuthenticated()
        let request = try makeRequest(path: "/api/Library/libraries")
        let (_, response) = try await send(request)
        return response.statusCode == 200
    }

    func fetchLibraries() async throws -> [Library] {
        try await ensureAuthenticated()
        let request = try makeRequest(path: "/api/Library/libraries")
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch libraries (HTTP \(response.statusCode))")
        }
        let libraries = try JSONDecoder().decode([KavitaLibrary].self, from: data)
        return libraries.map {
            let type: String
            switch $0.type {
            case 2: type = "book"
            case 4: type = "ebook"
            default: type = "book"
            }
            return Library(id: String($0.id), name: $0.name, type: type, providerId: connection.id)
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
        try await ensureAuthenticated()
        let firstPage = try await fetchCatalogPage(libraryId: libraryId, page: 0)
        return LibraryCatalogBatchSource.paged(
            firstPage: firstPage,
            pageSize: pageSize,
            pageConcurrency: 1,
            resumeAfter: resumeAfter,
            expectedSnapshotIdentifier: expectedSnapshotIdentifier,
            fetchPage: { try await self.fetchCatalogPage(libraryId: libraryId, page: $0) }
        )
    }

    private func fetchCatalogPage(libraryId: String, page: Int) async throws -> LibraryCatalogPage {
        guard let libraryId = Int(libraryId) else { throw ProviderError.invalidResponse }
        let body: [String: Any] = [
            "libraryIds": [libraryId],
            "pageNumber": page,
            "pageSize": pageSize,
            "sortOptions": ["sortField": 5, "isAscending": false],
        ]
        var request = try makeRequest(path: "/api/Series/v2")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch series (HTTP \(response.statusCode))")
        }
        let result = try JSONDecoder().decode([KavitaSeries].self, from: data)
        return LibraryCatalogPage(
            books: result.map { mapToBook($0, libraryId: String(libraryId)) },
            totalCount: nil,
            isLast: result.count < pageSize
        )
    }

    func fetchRecentBooks(libraryId: String, limit: Int) async throws -> [Book] {
        try await ensureAuthenticated()
        let request = try makeRequest(path: "/api/Series/recently-added-v2")
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            return []
        }
        let result = try JSONDecoder().decode([KavitaSeries].self, from: data)
        return Array(result.prefix(limit).map { mapToBook($0, libraryId: libraryId) })
    }

    func fetchCollections(libraryId: String?) async throws -> [Collection] {
        try await ensureAuthenticated()
        let request = try makeRequest(path: "/api/Collection")
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else { return [] }
        let tags = try JSONDecoder().decode([KavitaCollectionTag].self, from: data)
        return tags.map { tag in
            let bookIds = tag.seriesMetadatas?.map { String($0.id) } ?? []
            return Collection(
                id: String(tag.id),
                name: tag.title,
                description: tag.summary,
                books: bookIds,
                bookCount: bookIds.count,
                iconName: "books.vertical",
                color: "green",
                providerId: connection.id
            )
        }
    }
    func fetchSeries(libraryId: String) async throws -> [Series] { [] }
    func fetchUserMediaProgress(libraryId: String) async throws -> [UserMediaProgress] { [] }

    func fetchFullBookDetails(bookId: String, libraryId: String) async throws -> Book {
        try await ensureAuthenticated()
        guard let seriesId = Int(bookId) else {
            throw ProviderError.invalidURL
        }
        let request = try makeRequest(path: "/api/Series/\(seriesId)")
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch series details (HTTP \(response.statusCode))")
        }
        let series = try JSONDecoder().decode(KavitaSeriesDetail.self, from: data)
        return Book(
            id: String(series.id),
            title: series.name,
            author: nil,
            narrator: nil,
            seriesInfo: nil,
            duration: 0,
            coverURL: coverURL(seriesId: series.id),
            mediaType: .ebook,
            description: series.summary,
            genres: [],
            chapters: [],
            publisher: nil,
            progress: 0,
            currentTime: 0,
            isFinished: false,
            lastUpdate: Date(),
            libraryId: libraryId,
            providerId: connection.id,
            source: .kavita,
            rawMetadata: nil
        )
    }

    func getAudioURL(for book: Book) -> URL? { nil }
    func getStreamingHeaders() -> [String: String] {
        guard let token = jwtToken else { return [:] }
        return ["Authorization": "Bearer \(token)"]
    }

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

        try await ensureAuthenticated()
        guard let seriesId = Int(book.id) else { throw ProviderError.invalidURL }
        let volumesReq = try makeRequest(path: "/api/Series/volumes?seriesId=\(seriesId)")
        let (volData, volResp) = try await send(volumesReq)
        guard volResp.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch volumes (HTTP \(volResp.statusCode))")
        }
        let volumes = try JSONDecoder().decode([KavitaVolume].self, from: volData)
        guard let firstChapter = volumes.first?.chapters?.first else {
            throw ProviderError.serverError("No chapters found for download")
        }
        let downloadReq = try makeRequest(path: "/api/Download/chapter?chapterId=\(firstChapter.id)")

        let progressHandler: @Sendable (Double) -> Void = onProgress ?? { _ in }
        let delegate = URLSessionDownloadProgressDelegate(progressHandler: progressHandler)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 3600
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (tempURL, httpResponse) = try await delegate.awaitResult {
            session.downloadTask(with: downloadReq)
        }
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
    }

    func updateEbookProgress(for book: Book, progress: Double, epubLocator: String?) async throws {
        try await ensureAuthenticated()
        guard let seriesId = Int(book.id) else { return }
        let totalPages = try await resolvePageCount(for: book)
        let body: [String: Any] = [
            "seriesId": seriesId,
            "pagesRead": max(1, Int(progress * Double(totalPages))),
        ]
        var request = try makeRequest(path: "/api/Reader/progress")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await send(request)
        guard (200...299).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to update progress (HTTP \(response.statusCode))")
        }
    }

    private func resolvePageCount(for book: Book) async throws -> Int {
        if let cached = pageCountCache[book.id] { return cached }
        guard let seriesId = Int(book.id) else {
            throw ProviderError.serverError("Invalid series ID for Kavita page count")
        }
        let request = try makeRequest(path: "/api/Series/\(seriesId)")
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Could not fetch Kavita page count (HTTP \(response.statusCode))")
        }
        let detail = try JSONDecoder().decode(KavitaSeriesPageInfo.self, from: data)
        guard detail.pages > 0 else {
            throw ProviderError.serverError("Kavita returned zero pages for series \(seriesId)")
        }
        pageCountCache[book.id] = detail.pages
        return detail.pages
    }

    func ensureAuthenticated() async throws {
        if jwtToken != nil { return }
        guard let username = connection.username, !username.isEmpty,
            let password = connection.password, !password.isEmpty
        else {
            if let apiKey = connection.token, !apiKey.isEmpty {
                jwtToken = apiKey
                return
            }
            throw ProviderError.unauthorized
        }
        let loginBody: [String: String] = ["username": username, "password": password]
        var request = try makeUnauthRequest(path: "/api/Account/login")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(loginBody)
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw ProviderError.unauthorized
        }
        let loginResponse = try JSONDecoder().decode(KavitaLoginResponse.self, from: data)
        jwtToken = loginResponse.token
        connection.token = loginResponse.token
    }

    func makeRequest(path: String, queryItems: [URLQueryItem] = []) throws -> URLRequest {
        var request = try makeUnauthRequest(path: path, queryItems: queryItems)
        if let token = jwtToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func makeUnauthRequest(path: String, queryItems: [URLQueryItem] = []) throws -> URLRequest {
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
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }
        return (data, httpResponse)
    }

    private func normalize(_ urlString: String) -> String {
        var str = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasSuffix("/") { str.removeLast() }
        if !str.hasPrefix("http") { str = "http://\(str)" }
        return str
    }

    private func coverURL(seriesId: Int) -> URL? {
        let base = normalize(connection.url)
        return URL(string: "\(base)/api/image/series-cover?seriesId=\(seriesId)")
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

    private func mapToBook(_ series: KavitaSeries, libraryId: String) -> Book {
        let author = series.writers?.first
        return Book(
            id: String(series.id),
            title: series.name,
            author: author,
            narrator: nil,
            seriesInfo: nil,
            duration: 0,
            coverURL: coverURL(seriesId: series.id),
            mediaType: .ebook,
            description: series.summary,
            genres: [],
            chapters: [],
            publisher: nil,
            progress: 0,
            currentTime: 0,
            isFinished: false,
            lastUpdate: series.created.flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date(),
            libraryId: libraryId,
            providerId: connection.id,
            source: .kavita,
            rawMetadata: nil
        )
    }

    private struct KavitaLoginResponse: Decodable {
        let token: String
        let username: String?
    }

    private struct KavitaLibrary: Decodable {
        let id: Int
        let name: String
        let type: Int
    }

    private struct KavitaSeries: Decodable {
        let id: Int
        let name: String
        let summary: String?
        let writers: [String]?
        let created: String?
        let libraryId: Int?
        let pagesRead: Int?
        let pages: Int?
    }

    private struct KavitaSeriesDetail: Decodable {
        let id: Int
        let name: String
        let summary: String?
    }

    private struct KavitaSeriesPageInfo: Decodable {
        let pages: Int
    }

    private struct KavitaVolume: Decodable {
        let id: Int
        let chapters: [KavitaChapter]?
    }

    private struct KavitaChapter: Decodable {
        let id: Int
        let title: String?
    }

    private struct KavitaCollectionTag: Decodable {
        let id: Int
        let title: String
        let summary: String?
        let seriesMetadatas: [KavitaSeriesRef]?

        struct KavitaSeriesRef: Decodable {
            let id: Int
        }
    }
}
