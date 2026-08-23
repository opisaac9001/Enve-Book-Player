import AVFoundation
import Foundation
import Logging

#if canImport(UIKit)
import UIKit
#endif

class EmbyProvider: IncrementalCatalogProvider, PlaybackSessionProvider, AudiobookProgressProvider,
    EbookDownloadProvider, @unchecked Sendable
{
    var connection: ServerConnection

    var capabilities: ProviderCapabilities {
        [
            .fullImport, .pagedImport,
            .audiobookProgressPull, .audiobookProgressPush,
            .downloads, .coverAuthHeader, .backgroundOperation,
        ]
    }

    private let session = URLSession.shared

    static var shared: EmbyProvider = {
        let defaultConnection = ServerConnection(
            name: "Default",
            url: "",
            type: .emby
        )
        return EmbyProvider(connection: defaultConnection)
    }()

    init(connection: ServerConnection) {
        self.connection = connection
    }

    @discardableResult
    func authenticate(serverURL: String, username: String, password: String) async throws -> String {
        self.connection = ServerConnection(
            name: connection.name,
            url: serverURL,
            type: .emby,
            customHeaders: connection.customHeaders
        )
        try await authenticate(username: username, password: password)
        AppLogger.network.info(
            "[EmbyProvider] Authentication complete for: \(URL(string: serverURL)?.redacted.absoluteString ?? "<invalid>")"
        )
        guard let token = connection.token, !token.isEmpty else {
            throw ProviderError.unauthorized
        }
        return token
    }

    private var clientName: String { "Enve" }
    private var clientVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    private var deviceId: String {
        #if canImport(UIKit)
        return UIDevice.current.identifierForVendor?.uuidString ?? StorageService.shared.loadDeviceUUID()
        #else
        return StorageService.shared.loadDeviceUUID()
        #endif
    }
    private var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
        #elseif os(macOS)
        return (Host.current().localizedName ?? "Mac").replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
        #else
        return "Enve Client"
        #endif
    }

    public static func normalizeServerURL(_ input: String) -> String {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if trimmed.isEmpty { return input }

        if !trimmed.lowercased().hasPrefix("http") {
            if trimmed.contains("8920") {
                trimmed = "https://\(trimmed)"
            } else {
                trimmed = "http://\(trimmed)"
            }
        }

        return trimmed
    }

    private func buildAuthHeader(includeToken: Bool = true) -> String {
        var header =
            "MediaBrowser Client=\"\(clientName)\", Device=\"\(deviceName)\", DeviceId=\"\(deviceId)\", Version=\"\(clientVersion)\""
        if includeToken, let token = connection.token {
            header += ", Token=\"\(token)\""
        }
        return header
    }

    private func addAuthHeaders(_ request: inout URLRequest) {
        request.setValue(buildAuthHeader(), forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyCustomHeaders(to: &request)
    }

    private func applyCustomHeaders(to request: inout URLRequest) {
        if let customHeaders = connection.customHeaders {
            for (key, value) in customHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
    }

    func validateConnection() async throws -> Bool {
        if connection.token != nil && connection.userId != nil {
            return try await checkSystemInfo()
        }

        guard let username = connection.username,
            let password = connection.password ?? connection.token
        else {
            throw ProviderError.unauthorized
        }

        do {
            try await authenticate(username: username, password: password)
            return true
        } catch {
            AppLogger.network.error("Authentication failed: \(error)")
            throw ProviderError.unauthorized
        }
    }

    private func checkSystemInfo() async throws -> Bool {
        let base = EmbyProvider.normalizeServerURL(connection.url)
        guard let url = URL(string: "\(base)/System/Info/Public") else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        applyCustomHeaders(to: &request)

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return false
        }
        return true
    }

    private func authenticate(username: String, password: String) async throws {
        let base = Self.normalizeServerURL(connection.url)
        guard let authURL = URL(string: "\(base)/Users/AuthenticateByName") else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: authURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(buildAuthHeader(includeToken: false), forHTTPHeaderField: "X-Emby-Authorization")
        applyCustomHeaders(to: &request)

        let body = ["Username": username, "Pw": password]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ProviderError.unauthorized
        }

        struct AuthResponse: Decodable {
            let AccessToken: String
            let User: User
            struct User: Decodable {
                let Id: String
            }
        }

        let result = try JSONDecoder().decode(AuthResponse.self, from: data)

        self.connection.token = result.AccessToken
        self.connection.userId = result.User.Id
        self.connection.url = base
        self.connection.username = username

        do {
            try SecureTokenStorage.shared.saveCredentials(
                serverUrl: base,
                username: username,
                token: result.AccessToken,
                forService: "emby"
            )
        } catch {
            AppLogger.network.error("[Emby] Failed to save credentials to secure storage: \(error.localizedDescription)")
        }
    }

    func fetchLibraries() async throws -> [Library] {
        guard let userId = connection.userId else { throw ProviderError.unauthorized }
        let base = EmbyProvider.normalizeServerURL(connection.url)

        guard let url = URL(string: "\(base)/Users/\(userId)/Views") else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        addAuthHeaders(&request)

        AppLogger.network.info("fetchLibraries URL: \(url.redacted)")
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            AppLogger.network.error("fetchLibraries failed with status: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            throw ProviderError.invalidResponse
        }

        let result = try JSONDecoder().decode(EmbyItemsResponse.self, from: data)
        AppLogger.network.info("fetchLibraries found \(result.Items.count) total views")

        let libraries: [Library] = result.Items.compactMap { item in
            let collectionType = item.CollectionType ?? ""
            AppLogger.network.info("View: \(item.Name), ID: \(item.Id), CollectionType: \(collectionType)")
            guard collectionType == "books" || collectionType == "audiobooks" else { return nil }
            return Library(id: item.Id, name: item.Name, type: collectionType, providerId: connection.id)
        }
        return libraries
    }

    func fetchBooks(libraryId: String) async throws -> [Book] {
        guard let userId = connection.userId else { throw ProviderError.unauthorized }
        let base = EmbyProvider.normalizeServerURL(connection.url)

        let pageSize = 500
        var startIndex = 0
        var totalRecordCount: Int? = nil
        var allItems: [EmbyItem] = []
        var iterationCeiling = 5_000
        var iter = 0

        while iter < iterationCeiling {
            iter += 1
            guard var components = URLComponents(string: "\(base)/Users/\(userId)/Items") else { throw ProviderError.invalidURL }
            components.queryItems = [
                URLQueryItem(name: "ParentId", value: libraryId),

                URLQueryItem(name: "IncludeItemTypes", value: "Book,MusicAlbum"),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(
                    name: "Fields",
                    value:
                        "Overview,MediaSources,RunTimeTicks,ParentId,ChildCount,ProductionYear,AlbumArtist,AlbumArtists,ArtistItems,SeriesName,IndexNumber,Studios,Genres,UserData,People,Path,Chapters,ImageTags,PrimaryImageItemId,PrimaryImageTag,ParentPrimaryImageItemId,ParentPrimaryImageTag,AlbumId,AlbumPrimaryImageTag"
                ),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending"),
                URLQueryItem(name: "StartIndex", value: String(startIndex)),
                URLQueryItem(name: "Limit", value: String(pageSize)),
            ]
            guard let requestURL = components.url else { throw ProviderError.invalidURL }
            var request = URLRequest(url: requestURL)
            addAuthHeaders(&request)
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                AppLogger.network.error(
                    "[Emby] fetchBooks page startIndex=\(startIndex) failed with status: \((response as? HTTPURLResponse)?.statusCode ?? -1)"
                )
                throw ProviderError.invalidResponse
            }
            let result = try JSONDecoder().decode(EmbyItemsResponse.self, from: data)
            let pageItems = result.Items

            if iter == 1 {
                totalRecordCount = result.TotalRecordCount
                if let total = totalRecordCount, total > 0 {
                    let expectedPages = (total + pageSize - 1) / pageSize + 2
                    iterationCeiling = min(expectedPages, iterationCeiling)
                }
                AppLogger.network.info(
                    "[Emby] fetchBooks library=\(libraryId) totalRecordCount=\(totalRecordCount ?? -1) pageSize=\(pageSize)"
                )
            }

            allItems.append(contentsOf: pageItems)

            if pageItems.count < pageSize { break }
            if let total = totalRecordCount, startIndex + pageItems.count >= total { break }
            startIndex += pageItems.count
        }
        if iter >= iterationCeiling {
            AppLogger.network.error("[Emby] fetchBooks hit \(iterationCeiling)-page runaway guard for library \(libraryId)")
        }
        AppLogger.network.info("[Emby] fetchBooks library=\(libraryId) rawItems=\(allItems.count) iters=\(iter)")

        let folderTypes: Set<String> = ["CollectionFolder", "UserView", "Folder"]
        var filteredItems = allItems.filter { item in
            if item.Id == libraryId {
                AppLogger.network.warning("Skipping library root item returned in items list: \(item.Name) (\(item.Id))")
                return false
            }
            if let type = item.itemType, folderTypes.contains(type) {
                AppLogger.network.warning("Skipping non-book folder/view item: \(item.Name) (Type=\(type))")
                return false
            }
            return true
        }

        let containerItemIds: Set<String> = Set(
            filteredItems.compactMap { item -> String? in
                guard let type = item.itemType, type == "MusicAlbum" else { return nil }
                return item.Id
            }
        )
        let beforeDedup = filteredItems.count
        filteredItems = filteredItems.filter { item in
            if let parentId = item.ParentId, parentId != libraryId, containerItemIds.contains(parentId) {
                AppLogger.network.info(
                    "Removing nested child file '\(item.Name)' (Id=\(item.Id)) - MusicAlbum parent \(parentId) is already in results"
                )
                return false
            }
            return true
        }
        if filteredItems.count < beforeDedup {
            AppLogger.network.info("Dedup removed \(beforeDedup - filteredItems.count) nested child item(s)")
        }

        var titleIndex: [String: Int] = [:]
        var deduped: [EmbyItem] = []
        for item in filteredItems {
            let normalizedTitle = item.Name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let mediaType = isEbook(item) ? "ebook" : "audiobook"
            let deduplicationKey = "\(mediaType):\(normalizedTitle)"
            if let existingIdx = titleIndex[deduplicationKey] {
                let existingItem = deduped[existingIdx]
                let existingHasAuthor =
                    (existingItem.AlbumArtist?.isEmpty == false)
                    || existingItem.AlbumArtists?.first?.Name != nil
                    || existingItem.ArtistItems?.first?.Name != nil
                    || existingItem.Artists?.first != nil
                let newHasAuthor =
                    (item.AlbumArtist?.isEmpty == false)
                    || item.AlbumArtists?.first?.Name != nil
                    || item.ArtistItems?.first?.Name != nil
                    || item.Artists?.first != nil

                if !existingHasAuthor && newHasAuthor {
                    AppLogger.network.info(
                        "Replacing duplicate '\(existingItem.Name)' (no author, Id=\(existingItem.Id)) with '\(item.Name)' (has author, Id=\(item.Id))"
                    )
                    deduped[existingIdx] = item
                } else {
                    AppLogger.network.warning(
                        "Skipping duplicate item '\(item.Name)' (Id=\(item.Id)) - already have '\(existingItem.Name)' (Id=\(existingItem.Id))"
                    )
                }
            } else {
                titleIndex[deduplicationKey] = deduped.count
                deduped.append(item)
            }
        }
        if deduped.count < filteredItems.count {
            AppLogger.network.info("Title dedup removed \(filteredItems.count - deduped.count) duplicate(s)")
        }

        let books = deduped.map { item in
            AppLogger.network.info(
                "Book item: \(item.Name) (Type=\(item.itemType ?? "nil"), MediaSources=\(item.MediaSources?.count ?? 0))"
            )
            return mapEmbyItemToBook(item, libraryId: libraryId, base: base, children: [])
        }

        AppLogger.network.info("fetchBooks returning \(books.count) books")
        return books
    }

    func makeCatalogBatchSource(
        libraryId: String,
        resumeAfter: String?,
        expectedSnapshotIdentifier: String?
    ) async throws -> LibraryCatalogBatchSource {
        let firstPage = try await fetchIncrementalCatalogPage(libraryId: libraryId, page: 0)
        return LibraryCatalogBatchSource.paged(
            firstPage: firstPage,
            pageSize: 500,
            pageConcurrency: 6,
            resumeAfter: resumeAfter,
            expectedSnapshotIdentifier: expectedSnapshotIdentifier,
            fetchPage: { try await self.fetchIncrementalCatalogPage(libraryId: libraryId, page: $0) }
        )
    }

    private func fetchIncrementalCatalogPage(libraryId: String, page: Int) async throws -> LibraryCatalogPage {
        guard let userId = connection.userId else { throw ProviderError.unauthorized }
        let base = EmbyProvider.normalizeServerURL(connection.url)
        let pageSize = 500
        let startIndex = page * pageSize
        guard var components = URLComponents(string: "\(base)/Users/\(userId)/Items") else {
            throw ProviderError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "ParentId", value: libraryId),
            URLQueryItem(name: "IncludeItemTypes", value: "Book,MusicAlbum"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(
                name: "Fields",
                value: "Overview,MediaSources,RunTimeTicks,ParentId,ChildCount,ProductionYear,AlbumArtist,AlbumArtists,ArtistItems,SeriesName,IndexNumber,Studios,Genres,UserData,People,Path,Chapters,ImageTags,PrimaryImageItemId,PrimaryImageTag,ParentPrimaryImageItemId,ParentPrimaryImageTag,AlbumId,AlbumPrimaryImageTag"
            ),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "StartIndex", value: String(startIndex)),
            URLQueryItem(name: "Limit", value: String(pageSize)),
        ]
        guard let requestURL = components.url else { throw ProviderError.invalidURL }
        var request = URLRequest(url: requestURL)
        addAuthHeaders(&request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError.invalidResponse
        }
        let result = try JSONDecoder().decode(EmbyItemsResponse.self, from: data)
        let folderTypes: Set<String> = ["CollectionFolder", "UserView", "Folder"]
        let containerIds = Set(result.Items.filter { $0.itemType == "MusicAlbum" }.map(\.Id))
        let items = result.Items.filter { item in
            guard item.Id != libraryId else { return false }
            guard item.itemType.map({ !folderTypes.contains($0) }) ?? true else { return false }
            if let parentId = item.ParentId, parentId != libraryId, containerIds.contains(parentId) {
                return false
            }
            return true
        }
        var seenTitles = Set<String>()
        let books = items.compactMap { item -> Book? in
            let mediaType = isEbook(item) ? "ebook" : "audiobook"
            let key = "\(mediaType):\(item.Name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
            guard seenTitles.insert(key).inserted else { return nil }
            return mapEmbyItemToBook(item, libraryId: libraryId, base: base, children: [])
        }
        return LibraryCatalogPage(
            books: books,
            totalCount: result.TotalRecordCount,
            isLast: result.Items.count < pageSize
                || result.TotalRecordCount.map { startIndex + result.Items.count >= $0 } == true
        )
    }

    func fetchRecentBooks(libraryId: String, limit: Int) async throws -> [Book] {
        throw ProviderError.notImplemented
    }

    func downloadEbook(for book: Book, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        if let cached = LocalEbookImporter.shared.cachedEbook(forBookId: book.id) {
            onProgress?(1)
            return cached
        }

        guard book.mediaType == .ebook else { throw ProviderError.invalidResponse }
        guard let token = connection.token else { throw ProviderError.unauthorized }

        let base = EmbyProvider.normalizeServerURL(connection.url)
        guard var components = URLComponents(string: "\(base)/Items/\(book.id)/File") else {
            throw ProviderError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "api_key", value: token)]
        guard let downloadURL = components.url else { throw ProviderError.invalidURL }

        var request = URLRequest(url: downloadURL)
        addAuthHeaders(&request)

        let response: URLResponse
        let tempURL: URL
        if let onProgress {
            let delegate = URLSessionDownloadProgressDelegate(progressHandler: onProgress)
            let downloadSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            defer { downloadSession.finishTasksAndInvalidate() }
            let (url, http) = try await delegate.awaitResult {
                downloadSession.downloadTask(with: request)
            }
            tempURL = url
            response = http
        } else {
            (tempURL, response) = try await session.download(for: request)
        }

        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let responseMessage = (try? Data(contentsOf: tempURL))
                .flatMap { String(data: $0, encoding: .utf8) }
            try? FileManager.default.removeItem(at: tempURL)
            if responseMessage?.localizedCaseInsensitiveContains("access to the path") == true,
                responseMessage?.localizedCaseInsensitiveContains("is denied") == true
            {
                AppLogger.network.error(
                    "[Emby] Server denied ebook access bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
                )
                throw ProviderError.serverError(
                    "Emby cannot access this ebook file. Check the Books library file permissions on the Emby server."
                )
            }
            AppLogger.network.error(
                "[Emby] Ebook request failed bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) status=\(http.statusCode)"
            )
            throw ProviderError.serverError("Failed to download ebook (HTTP \(http.statusCode))")
        }

        let filename = ebookDownloadFilename(for: book, response: http)
        return try LocalEbookImporter.shared.cacheRemoteEbook(
            tempURL: tempURL,
            preferredFilename: filename,
            bookIdentifier: book.id
        )
    }

    func fetchFullBookDetails(bookId: String, libraryId: String) async throws -> Book {
        guard let userId = connection.userId else { throw ProviderError.unauthorized }
        let base = EmbyProvider.normalizeServerURL(connection.url)

        guard var components = URLComponents(string: "\(base)/Users/\(userId)/Items/\(bookId)") else { throw ProviderError.invalidURL }
        components.queryItems = [
            URLQueryItem(
                name: "Fields",
                value:
                    "Overview,MediaSources,RunTimeTicks,ParentId,ChildCount,ProductionYear,AlbumArtist,AlbumArtists,ArtistItems,SeriesName,IndexNumber,Studios,Genres,UserData,Chapters,People,Path,ImageTags,PrimaryImageItemId,PrimaryImageTag,ParentPrimaryImageItemId,ParentPrimaryImageTag,AlbumId,AlbumPrimaryImageTag"
            )
        ]

        guard let url = components.url else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        addAuthHeaders(&request)

        AppLogger.network.info("fetchFullBookDetails URL: \(url.redacted)")
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            AppLogger.network.error("fetchFullBookDetails failed with status: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            throw ProviderError.invalidResponse
        }

        let item = try JSONDecoder().decode(EmbyItem.self, from: data)
        AppLogger.network.info("Processing: \(item.Name), Type: \(item.itemType ?? "nil"), Chapters: \(item.Chapters?.count ?? 0)")

        var duration = Double(item.RunTimeTicks ?? 0) / 10_000_000.0

        var chapters: [Chapter] = []

        if let embyChapters = item.Chapters, !embyChapters.isEmpty {
            AppLogger.network.info("Using API chapters (\(embyChapters.count))")
            for (index, ch) in embyChapters.enumerated() {
                let start = Double(ch.StartPositionTicks) / 10_000_000.0
                let end: Double
                if index + 1 < embyChapters.count {
                    end = Double(embyChapters[index + 1].StartPositionTicks) / 10_000_000.0
                } else if duration > 0 {
                    end = duration
                } else {
                    end = start
                }

                chapters.append(
                    Chapter(
                        id: "chapter_\(index)",
                        start: start,
                        end: end,
                        title: ch.Name
                    )
                )
            }

        }

        if chapters.count <= 1 {
            let childTracks = try await fetchChildAudioItems(parentId: bookId)

            if childTracks.count > 1 {
                AppLogger.network.info("Multi-file book detected (\(childTracks.count) tracks). Mapping tracks to chapters.")
                var chaptersFromTracks: [Chapter] = []
                var cumulativeStart: Double = 0
                for track in childTracks {
                    let trackDuration = Double(track.RunTimeTicks ?? 0) / 10_000_000.0
                    chaptersFromTracks.append(
                        Chapter(
                            id: track.Id,
                            start: cumulativeStart,
                            end: cumulativeStart + trackDuration,
                            title: track.Name
                        )
                    )
                    cumulativeStart += trackDuration
                }
                chapters = chaptersFromTracks
                duration = cumulativeStart
                AppLogger.network.info("Total duration updated to \(duration)s based on \(childTracks.count) tracks")
            }
        }

        if chapters.count <= 1 {
            AppLogger.network.info("Still have <= 1 chapter, attempting AVFoundation extraction...")
            if let token = connection.token {

                var streamId = bookId
                let containerTypes: Set<String> = ["MusicAlbum", "AudioBook", "Folder"]
                if let type = item.itemType, containerTypes.contains(type) {
                    let childTracks = try await fetchChildAudioItems(parentId: bookId)
                    if let firstTrack = childTracks.first {
                        streamId = firstTrack.Id
                    }
                }
                let streamURLString = "\(base)/Audio/\(streamId)/stream?static=true&api_key=\(token)"
                if let streamURL = URL(string: streamURLString) {
                    let extracted = await extractChaptersFromStream(url: streamURL)
                    if !extracted.isEmpty {
                        AppLogger.network.info("Successfully extracted \(extracted.count) chapters from stream")
                        chapters = extracted
                    }
                }
            }
        }

        if chapters.isEmpty {
            AppLogger.network.warning("Final fallback: Single full-book chapter")
            chapters.append(
                Chapter(
                    id: "chapter_0",
                    start: 0,
                    end: duration,
                    title: item.Name
                )
            )
        }

        let childTracks = try await fetchChildAudioItems(parentId: bookId)
        var book = mapEmbyItemToBook(item, libraryId: libraryId, base: base, children: childTracks)
        book.chapters = chapters

        if duration == 0 || book.duration == 0, let lastChapter = chapters.last, lastChapter.end > 0 {
            duration = lastChapter.end
            AppLogger.network.info("Duration updated to \(duration)s from last chapter end")
        }

        if duration == 0 || book.duration == 0, let source = item.MediaSources?.first, let ticks = source.RunTimeTicks {
            duration = Double(ticks) / 10_000_000.0
            AppLogger.network.info("Duration updated to \(duration)s from MediaSource")
        }

        if (duration != book.duration && duration > 0) || (book.duration == 0 && duration > 0) {
            AppLogger.network.info("Recreating book with corrected duration: \(duration)s")
            let newProgress = duration > 0 ? (book.currentTime / duration) : 0
            book = Book(
                id: book.id,
                title: book.title,
                author: book.author,
                narrator: book.narrator,
                seriesInfo: book.seriesInfo,
                duration: duration,
                coverURL: book.coverURL,
                dateAdded: book.dateAdded,
                releaseDate: book.releaseDate,
                description: book.description,
                genres: book.genres,
                chapters: chapters,
                publisher: book.publisher,
                progress: newProgress,
                currentTime: book.currentTime,
                isFinished: book.isFinished,
                lastUpdate: Date(),
                libraryId: libraryId,
                providerId: connection.id,
                rawMetadata: nil
            )
        }

        book = await applyMetadataFallback(book: book, item: item, childTracks: childTracks)

        return book
    }

    private func applyMetadataFallback(book: Book, item: EmbyItem, childTracks: [EmbyItem]) async -> Book {
        var book = book
        let base = EmbyProvider.normalizeServerURL(connection.url)

        if book.author == "Unknown Author" || (book.narrator == nil || book.narrator?.isEmpty == true) || book.seriesInfo == nil {
            AppLogger.network.warning(
                "Essential metadata missing for '\(book.title)' (Author/Narrator/Series), attempting to read from file tags..."
            )
            if let token = connection.token {
                var streamId = item.Id
                if (item.RunTimeTicks ?? 0) == 0 {
                    if let firstTrack = childTracks.first {
                        streamId = firstTrack.Id
                    }
                }

                let streamURLString = "\(base)/Audio/\(streamId)/stream?static=true&api_key=\(token)"
                if let streamURL = URL(string: streamURLString) {
                    let fileMetadata = await extractMetadataFromStream(url: streamURL)

                    if book.author == "Unknown Author", let fileAuthor = fileMetadata.author {
                        AppLogger.network.debug(
                            "Using embedded author bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
                        )
                        book.author = fileAuthor
                    }

                    if book.narrator == nil || book.narrator?.isEmpty == true, let fileNarrator = fileMetadata.narrator {
                        AppLogger.network.debug(
                            "Using embedded narrator bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
                        )
                        book.narrator = fileNarrator
                    }

                    if book.series == nil, let fileSeries = fileMetadata.series {
                        AppLogger.network.debug(
                            "Using embedded series bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
                        )
                        book.series = fileSeries
                    }
                }
            }
        }
        return book
    }

    private func fetchChildAudioItems(parentId: String) async throws -> [EmbyItem] {
        guard let userId = connection.userId else { return [] }
        let base = EmbyProvider.normalizeServerURL(connection.url)

        guard var components = URLComponents(string: "\(base)/Users/\(userId)/Items") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "ParentId", value: parentId),
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(
                name: "Fields",
                value:
                    "Overview,MediaSources,RunTimeTicks,ParentId,ChildCount,ProductionYear,AlbumArtist,AlbumArtists,ArtistItems,SeriesName,IndexNumber,Studios,Genres,UserData,People,Artists,Artist"
            ),
        ]

        guard let requestURL = components.url else {
            return []
        }

        var request = URLRequest(url: requestURL)
        addAuthHeaders(&request)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return []
        }

        let result = try JSONDecoder().decode(EmbyItemsResponse.self, from: data)
        return result.Items
    }

    private func extractChaptersFromStream(url: URL) async -> [Chapter] {
        let asset = AVURLAsset(url: url)
        var chapters: [Chapter] = []

        do {
            let locales = try await asset.load(.availableChapterLocales)
            for locale in locales {
                let metadataGroups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: [locale.identifier])
                for (index, group) in metadataGroups.enumerated() {
                    let timeRange = group.timeRange
                    let start = CMTimeGetSeconds(timeRange.start)
                    let chapterDuration = CMTimeGetSeconds(timeRange.duration)

                    var title = "Chapter \(index + 1)"
                    for item in group.items {
                        if item.commonKey == .commonKeyTitle {
                            if let val = try? await item.load(.stringValue) {
                                title = val
                                break
                            }
                        }
                    }

                    chapters.append(
                        Chapter(
                            id: "extracted_\(index)",
                            start: start,
                            end: start + chapterDuration,
                            title: title
                        )
                    )
                }
                if !chapters.isEmpty { break }
            }
        } catch {
            AppLogger.network.error("Extraction failed: \(error)")
        }

        return chapters.sorted { $0.start < $1.start }
    }

    private struct FileMetadata {
        var author: String?
        var narrator: String?
        var series: String?
    }

    private func extractMetadataFromStream(url: URL) async -> FileMetadata {
        let asset = AVURLAsset(url: url)
        var metadata = FileMetadata()
        var potentialNarrators: [String] = []

        do {
            let formats = try await asset.load(.availableMetadataFormats)
            AppLogger.network.info("Available metadata formats: \(formats.map { $0.rawValue })")

            for format in formats {
                let items = try await asset.loadMetadata(for: format)
                AppLogger.network.info("Format \(format.rawValue) has \(items.count) tags:")

                for item in items {
                    let key = item.commonKey?.rawValue ?? item.key?.description ?? "unknown"
                    let value = try? await item.load(.stringValue)
                    let val = value ?? "<no string value>"
                    AppLogger.network.info("Tag: '\(key)' = '\(val)'")

                    guard let actualVal = value, !actualVal.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                    let trimmedVal = actualVal.trimmingCharacters(in: .whitespaces)

                    let lowerKey = key.lowercased()

                    if metadata.author == nil
                        && (lowerKey.contains("artist") || lowerKey.contains("author") || lowerKey == "tpe1" || lowerKey == "©art")
                    {
                        metadata.author = trimmedVal
                        AppLogger.network.info("Extracted Author from '\(key)': \(trimmedVal)")
                    }

                    if metadata.narrator == nil
                        && (lowerKey.contains("composer") || lowerKey.contains("narrator") || lowerKey.contains("album_artist")
                            || lowerKey == "tcom" || lowerKey == "©wrt" || lowerKey == "©lyr" || lowerKey == "text"
                            || lowerKey.contains("tpe2") || lowerKey.contains("aart"))
                    {
                        if trimmedVal.lowercased() != (metadata.author ?? "").lowercased() {
                            metadata.narrator = trimmedVal
                            AppLogger.network.info("Extracted Narrator from '\(key)': \(trimmedVal)")
                        }
                    }

                    if key.contains("-1451789708") || key.contains("1631670869") {
                        if trimmedVal.lowercased() != (metadata.author ?? "").lowercased() {
                            potentialNarrators.append(trimmedVal)
                            AppLogger.network.info("Potential narrator from iTunes atom '\(key)': \(trimmedVal)")
                        }
                    }

                    if metadata.narrator == nil && key.hasPrefix("-") && trimmedVal.lowercased() != (metadata.author ?? "").lowercased() {
                        let words = trimmedVal.components(separatedBy: " ")
                        if words.count >= 2 && words.count <= 5 && trimmedVal.count < 50 {
                            if !trimmedVal.contains("ISBN") && !trimmedVal.contains("©") && !trimmedVal.contains("http") {
                                potentialNarrators.append(trimmedVal)
                                AppLogger.network.info("Potential narrator from '\(key)': \(trimmedVal)")
                            }
                        }
                    }

                    if metadata.series == nil && (lowerKey.contains("album") || lowerKey.contains("talb") || lowerKey == "©alb") {
                        metadata.series = trimmedVal
                        AppLogger.network.info("Extracted Series from '\(key)': \(trimmedVal)")
                    }
                }
            }

            if metadata.narrator == nil, let firstCandidate = potentialNarrators.first {
                metadata.narrator = firstCandidate
                AppLogger.network.info("Using potential narrator: \(firstCandidate)")
            }

        } catch {
            AppLogger.network.error("Metadata extraction failed: \(error)")
        }

        return metadata
    }

    func startPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo {
        let base = EmbyProvider.normalizeServerURL(connection.url)
        guard let token = connection.token else { throw ProviderError.unauthorized }

        AppLogger.network.debug(
            "[Emby] Starting playback bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) server=\(URL(string: base)?.redacted.absoluteString ?? "<invalid>")"
        )

        if book.id == book.libraryId {
            AppLogger.network.warning(
                "[Emby] Refusing playback because item matches library bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
            )
            throw ProviderError.invalidResponse
        }

        var tracks: [AudioTrackInfo] = []

        let childTracks = try await fetchChildAudioItems(parentId: book.id)
        AppLogger.network.info("[Emby] Child tracks found: \(childTracks.count)")

        if !childTracks.isEmpty {
            AppLogger.network.info("[Emby] Multi-file audiobook detected")
            var cumulativeStart: Double = 0
            for (index, child) in childTracks.enumerated() {
                let trackDuration = Double(child.RunTimeTicks ?? 0) / 10_000_000.0
                let streamUrl = "\(base)/Audio/\(child.Id)/stream?static=true&api_key=\(token)"
                AppLogger.network.info("[Emby] Track \(index): \(child.Name) (%.1fs) -> \(trackDuration)")

                tracks.append(
                    AudioTrackInfo(
                        index: index,
                        startOffset: cumulativeStart,
                        duration: trackDuration,
                        contentUrl: streamUrl,
                        mimeType: "audio/mpeg"
                    )
                )
                cumulativeStart += trackDuration
            }
        } else {
            AppLogger.network.info("[Emby] Single-file audiobook detected")
            let streamUrl = "\(base)/Audio/\(book.id)/stream?static=true&api_key=\(token)"
            AppLogger.network.info("[Emby] Stream URL: \(URL(string: streamUrl)?.redacted.absoluteString ?? "<invalid>")")

            tracks.append(
                AudioTrackInfo(
                    index: 0,
                    startOffset: 0,
                    duration: book.duration ?? 0,
                    contentUrl: streamUrl,
                    mimeType: "audio/mpeg"
                )
            )
        }

        AppLogger.network.info("[Emby] Total tracks: \(tracks.count)")
        AppLogger.network.info("[Emby] ===== PLAYBACK SESSION READY =====")

        return PlaybackSessionInfo(
            sessionId: UUID().uuidString,
            audioTracks: tracks,
            chapters: book.chapters ?? []
        )
    }

    func updatePlaybackProgress(
        book: Book,
        sessionId: String?,
        currentTime: TimeInterval,
        isFinished: Bool,
        timeListened: TimeInterval
    ) async throws {
        guard let userId = connection.userId else { return }
        let base = EmbyProvider.normalizeServerURL(connection.url)

        guard let url = URL(string: "\(base)/Users/\(userId)/Items/\(book.id)/UserData") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuthHeaders(&request)

        let ticks = Int64(currentTime * 10_000_000)
        let body: [String: Any] = [
            "PlaybackPositionTicks": ticks,
            "Played": isFinished,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        _ = try await session.data(for: request)
    }

    func getAudioURL(for book: Book) -> URL? {
        guard let token = connection.token else { return nil }
        let base = EmbyProvider.normalizeServerURL(connection.url)
        return URL(string: "\(base)/Audio/\(book.id)/stream?static=true&api_key=\(token)")
    }

    func getStreamingHeaders() -> [String: String] {
        return [:]
    }

    func fetchAudiobookProgress(
        for book: Book
    ) async throws -> (positionSeconds: TimeInterval, percentage: Double, trackIndex: Int?, updatedAt: Date?, isAbandoned: Bool)? {
        guard let userId = connection.userId else { return nil }
        let base = EmbyProvider.normalizeServerURL(connection.url)

        guard let url = URL(string: "\(base)/Users/\(userId)/Items/\(book.id)?Fields=UserData") else { return nil }
        var request = URLRequest(url: url)
        addAuthHeaders(&request)

        guard let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let item = try? JSONDecoder().decode(EmbyItem.self, from: data)
        else {
            return nil
        }

        let positionSeconds = Double(item.UserData?.PlaybackPositionTicks ?? 0) / 10_000_000.0
        let played = item.UserData?.Played ?? false
        return (positionSeconds: positionSeconds, percentage: 0, trackIndex: nil, updatedAt: nil, isAbandoned: played)
    }

    func fetchCollections(libraryId: String?) async throws -> [Collection] { return [] }
    func fetchSeries(libraryId: String) async throws -> [Series] { return [] }
    func fetchUserMediaProgress(libraryId: String) async throws -> [UserMediaProgress] { return [] }

    private func isEbook(_ item: EmbyItem) -> Bool {
        item.itemType?.caseInsensitiveCompare("Book") == .orderedSame
            || item.MediaType?.caseInsensitiveCompare("Book") == .orderedSame
    }

    private func ebookDownloadFilename(for book: Book, response: HTTPURLResponse) -> String {
        if let suggestedFilename = response.suggestedFilename,
            EbookFormat.from(fileExtension: (suggestedFilename as NSString).pathExtension) != nil
        {
            return suggestedFilename
        }

        let fileExtension: String = {
            if let mimeType = response.mimeType?.lowercased() {
                switch mimeType {
                case "application/epub+zip": return "epub"
                case "application/pdf": return "pdf"
                case "application/x-cbz", "application/vnd.comicbook+zip": return "cbz"
                case "application/x-cbr", "application/vnd.comicbook-rar", "application/vnd.rar": return "cbr"
                default: break
                }
            }
            if let format = book.ebookFormat,
                EbookFormat.from(fileExtension: format) != nil
            {
                return format.lowercased()
            }
            return "epub"
        }()

        return "\(book.title.replacingOccurrences(of: "/", with: "-")).\(fileExtension)"
    }

    private func mapEmbyItemToBook(_ item: EmbyItem, libraryId: String, base: String, children: [EmbyItem] = []) -> Book {
        let isEbook = isEbook(item)
        var rawDuration = isEbook ? 0 : item.RunTimeTicks ?? 0
        if rawDuration == 0 {
            rawDuration = isEbook ? 0 : children.reduce(0) { $0 + ($1.RunTimeTicks ?? 0) }
        }

        let duration = Double(rawDuration) / 10_000_000.0
        let currentTime = isEbook ? 0 : Double(item.UserData?.PlaybackPositionTicks ?? 0) / 10_000_000.0
        let audioProgress = duration > 0 ? (currentTime / duration) : 0
        let ebookProgress = isEbook ? (item.UserData?.PlayedPercentage.map { $0 / 100.0 }) : nil
        let ebookFormat: String? =
            isEbook
            ? item.Path.flatMap { path in
                let fileExtension = (path as NSString).pathExtension.lowercased()
                return EbookFormat.from(fileExtension: fileExtension) == nil ? nil : fileExtension
            } : nil

        let imageReference: (itemId: String, tag: String)? = {
            if let tag = item.ImageTags?["Primary"], !tag.isEmpty {
                return (item.Id, tag)
            }
            if let itemId = item.PrimaryImageItemId, !itemId.isEmpty,
                let tag = item.PrimaryImageTag, !tag.isEmpty
            {
                return (itemId, tag)
            }
            if let itemId = item.ParentPrimaryImageItemId, !itemId.isEmpty,
                let tag = item.ParentPrimaryImageTag, !tag.isEmpty
            {
                return (itemId, tag)
            }
            if let itemId = item.AlbumId, !itemId.isEmpty,
                let tag = item.AlbumPrimaryImageTag, !tag.isEmpty
            {
                return (itemId, tag)
            }
            return nil
        }()
        var coverURL: URL?
        if let imageReference,
            var components = URLComponents(string: "\(base)/Items/\(imageReference.itemId)/Images/Primary")
        {
            var queryItems: [URLQueryItem] = []
            if let token = connection.token, !token.isEmpty {
                queryItems.append(URLQueryItem(name: "api_key", value: token))
            }
            queryItems.append(URLQueryItem(name: "tag", value: imageReference.tag))
            components.queryItems = queryItems
            coverURL = components.url
        }

        let getAuthor = { (obj: EmbyItem) -> String? in
            [
                obj.AlbumArtist,
                obj.AlbumArtists?.first?.Name,
                obj.People?.first(where: { $0.personType == "Writer" })?.Name,
            ].compactMap { $0 }.first(where: { !$0.isEmpty })
        }

        let author = getAuthor(item) ?? children.compactMap({ getAuthor($0) }).first ?? "Unknown Author"

        let getNarrator = { (obj: EmbyItem, currentAuthor: String) -> String? in
            let lowerAuthor = currentAuthor.lowercased()

            if let narratorPerson = obj.People?.first(where: {
                ($0.Role?.lowercased().contains("narrator") == true) || ($0.personType?.lowercased().contains("narrator") == true)
            })?.Name {
                return narratorPerson
            }

            if let artistItem = obj.ArtistItems?.first(where: {
                let name = $0.Name.trimmingCharacters(in: .whitespaces)
                return !name.isEmpty && name.lowercased() != lowerAuthor
            })?.Name {
                return artistItem
            }

            if let artistStr = (obj.Artists ?? [obj.Artist].compactMap { $0 }).first(where: {
                let name = $0.trimmingCharacters(in: .whitespaces)
                return !name.isEmpty && name.lowercased() != lowerAuthor
            }) {
                return artistStr
            }

            return nil
        }

        let narrator = getNarrator(item, author) ?? children.compactMap({ getNarrator($0, author) }).first

        let releaseYear = item.ProductionYear ?? children.compactMap({ $0.ProductionYear }).first
        var releaseDate: Date? = nil
        if let year = releaseYear {
            var components = DateComponents()
            components.year = year
            components.month = 1
            components.day = 1
            releaseDate = Calendar.current.date(from: components)
        }

        var seriesName = item.SeriesName ?? children.compactMap({ $0.SeriesName }).first
        var indexNumber = item.IndexNumber ?? children.compactMap({ $0.IndexNumber }).first

        if seriesName == nil, let path = item.Path ?? children.first?.Path {
            let components = path.components(separatedBy: "/")
            if components.count >= 2 {
                let bookFolderName = components[components.count - 1]
                let potentialSeriesName = components[components.count - 2]

                if potentialSeriesName != bookFolderName && !potentialSeriesName.isEmpty
                    && potentialSeriesName.lowercased() != author.lowercased()
                {
                    seriesName = potentialSeriesName
                    AppLogger.network.info("Derived series from path: \(potentialSeriesName)")

                    if indexNumber == nil {
                        let regex = try? NSRegularExpression(pattern: "^(\\d+)\\s*[-\\.]")
                        if let match = regex?.firstMatch(
                            in: bookFolderName,
                            range: NSRange(bookFolderName.startIndex..., in: bookFolderName)
                        ),
                            let range = Range(match.range(at: 1), in: bookFolderName),
                            let parsed = Int(bookFolderName[range])
                        {
                            indexNumber = parsed
                            AppLogger.network.info("Derived index from path: \(parsed)")
                        }
                    }
                }
            }
        }

        var seriesInfo: SeriesInfo? = nil
        if let name = seriesName {
            seriesInfo = SeriesInfo(name: name, sequence: indexNumber.map { "\($0)" })
        }

        return Book(
            id: item.Id,
            title: item.Name,
            author: author,
            narrator: narrator,
            seriesInfo: seriesInfo,
            duration: duration,
            coverURL: coverURL,
            mediaType: isEbook ? .ebook : .audiobook,
            ebookFormat: ebookFormat,
            ebookProgress: ebookProgress,
            dateAdded: Date(),
            releaseDate: releaseDate,
            description: item.Overview ?? children.compactMap({ $0.Overview }).first,
            genres: item.Genres ?? children.flatMap({ $0.Genres ?? [] }),
            chapters: [],
            publisher: item.Studios?.first?.Name ?? children.compactMap({ $0.Studios?.first?.Name }).first,
            progress: audioProgress,
            currentTime: currentTime,
            isFinished: item.UserData?.Played ?? false,
            lastUpdate: Date(),
            libraryId: libraryId,
            providerId: connection.id,
            source: .emby,
            rawMetadata: nil
        )
    }
}

