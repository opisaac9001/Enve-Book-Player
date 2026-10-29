import Foundation
import Logging

class KavitaProvider: IncrementalCatalogProvider, EbookProgressProvider, EbookDownloadProvider,
    ServerPageProvider, @unchecked Sendable
{
    var connection: ServerConnection
    private let isolatesCredentials: Bool
    private let certificateTransport: InsecureURLSession

    var capabilities: ProviderCapabilities {
        [
            .fullImport, .pagedImport,
            .recentBooks, .series, .collections,
            .ebookProgressPull, .ebookProgressPush,
            .downloads, .coverAuthHeader, .serverPageStreaming, .backgroundOperation,
        ]
    }

    var catalogMappingRevision: Int { 2 }

    private let pageSize = 100
    private var jwtToken: String?
    private var imageAPIKey: String?
    private var streamedChapter: (bookId: String, chapterId: Int, pageCount: Int)?
    private var libraryTypes: [String: Int]?

    var statsLibraries: [Int]?

    private let networkSession: URLSession
    private let ebooks: LocalEbookImporter
    private let rejectedContent: RejectedContentStore
    private let issueIdentities: KavitaIssueIdentityStore

    init(connection: ServerConnection, profileSession: ProfileSession? = nil) {
        issueIdentities = KavitaIssueIdentityStore(defaults: profileSession?.defaults ?? .standard)
        networkSession = profileSession?.networkSession ?? .shared
        ebooks = profileSession?.ebooks ?? .shared
        rejectedContent = profileSession?.rejectedContent ?? .shared
        self.connection = connection
        isolatesCredentials = profileSession?.isOwner == false
        certificateTransport = profileSession?.transport ?? .delegateInstance
        self.jwtToken = connection.token
        if let token = connection.token, token.split(separator: ".").count != 3 {
            imageAPIKey = token
        }
    }

    func validateConnection() async throws -> Bool {
        try EnveProvenance.checkServerAddress(connection.url)
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
        libraryTypes = Dictionary(libraries.map { (String($0.id), $0.type) }, uniquingKeysWith: { _, last in last })
        return libraries.map {
            let type: String
            switch $0.type {
            case 2: type = "book"
            case 4: type = "ebook"
            default: type = "comic"
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
            "statements": [["field": 19, "comparison": 0, "value": String(libraryId)]],
            "combination": 0,
            "sortOptions": ["sortField": 5, "isAscending": false],
        ]
        var request = try makeRequest(path: "/api/Series/v2", queryItems: [
            URLQueryItem(name: "pageNumber", value: String(page + 1)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
        ])
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch series (HTTP \(response.statusCode))")
        }
        let result = try JSONDecoder().decode(LossyDecodableArray<KavitaSeries>.self, from: data)
        rejectedContent.update(
            connection: connection,
            libraryId: String(libraryId),
            acceptedItemIdentifiers: Set(result.values.map { String($0.id) }),
            rejectedItems: result.rejectedItems,
            fallbackScope: "page-\(page)"
        )
        return LibraryCatalogPage(
            books: try await issueBooks(for: result.values, libraryId: String(libraryId)),
            totalCount: nil,
            isLast: result.values.count + result.rejectedItems.count < pageSize,
            isComplete: result.rejectedItems.isEmpty
        )
    }

    func fetchRecentBooks(libraryId: String, limit: Int) async throws -> [Book] {
        try await ensureAuthenticated()
        guard let libraryId = Int(libraryId) else { throw ProviderError.invalidResponse }
        var request = try makeRequest(path: "/api/Series/recently-added-v2", queryItems: [
            URLQueryItem(name: "pageNumber", value: "1"),
            URLQueryItem(name: "pageSize", value: String(max(1, limit))),
        ])
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "statements": [["field": 19, "comparison": 0, "value": String(libraryId)]],
            "combination": 0,
        ])
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch recent series (HTTP \(response.statusCode))")
        }
        let result = try JSONDecoder().decode(LossyDecodableArray<KavitaSeries>.self, from: data)
        rejectedContent.update(
            connection: connection,
            libraryId: String(libraryId),
            acceptedItemIdentifiers: Set(result.values.map { String($0.id) }),
            rejectedItems: result.rejectedItems,
            fallbackScope: "recent"
        )
        return Array(try await issueBooks(for: Array(result.values.prefix(limit)), libraryId: String(libraryId)).prefix(limit))
    }

    func fetchCollections(libraryId: String?) async throws -> [Collection] {
        try await ensureAuthenticated()
        let request = try makeRequest(path: "/api/Collection")
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else { return [] }
        let tags = try JSONDecoder().decode([KavitaCollectionTag].self, from: data)
        var collections: [Collection] = []
        for tag in tags {
            var bookIds: [String] = []
            for reference in tag.seriesMetadatas ?? [] {
                let series = try await fetchSeriesDetails(id: reference.id)
                bookIds += try await issueBooks(for: [series], libraryId: libraryId ?? series.libraryId.map(String.init) ?? "").map(\.id)
            }
            collections.append(Collection(
                id: String(tag.id),
                name: tag.title,
                description: tag.summary,
                books: bookIds,
                bookCount: bookIds.count,
                iconName: "books.vertical",
                color: "green",
                providerId: connection.id
            ))
        }
        return collections
    }

    func fetchSeries(libraryId: String) async throws -> [Series] {
        let books = try await fetchBooks(libraryId: libraryId)
        return Dictionary(grouping: books, by: { String($0.id.split(separator: ":")[0]) }).map { seriesId, issues in
            Series(id: "kavita-series-\(seriesId)", name: issues[0].seriesInfo!.name,
                   description: nil, books: issues.map(\.id),
                   bookSequences: Dictionary(uniqueKeysWithValues: issues.compactMap { book in book.seriesInfo?.sequence.map { (book.id, $0) } }),
                   bookCount: issues.count, libraryId: libraryId, providerId: connection.id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func fetchUserMediaProgress(libraryId: String) async throws -> [UserMediaProgress] { [] }

    func fetchFullBookDetails(bookId: String, libraryId: String) async throws -> Book {
        try await ensureAuthenticated()
        let reference = try KavitaBookReference(bookId)
        let series = try await fetchSeriesDetails(id: reference.seriesId)
        let issues = try await issueBooks(for: [series], libraryId: libraryId, bookId: bookId)
        guard let book = issues.first(where: { $0.id == bookId }) else { throw ProviderError.invalidResponse }
        return book
    }

    private func fetchSeriesDetails(id: Int) async throws -> KavitaSeries {
        let (data, response) = try await send(makeRequest(path: "/api/Series/\(id)"))
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch Kavita series (HTTP \(response.statusCode))")
        }
        return try JSONDecoder().decode(KavitaSeries.self, from: data)
    }

    func getAudioURL(for book: Book) -> URL? { nil }
    func getStreamingHeaders() -> [String: String] {
        guard let token = jwtToken else { return [:] }
        return ["Authorization": "Bearer \(token)"]
    }

    func fetchPageCount(for book: Book) async throws -> Int {
        _ = try await imageAuthenticationKey()
        if let metadata = book.comicMetadata, let count = metadata.pageCount, count > 0,
            let chapterID = metadata.resourceID.flatMap(Int.init) {
            streamedChapter = (book.id, chapterID, count)
            return count
        }
        if let streamedChapter, streamedChapter.bookId == book.id { return streamedChapter.pageCount }
        let (_, chapter) = try await readingChapter(for: book)
        streamedChapter = (book.id, chapter.id, chapter.pages)
        return chapter.pages
    }

    func fetchPage(_ pageNumber: Int, for book: Book) async throws -> Data {
        let imageKey = try await imageAuthenticationKey()
        let chapterId: Int
        if let streamedChapter, streamedChapter.bookId == book.id {
            chapterId = streamedChapter.chapterId
        } else if let chapterID = book.comicMetadata?.resourceID.flatMap(Int.init) {
            chapterId = chapterID
        } else {
            let (_, chapter) = try await readingChapter(for: book)
            chapterId = chapter.id
        }
        // The image endpoint requires an API-key query parameter even for password connections.
        var request = try makeRequest(path: "/api/Reader/image", queryItems: [
            URLQueryItem(name: "chapterId", value: String(chapterId)),
            URLQueryItem(name: "page", value: String(pageNumber - 1)),
            URLQueryItem(name: "apiKey", value: imageKey),
        ])
        request.setValue("image/jpeg, image/png, image/webp, */*", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch Kavita page (HTTP \(response.statusCode))")
        }
        return data
    }

    private func imageAuthenticationKey() async throws -> String {
        try await ensureAuthenticated()
        if let imageAPIKey, !imageAPIKey.isEmpty { return imageAPIKey }
        let (data, response) = try await send(makeRequest(path: "/api/Account"))
        guard response.statusCode == 200 else { throw ProviderError.unauthorized }
        let credentials = try JSONDecoder().decode(KavitaImageCredentials.self, from: data)
        guard !credentials.apiKey.isEmpty else { throw ProviderError.invalidResponse }
        imageAPIKey = credentials.apiKey
        return credentials.apiKey
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
        if let cached = ebooks.cachedEbook(forBookId: book.id) {
            onProgress?(1)
            return cached
        }

        let (_, chapter) = try await readingChapter(for: book)
        let downloadReq = try makeRequest(path: "/api/Download/chapter?chapterId=\(chapter.id)")

        let progressHandler: @Sendable (Double) -> Void = onProgress ?? { _ in }
        let delegate = URLSessionDownloadProgressDelegate(progressHandler: progressHandler, certificateTransport: certificateTransport)
        let config: URLSessionConfiguration = isolatesCredentials ? .ephemeral : .default
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
        return try ebooks.cacheRemoteEbook(
            tempURL: tempURL,
            preferredFilename: filename,
            bookIdentifier: book.id
        )
    }

    func updateEbookProgress(for book: Book, progress: Double, epubLocator: String?) async throws {
        let (volume, chapter) = try await readingChapter(for: book)
        let seriesId = try KavitaBookReference(book.id).seriesId
        guard let libraryId = Int(book.libraryId) else { throw ProviderError.invalidResponse }
        let clamped = max(0, min(1, progress))
        // Kavita only counts a chapter as read once the last page is reported.
        let pageNum = clamped >= Book.finishedProgressThreshold ? chapter.pages : Int((clamped * Double(chapter.pages)).rounded())
        let body: [String: Any] = [
            "seriesId": seriesId,
            "libraryId": libraryId,
            "volumeId": volume.id,
            "chapterId": chapter.id,
            "pageNum": pageNum,
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

    func fetchEbookProgress(for book: Book) async throws -> (progress: Double, locator: String?, updatedAt: Date?, isFinished: Bool)? {
        let (_, chapter) = try await readingChapter(for: book)
        let request = try makeRequest(path: "/api/Reader/get-progress?chapterId=\(chapter.id)")
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch Kavita progress (HTTP \(response.statusCode))")
        }
        let progress = try JSONDecoder().decode(KavitaReadingProgress.self, from: data)
        let fraction = max(0, min(1, Double(progress.pageNum) / Double(chapter.pages)))
        return (progress: fraction, locator: nil, updatedAt: progress.lastModifiedUtc.flatMap(KavitaDate.parse), isFinished: fraction >= Book.finishedProgressThreshold)
    }

    private func readingChapter(for book: Book) async throws -> (KavitaVolume, KavitaChapter) {
        try await ensureAuthenticated()
        let reference = try KavitaBookReference(book.id)
        let volumes = try await fetchVolumes(seriesId: reference.seriesId)
        let chapterId: Int
        if let requested = reference.chapterId {
            chapterId = requested
        } else {
            guard let first = volumes.lazy.compactMap({ $0.chapters?.first }).first else { throw ProviderError.invalidResponse }
            chapterId = issueIdentities.legacyChapterId(connectionId: connection.id, seriesId: reference.seriesId, firstChapterId: first.id)
        }
        for volume in volumes where reference.volumeId == nil || reference.volumeId == volume.id {
            if let chapter = volume.chapters?.first(where: { $0.id == chapterId }), chapter.pages > 0 {
                return (volume, chapter)
            }
        }
        throw ProviderError.serverError("This Kavita issue is no longer available")
    }

    private func fetchVolumes(seriesId: Int) async throws -> [KavitaVolume] {
        let request = try makeRequest(path: "/api/Series/volumes?seriesId=\(seriesId)")
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch Kavita volumes (HTTP \(response.statusCode))")
        }
        return try JSONDecoder().decode([KavitaVolume].self, from: data)
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
            if response.statusCode == 401 { throw ProviderError.unauthorized }
            throw ProviderError.serverError("Kavita login failed (HTTP \(response.statusCode))")
        }
        let loginResponse = try JSONDecoder().decode(KavitaLoginResponse.self, from: data)
        jwtToken = loginResponse.token
        imageAPIKey = loginResponse.apiKey
        connection.token = loginResponse.token
    }

    func makeRequest(path: String, queryItems: [URLQueryItem] = []) throws -> URLRequest {
        let request = try makeUnauthRequest(path: path, queryItems: queryItems)
        return authenticatedRequest(from: request)
    }

    func fetchCoverImage(url: URL) async throws -> Data {
        try await ensureAuthenticated()
        let (data, response) = try await send(authenticatedRequest(from: URLRequest(url: url)))
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch Kavita cover (HTTP \(response.statusCode))")
        }
        return data
    }

    private func authenticatedRequest(from request: URLRequest) -> URLRequest {
        var request = request
        if usesPasswordLogin {
            if let jwtToken {
                request.setValue("Bearer \(jwtToken)", forHTTPHeaderField: "Authorization")
            }
        } else if let token = jwtToken, !token.isEmpty {
            if token.split(separator: ".").count == 3 {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            } else {
                request.setValue(token, forHTTPHeaderField: "X-API-Key")
            }
        }
        return request
    }

    private var usesPasswordLogin: Bool {
        connection.username?.isEmpty == false && connection.password?.isEmpty == false
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
        let (data, response) = try await networkSession.data(for: request)
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
        // Kavita serves image-folder chapters as an octet-stream `.zip` of the pages.
        if normalized.hasSuffix(".zip") { return EbookFormat.cbz.rawValue }
        for ext in EbookFormat.allExtensions where normalized.contains(".\(ext)") {
            return ext
        }
        return nil
    }

    private func issueBooks(for seriesList: [KavitaSeries], libraryId: String, bookId: String? = nil) async throws -> [Book] {
        let volumesByIndex = try await withThrowingTaskGroup(of: (Int, [KavitaVolume]).self) { group in
            var volumes = Array(repeating: [KavitaVolume](), count: seriesList.count)
            var nextIndex = 0
            for index in 0..<min(6, seriesList.count) {
                group.addTask { (index, try await self.fetchVolumes(seriesId: seriesList[index].id)) }
                nextIndex += 1
            }
            while let (index, result) = try await group.next() {
                volumes[index] = result
                if nextIndex < seriesList.count {
                    let next = nextIndex
                    group.addTask { (next, try await self.fetchVolumes(seriesId: seriesList[next].id)) }
                    nextIndex += 1
                }
            }
            return volumes
        }
        let legacyChapterIds = issueIdentities.legacyChapterIds(
            connectionId: connection.id,
            firstChapters: seriesList.enumerated().compactMap { index, series in
                volumesByIndex[index].lazy.compactMap { $0.chapters?.first }.first.map { (series.id, $0.id) }
            }
        )
        if libraryTypes == nil {
            _ = try? await fetchLibraries()
            if libraryTypes == nil { libraryTypes = [:] }
        }
        let types = libraryTypes ?? [:]
        var books: [Book] = []
        for (index, series) in seriesList.enumerated() {
            let volumes = volumesByIndex[index]
            guard let legacyChapterId = legacyChapterIds[series.id] else {
                throw ProviderError.serverError("Kavita returned a series without readable issues")
            }
            let libraryType = types[series.libraryId.map(String.init) ?? libraryId]
            let chapterCount = volumes.reduce(0) { $0 + ($1.chapters?.count ?? 0) }
            for volume in volumes {
                for chapter in volume.chapters ?? [] where chapter.pages > 0 {
                    let id = chapter.id == legacyChapterId
                        ? String(series.id) : "\(series.id):\(volume.id):\(chapter.id)"
                    if let bookId {
                        guard id == bookId else { continue }
                        streamedChapter = (id, chapter.id, chapter.pages)
                    }
                    let sequence = chapter.range ?? chapter.number
                    let number = sequence.flatMap { $0.isEmpty || $0 == "-100000" ? nil : $0 }
                    let volumeName = volume.name.flatMap { $0.isEmpty || $0 == "-100000" || $0 == "0" ? nil : $0 }
                    let label: String
                    if let name = chapter.titleName, !name.isEmpty {
                        label = name
                    } else if let number {
                        label = "Issue \(number)"
                    } else if let volumeName {
                        label = "Volume \(volumeName)"
                    } else if let name = chapter.title, !name.isEmpty {
                        label = name
                    } else {
                        label = "Issue \(chapter.id)"
                    }
                    let issueLabel: String
                    if volumes.count > 1, let volumeName {
                        issueLabel = "Volume \(volumeName) · \(label)"
                    } else {
                        issueLabel = label
                    }
                    let fileFormat = chapter.files?.first?.format ?? series.format
                    let format: String?
                    switch fileFormat {
                    case 0, 1: format = EbookFormat.cbz.rawValue
                    case 3: format = EbookFormat.epub.rawValue
                    case 4: format = EbookFormat.pdf.rawValue
                    default: format = nil
                    }
                    let progress = max(0, min(1, Double(chapter.pagesRead ?? 0) / Double(chapter.pages)))
                    let comicMetadata = Self.comicMetadata(
                        seriesId: series.id,
                        libraryType: libraryType,
                        format: format,
                        volume: volume,
                        volumeName: volumeName,
                        chapter: chapter,
                        issueLabel: label
                    )
                    let displayLabel = comicMetadata?.section == .specials ? (comicMetadata?.issueLabel ?? label) : issueLabel
                    let title = chapterCount == 1 ? series.name : "\(series.name) · \(displayLabel)"
                    books.append(Book(
                        id: id, title: title, author: series.writers?.first, narrator: nil,
                        seriesInfo: SeriesInfo(name: series.name, sequence: number ?? volumeName),
                        duration: 0,
                        coverURL: URL(string: "\(normalize(connection.url))/api/image/chapter-cover?chapterId=\(chapter.id)"),
                        mediaType: .ebook, ebookFormat: format, comicMetadata: comicMetadata,
                        description: chapter.summary ?? series.summary, genres: [], chapters: [], publisher: nil,
                        progress: 0, currentTime: 0, isFinished: progress >= Book.finishedProgressThreshold,
                        lastUpdate: .distantPast, libraryId: series.libraryId.map(String.init) ?? libraryId,
                        providerId: connection.id, source: .kavita, rawMetadata: nil
                    ))
                    books[books.count - 1].ebookProgress = progress
                }
            }
        }
        return books
    }

    // Kavita uses -100000 for loose leaf, 100000 for specials and type 5 for flat ComicVine runs.
    private static func comicMetadata(
        seriesId: Int,
        libraryType: Int?,
        format: String?,
        volume: KavitaVolume,
        volumeName: String?,
        chapter: KavitaChapter,
        issueLabel: String
    ) -> ComicMetadata? {
        guard let libraryType, libraryType != 2, libraryType != 4,
            format == EbookFormat.cbz.rawValue || format == EbookFormat.pdf.rawValue
        else { return nil }
        let volumeNumber = volume.minNumber ?? volume.number
        let issueOrder = (chapter.sortOrder ?? chapter.minNumber).flatMap { $0 == -100_000 ? nil : $0 }
        if chapter.isSpecial == true || volumeNumber == 100_000 {
            let specialLabel = [chapter.titleName, chapter.title].lazy.compactMap { $0 }.first { !$0.isEmpty }
            return ComicMetadata(
                seriesID: String(seriesId),
                section: .specials,
                issueLabel: specialLabel ?? issueLabel,
                issueOrder: issueOrder, pageCount: chapter.pages, resourceID: String(chapter.id)
            )
        }
        // Strict Comic libraries use the volume as the run or year, so issues stay flat.
        guard libraryType != 5, let volumeNumber, volumeNumber > 0 else {
            return ComicMetadata(seriesID: String(seriesId), section: .issues, issueLabel: issueLabel, issueOrder: issueOrder, pageCount: chapter.pages, resourceID: String(chapter.id))
        }
        return ComicMetadata(
            seriesID: String(seriesId),
            section: .volumes,
            volumeID: String(volume.id),
            volumeTitle: "Volume \(volumeName ?? String(format: "%g", volumeNumber))",
            volumeOrder: volumeNumber,
            issueLabel: issueLabel,
            issueOrder: issueOrder, pageCount: chapter.pages, resourceID: String(chapter.id)
        )
    }

    private struct KavitaLoginResponse: Decodable {
        let token: String
        let apiKey: String?
    }

    private struct KavitaImageCredentials: Decodable {
        let apiKey: String
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
        let libraryId: Int?
        let pagesRead: Int?
        let pages: Int?
        let format: Int?
    }

    private struct KavitaVolume: Decodable, Sendable {
        let id: Int
        let name: String?
        let minNumber: Double?
        let number: Double?
        let chapters: [KavitaChapter]?
    }

    private struct KavitaChapter: Decodable, Sendable {
        let id: Int
        let title: String?
        let titleName: String?
        let range: String?
        let number: String?
        let minNumber: Double?
        let sortOrder: Double?
        let isSpecial: Bool?
        let pages: Int
        let pagesRead: Int?
        let summary: String?
        let files: [KavitaFile]?
    }

    private struct KavitaFile: Decodable, Sendable {
        let format: Int?
    }

    private struct KavitaReadingProgress: Decodable {
        let pageNum: Int
        let lastModifiedUtc: String?
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

private struct KavitaBookReference {
    let seriesId: Int
    let volumeId: Int?
    let chapterId: Int?

    init(_ id: String) throws {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard (parts.count == 1 || parts.count == 3),
              let series = Int(parts[0]), series > 0 else { throw ProviderError.invalidResponse }
        seriesId = series
        if parts.count == 3 {
            guard let volume = Int(parts[1]), volume > 0,
                  let chapter = Int(parts[2]), chapter > 0 else { throw ProviderError.invalidResponse }
            volumeId = volume
            chapterId = chapter
        } else {
            volumeId = nil
            chapterId = nil
        }
    }
}