private struct EmbyItemsResponse: Decodable {
    let Items: [EmbyItem]
    let TotalRecordCount: Int?
}

private struct EmbyItem: Decodable {
    let Id: String
    let ParentId: String?
    let Name: String
    let itemType: String?
    let MediaType: String?
    let CollectionType: String?
    let RunTimeTicks: Int64?
    let ProductionYear: Int?
    let Overview: String?
    let AlbumArtist: String?
    let AlbumArtists: [EmbyNameIdPair]?
    let ArtistItems: [EmbyNameIdPair]?
    let ImageTags: [String: String]?
    let PrimaryImageItemId: String?
    let PrimaryImageTag: String?
    let ParentPrimaryImageItemId: String?
    let ParentPrimaryImageTag: String?
    let AlbumId: String?
    let AlbumPrimaryImageTag: String?
    let Chapters: [EmbyChapter]?
    let UserData: EmbyUserData?
    let SeriesName: String?
    let IndexNumber: Int?
    let Studios: [EmbyNameIdPair]?
    let Genres: [String]?
    let ChildCount: Int?
    let MediaSources: [EmbyMediaSource]?
    let People: [EmbyPerson]?
    let Artists: [String]?
    let Artist: String?
    let Path: String?

    enum CodingKeys: String, CodingKey {
        case Id, ParentId, Name, MediaType, CollectionType, RunTimeTicks, ProductionYear, Overview
        case AlbumArtist, AlbumArtists, ArtistItems, ImageTags, Chapters, UserData
        case PrimaryImageItemId, PrimaryImageTag, ParentPrimaryImageItemId, ParentPrimaryImageTag
        case AlbumId, AlbumPrimaryImageTag
        case SeriesName, IndexNumber, Studios, Genres, ChildCount, MediaSources, People
        case Artists, Artist, Path
        case itemType = "Type"
    }
}

private struct EmbyMediaSource: Decodable {
    let Id: String
    let RunTimeTicks: Int64?
}

private struct EmbyPerson: Decodable {
    let Name: String
    let Id: String
    let personType: String?
    let Role: String?

    enum CodingKeys: String, CodingKey {
        case Name, Id, Role
        case personType = "Type"
    }
}

private struct EmbyChapter: Decodable {
    let Name: String
    let StartPositionTicks: Int64
}

private struct EmbyUserData: Decodable {
    let PlaybackPositionTicks: Int64?
    let Played: Bool?
    let PlayedPercentage: Double?
}

private struct EmbyNameIdPair: Decodable {
    let Name: String
    let Id: String
}
