import AVFoundation
import Combine
import Foundation
import Logging

#if canImport(UIKit)
import UIKit
#endif

class JellyfinProvider: IncrementalCatalogProvider, PlaybackSessionProvider, AudiobookProgressProvider,
    EbookProgressProvider, EbookDownloadProvider, ObservableObject, @unchecked Sendable
{
    @Published var connection: ServerConnection
    let session: URLSession

    var capabilities: ProviderCapabilities {
        [
            .fullImport, .pagedImport,
            .audiobookProgressPull, .audiobookProgressPush,
            .ebookProgressPull, .ebookProgressPush,
            .downloads, .coverAuthHeader, .backgroundOperation,
        ]
    }

    var jellyfinClientName: String { "Enve" }
    var jellyfinClientVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    var jellyfinDeviceId: String {
        #if canImport(UIKit)
        return UIDevice.current.identifierForVendor?.uuidString ?? StorageService.shared.loadDeviceUUID()
        #else
        return StorageService.shared.loadDeviceUUID()
        #endif
    }
    var jellyfinDeviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
        #elseif os(macOS)
        return (Host.current().localizedName ?? "Mac").replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
        #else
        return "Enve Client"
        #endif
    }

    init(connection: ServerConnection = ServerConnection(name: "Jellyfin", url: "", type: .jellyfin)) {
        self.connection = connection

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    private func addAuthHeaders(_ request: inout URLRequest) {
        let auth = buildAuthHeaderValue()
        request.setValue(auth, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let token = connection.token {
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        }
    }

    private func buildAuthHeaderValue() -> String {
        var header =
            "MediaBrowser Client=\"\(jellyfinClientName)\", Device=\"\(jellyfinDeviceName)\", DeviceId=\"\(jellyfinDeviceId)\", Version=\"\(jellyfinClientVersion)\""
        if let token = connection.token {
            header += ", Token=\"\(token)\""
        }
        return header
    }

    func normalizeServerURL(_ url: String) -> String {
        var trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if trimmed.isEmpty { return url }

        if !trimmed.lowercased().hasPrefix("http") {
            if trimmed.contains("8920") {
                trimmed = "https://\(trimmed)"
            } else {
                trimmed = "http://\(trimmed)"
            }
        }

        return trimmed
    }

    func validateConnection() async throws -> Bool {
        AppLogger.network.info("[JellyfinProvider] ===== VALIDATE CONNECTION STARTED =====")
        AppLogger.network.info("[JellyfinProvider] URL: \(URL(string: connection.url)?.redacted.absoluteString ?? "<invalid>")")
        AppLogger.network.info("[JellyfinProvider] Has username: \(connection.username != nil ? "YES" : "NO")")
        AppLogger.network.info("[JellyfinProvider] Has userId: \(connection.userId != nil ? "YES" : "NO")")

        let base = normalizeServerURL(connection.url)

        if let token = connection.token, connection.userId == nil {
            AppLogger.network.info("[JellyfinProvider] Token exists but no userId, trying to discover...")
            if let discovered = try? await fetchUserId(base: base, token: token, preferredUsername: connection.username) {
                connection.userId = discovered
                AppLogger.network.info("[JellyfinProvider] Discovered userId: \(discovered)")
            }
        }

        if let _ = connection.token, let userId = connection.userId {
            AppLogger.network.info("[JellyfinProvider] Validating existing token with userId: \(userId)")
            guard let url = URL(string: "\(base)/Users/\(userId)") else {
                AppLogger.network.error("[JellyfinProvider] Invalid URL while validating user")
                return false
            }

            var request = URLRequest(url: url)
            addAuthHeaders(&request)

            do {
                let (_, response) = try await performDataTask(for: request)
                guard let httpResponse = response as? HTTPURLResponse else { return false }
                AppLogger.network.info("[JellyfinProvider] validateConnection status: \(httpResponse.statusCode)")
                return httpResponse.statusCode == 200
            } catch {
                AppLogger.network.error("[JellyfinProvider] validateConnection failed: \(error.localizedDescription)")
                return false
            }
        }

        AppLogger.network.info("[JellyfinProvider] No valid token, checking for username/password...")
        guard let username = connection.username, let password = connection.token else {
            AppLogger.network.warning("[JellyfinProvider] Missing username or password")
            return false
        }

        AppLogger.network.info("[JellyfinProvider] Attempting authentication with username/password...")
        try await authenticate(username: username, password: password)
        return try await validateConnection()
    }

    private struct JellyfinUser: Decodable {
        let Id: String
        let Name: String?
    }

    private func fetchUserId(base: String, token: String, preferredUsername: String?) async throws -> String? {
        guard let url = URL(string: "\(base)/Users") else {
            return nil
        }
        var request = URLRequest(url: url)
        let savedToken = connection.token
        connection.token = token
        addAuthHeaders(&request)
        connection.token = savedToken

        let (data, response) = try await performDataTask(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        let users = try JSONDecoder().decode([JellyfinUser].self, from: data)
        if let preferredUsername {
            if let match = users.first(where: { ($0.Name ?? "").caseInsensitiveCompare(preferredUsername) == .orderedSame }) {
                return match.Id
            }
        }
        return users.first?.Id
    }

    private struct AuthResponse: Decodable {
        let AccessToken: String
        let User: User
        struct User: Decodable {
            let Id: String
        }
    }

    private func authenticate(username: String, password: String) async throws {
        AppLogger.network.info("[JellyfinProvider] ===== AUTHENTICATION STARTED =====")
        AppLogger.network.info("[JellyfinProvider] Username: \(username)")

        let base = normalizeServerURL(connection.url)
        AppLogger.network.info("[JellyfinProvider] Server URL: \(URL(string: base)?.redacted.absoluteString ?? "<invalid>")")

        guard let url = URL(string: "\(base)/Users/AuthenticateByName") else {
            AppLogger.network.error("[JellyfinProvider] Invalid URL for auth")
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let authHeader =
            "MediaBrowser Client=\"\(jellyfinClientName)\", Device=\"\(jellyfinDeviceName)\", DeviceId=\"\(jellyfinDeviceId)\", Version=\"\(jellyfinClientVersion)\""
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")

        let body: [String: String] = ["Username": username, "Pw": password]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        AppLogger.network.info("[JellyfinProvider] Sending auth request to: \(url.redacted)")

        let (data, response) = try await performDataTask(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            AppLogger.network.error("[JellyfinProvider] Invalid response type")
            throw ProviderError.invalidResponse
        }

        AppLogger.network.info("[JellyfinProvider] Response status: \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            AppLogger.network.error("[JellyfinProvider] Auth failed with status \(httpResponse.statusCode)")
            if httpResponse.statusCode == 401 {
                throw ProviderError.unauthorized
            }
            throw ProviderError.serverError("HTTP \(httpResponse.statusCode)")
        }

        let result = try JSONDecoder().decode(AuthResponse.self, from: data)
        connection.token = result.AccessToken
        connection.userId = result.User.Id

        AppLogger.network.info("[JellyfinProvider] Authentication successful!")
        AppLogger.network.info("[JellyfinProvider] User ID: \(result.User.Id)")
    }

    func fetchLibraries() async throws -> [Library] {
        guard let userId = connection.userId else { throw ProviderError.unauthorized }
        let base = normalizeServerURL(connection.url)

        guard let url = URL(string: "\(base)/Users/\(userId)/Views") else {
            throw ProviderError.invalidURL
        }
        var request = URLRequest(url: url)
        addAuthHeaders(&request)

        AppLogger.network.info("fetchLibraries URL: \(url.redacted)")
        let (data, response) = try await performDataTask(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            AppLogger.network.error("fetchLibraries failed with status: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            throw ProviderError.invalidResponse
        }

        let result = try JSONDecoder().decode(JellyfinItemsResponse.self, from: data)
        AppLogger.network.info("fetchLibraries found \(result.Items.count) total views")

        return result.Items.compactMap { item in
            let collectionType = item.CollectionType ?? ""
            AppLogger.network.info("View: \(item.Name), ID: \(item.Id), CollectionType: \(collectionType)")

            if collectionType == "books" || collectionType == "audiobooks" {
                return Library(
                    id: item.Id,
                    name: item.Name,
                    type: "book",
                    providerId: connection.id
                )
            }
            return nil
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
            pageSize: 500,
            pageConcurrency: 6,
            resumeAfter: resumeAfter,
            expectedSnapshotIdentifier: expectedSnapshotIdentifier,
            fetchPage: { try await self.fetchCatalogPage(libraryId: libraryId, page: $0) }
        )
    }

    private func fetchCatalogPage(libraryId: String, page: Int) async throws -> LibraryCatalogPage {
        guard let userId = connection.userId else { throw ProviderError.unauthorized }
        let base = normalizeServerURL(connection.url)
        let pageSize = 500
        let startIndex = page * pageSize
        guard var components = URLComponents(string: "\(base)/Users/\(userId)/Items") else {
            throw ProviderError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "ParentId", value: libraryId),
            URLQueryItem(name: "IncludeItemTypes", value: "AudioBook,Book"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(
                name: "Fields",
                value: "Overview,Chapters,MediaSources,RunTimeTicks,ParentId,ChildCount,ProductionYear,AlbumArtist,AlbumArtists,ArtistItems,SeriesName,IndexNumber,Studios,Genres,UserData,Path"
            ),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "StartIndex", value: String(startIndex)),
            URLQueryItem(name: "Limit", value: String(pageSize)),
        ]
        guard let requestURL = components.url else { throw ProviderError.invalidURL }
        var request = URLRequest(url: requestURL)
        addAuthHeaders(&request)
        let (data, response) = try await performDataTask(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError.invalidResponse
        }
        let result = try JSONDecoder().decode(JellyfinItemsResponse.self, from: data)
        let books = result.Items.filter { item in
            item.Id != libraryId && item.itemType != "CollectionFolder" && item.itemType != "UserView"
        }.map { mapJellyfinItemToBook($0, libraryId: libraryId, base: base) }
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

    func fetchFullBookDetails(bookId: String, libraryId: String) async throws -> Book {
        guard let userId = connection.userId else { throw ProviderError.unauthorized }
        let base = normalizeServerURL(connection.url)

        guard let url = URL(string: "\(base)/Users/\(userId)/Items/\(bookId)") else {
            throw ProviderError.invalidURL
        }
        var request = URLRequest(url: url)
        addAuthHeaders(&request)

        AppLogger.network.info("fetchFullBookDetails URL: \(url.redacted)")
        let (data, response) = try await performDataTask(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            AppLogger.network.error("fetchFullBookDetails failed with status: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            throw ProviderError.invalidResponse
        }

        let item = try JSONDecoder().decode(JellyfinItem.self, from: data)
        AppLogger.network.info("Processing: \(item.Name), Type: \(item.itemType), Chapters: \(item.Chapters?.count ?? 0)")

        var duration = Double(item.RunTimeTicks ?? 0) / 10_000_000.0

        var chapters: [Chapter] = []

        if let jfChapters = item.Chapters, !jfChapters.isEmpty {
            AppLogger.network.info("Using API chapters (\(jfChapters.count))")
            for (index, ch) in jfChapters.enumerated() {
                let start = Double(ch.StartPositionTicks) / 10_000_000.0
                let end: Double
                if index + 1 < jfChapters.count {
                    end = Double(jfChapters[index + 1].StartPositionTicks) / 10_000_000.0
                } else {
                    end = duration
                }

                chapters.append(
                    Chapter(
                        id: "ch_\(index)",
                        start: start,
                        end: end,
                        title: ch.Name
                    )
                )
            }
        }

        if chapters.count <= 1 && (item.itemType == "Folder" || item.itemType == "MusicAlbum" || item.itemType == "AudioBook") {
            let children = try await fetchChildAudioItems(parentId: bookId)

            if children.count > 1 {
                AppLogger.network.info("Multi-file book detected (\(children.count) tracks). Mapping tracks to chapters.")
                var chaptersFromTracks: [Chapter] = []
                var cumulativeStart: Double = 0
                for track in children {
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
                AppLogger.network.info("Total duration updated to \(duration)s based on \(children.count) tracks")
            } else if children.count == 1, let firstTrack = children.first {
                AppLogger.network.info("Single-file folder detected, will attempt AVFoundation on child track: \(firstTrack.Id)")
            }
        }

        if chapters.count <= 1 {
            AppLogger.network.info("Still have <= 1 chapter, attempting AVFoundation extraction...")
            if let token = connection.token {
                var streamId = bookId

                if item.itemType == "MusicAlbum" || item.itemType == "AudioBook" || item.itemType == "Folder" {
                    let children = try await fetchChildAudioItems(parentId: bookId)
                    if let firstTrack = children.first {
                        streamId = firstTrack.Id
                    } else if (item.RunTimeTicks ?? 0) == 0 {
                        AppLogger.network.error("Error: Folder-based book has no audio children to stream")
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
                    id: "full_book",
                    start: 0,
                    end: duration > 0 ? duration : 0,
                    title: item.Name
                )
            )
        }

        var book = mapJellyfinItemToBook(item, libraryId: libraryId, base: base)
        book.chapters = chapters

        if duration != book.duration {
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
                chapters: book.chapters,
                publisher: book.publisher,
                progress: newProgress,
                currentTime: book.currentTime,
                isFinished: book.isFinished,
                lastUpdate: book.lastUpdate,
                libraryId: book.libraryId,
                providerId: book.providerId,
                rawMetadata: book.rawMetadata
            )
        }
        return book
    }

    func fetchCollections(libraryId: String?) async throws -> [Collection] {
        return []
    }

    func fetchSeries(libraryId: String) async throws -> [Series] {
        return []
    }

    func fetchUserMediaProgress(libraryId: String) async throws -> [UserMediaProgress] {
        return []
    }

    func getAudioURL(for book: Book) -> URL? {
        guard let token = connection.token else { return nil }
        let base = normalizeServerURL(connection.url)
        return URL(string: "\(base)/Audio/\(book.id)/stream?static=true&api_key=\(token)")
    }

    func getStreamingHeaders() -> [String: String] {
        return [
            "Authorization": buildAuthHeaderValue(),
            "X-Emby-Token": connection.token ?? "",
        ]
    }

    func startPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo {
        let fullBook = try await fetchFullBookDetails(bookId: book.id, libraryId: book.libraryId)

        let children = try await fetchChildAudioItems(parentId: book.id)
        let tracks: [AudioTrackInfo]

        if children.isEmpty {
            let url = getAudioURL(for: fullBook)?.absoluteString ?? ""
            tracks = [
                AudioTrackInfo(
                    index: 0,
                    startOffset: 0,
                    duration: fullBook.duration ?? 0,
                    contentUrl: url,
                    mimeType: "audio/mpeg"
                )
            ]
        } else {
            var currentOffset: Double = 0
            tracks = children.enumerated().map { index, track in
                let trackDuration = Double(track.RunTimeTicks ?? 0) / 10_000_000.0
                let url = "\(normalizeServerURL(connection.url))/Audio/\(track.Id)/stream?static=true&api_key=\(connection.token ?? "")"
                let info = AudioTrackInfo(
                    index: index,
                    startOffset: currentOffset,
                    duration: trackDuration,
                    contentUrl: url,
                    mimeType: "audio/mpeg"
                )
                currentOffset += trackDuration
                return info
            }
        }

        return PlaybackSessionInfo(
            sessionId: UUID().uuidString,
            audioTracks: tracks,
            chapters: fullBook.chapters ?? []
        )
    }

    func updatePlaybackProgress(
        book: Book,
        sessionId: String?,
        currentTime: TimeInterval,
        isFinished: Bool,
        timeListened: TimeInterval
    ) async throws {
        guard let userId = connection.userId, let _ = connection.token else { return }
        let base = normalizeServerURL(connection.url)
        let positionTicks = Int64(currentTime * 10_000_000)

        guard let url = URL(string: "\(base)/Users/\(userId)/PlayingItems/\(book.id)/Progress?PositionTicks=\(positionTicks)") else {
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        addAuthHeaders(&request)

        _ = try? await performDataTask(for: request)

        if isFinished {
            guard let playedUrl = URL(string: "\(base)/Users/\(userId)/PlayedItems/\(book.id)") else {
                return
            }
            var playedRequest = URLRequest(url: playedUrl)
            playedRequest.httpMethod = "POST"
            addAuthHeaders(&playedRequest)
            _ = try? await performDataTask(for: playedRequest)
        }
    }

    private func performDataTask(for request: URLRequest, retryCount: Int = 3) async throws -> (Data, URLResponse) {
        var currentRetry = 0
        while true {
            do {
                if currentRetry > 0 {
                    AppLogger.network.warning(
                        "Executing request: \(request.url?.redacted.absoluteString ?? "unknown") (Attempt \(currentRetry + 1))"
                    )
                }
                return try await session.data(for: request)
            } catch {
                let nsError = error as NSError
                let retryableCodes = [-1001, -1003, -1005, -1009]

                if currentRetry < retryCount && retryableCodes.contains(nsError.code) {
                    currentRetry += 1
                    let delay = pow(2.0, Double(currentRetry))
                    AppLogger.network.error(
                        "Request failed with error \(nsError.code). Retrying in \(delay)s... (Attempt \(currentRetry + 1)/\(retryCount + 1))"
                    )
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw error
            }
        }
    }

    private func fetchChildAudioItems(parentId: String) async throws -> [JellyfinItem] {
        guard let userId = connection.userId else { return [] }
        let base = normalizeServerURL(connection.url)

        guard var components = URLComponents(string: "\(base)/Users/\(userId)/Items") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "ParentId", value: parentId),
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Fields", value: "RunTimeTicks"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
        ]

        guard let requestURL = components.url else {
            return []
        }

        var request = URLRequest(url: requestURL)
        addAuthHeaders(&request)

        let (data, response) = try await performDataTask(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return []
        }

        let result = try JSONDecoder().decode(JellyfinItemsResponse.self, from: data)
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
                    let duration = CMTimeGetSeconds(timeRange.duration)

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
                            end: start + duration,
                            title: title
                        )
                    )
                }
                if !chapters.isEmpty { break }
            }
        } catch {
            AppLogger.network.error("Chapter extraction failed: \(error)")
        }

        return chapters.sorted { $0.start < $1.start }
    }

    private func mapJellyfinItemToBook(_ item: JellyfinItem, libraryId: String, base: String) -> Book {
        let isEbook = item.itemType == "Book"
        let duration = isEbook ? 0 : Double(item.RunTimeTicks ?? 0) / 10_000_000.0
        let currentTime = isEbook ? 0 : Double(item.UserData?.PlaybackPositionTicks ?? 0) / 10_000_000.0
        let audioProgress = duration > 0 ? (currentTime / duration) : 0
        let ebookProgress: Double? = isEbook ? ((item.UserData?.PlayedPercentage ?? 0) / 100.0) : nil

        var coverURL: URL?
        if let tags = item.ImageTags, !tags.isEmpty {
            coverURL = URL(string: "\(base)/Items/\(item.Id)/Images/Primary")
        }

        let author = item.AlbumArtist ?? item.AlbumArtists?.first?.Name ?? item.ArtistItems?.first?.Name ?? "Unknown Author"
        let narrator = isEbook ? nil : item.ArtistItems?.first(where: { $0.Name != author })?.Name

        var releaseDate: Date? = nil
        if let year = item.ProductionYear {
            var components = DateComponents()
            components.year = year
            components.month = 1
            components.day = 1
            releaseDate = Calendar.current.date(from: components)
        }

        var seriesInfo: SeriesInfo? = nil
        if let seriesName = item.SeriesName {
            seriesInfo = SeriesInfo(name: seriesName, sequence: item.IndexNumber.map { "\($0)" })
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
            ebookProgress: ebookProgress,
            dateAdded: Date(),
            releaseDate: releaseDate,
            description: item.Overview,
            genres: item.Genres ?? [],
            chapters: [],
            publisher: item.Studios?.first?.Name,
            progress: audioProgress,
            currentTime: currentTime,
            isFinished: item.UserData?.Played ?? false,
            lastUpdate: Date(),
            libraryId: libraryId,
            providerId: connection.id,
            source: .jellyfin,
            rawMetadata: nil
        )
    }

    func downloadEbook(for book: Book, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        if let cached = LocalEbookImporter.shared.cachedEbook(forBookId: book.id) {
            onProgress?(1)
            return cached
        }

        guard connection.token != nil else { throw ProviderError.unauthorized }
        let base = normalizeServerURL(connection.url)

        guard let downloadURL = URL(string: "\(base)/Items/\(book.id)/Download") else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: downloadURL)
        addAuthHeaders(&request)

        let response: URLResponse
        let tempURL: URL
        if let onProgress {

            let delegate = URLSessionDownloadProgressDelegate(progressHandler: onProgress)
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let (url, http) = try await delegate.awaitResult {
                session.downloadTask(with: request)
            }
            tempURL = url
            response = http
        } else {
            (tempURL, response) = try await URLSession.shared.download(for: request)
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ProviderError.invalidResponse
        }

        var filename = "\(book.title.replacingOccurrences(of: "/", with: "-")).epub"
        if let header = http.allHeaderFields["Content-Disposition"] as? String,
            let range = header.range(of: "filename=\"") ?? header.range(of: "filename=")
        {
            let start = range.upperBound
            let end = header[start...].firstIndex(of: "\"") ?? header.endIndex
            filename = String(header[start..<end])
        }

        return try LocalEbookImporter.shared.cacheRemoteEbook(
            tempURL: tempURL,
            preferredFilename: filename,
            bookIdentifier: book.id
        )
    }

    func updateEbookProgress(for book: Book, progress: Double, epubLocator: String?) async throws {
        guard let userId = connection.userId else { throw ProviderError.unauthorized }
        let base = normalizeServerURL(connection.url)

        guard let url = URL(string: "\(base)/Users/\(userId)/Items/\(book.id)/UserData") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuthHeaders(&request)

        let body: [String: Any] = [
            "PlayedPercentage": max(0, min(100, progress * 100)),
            "Played": progress >= 0.99,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await performDataTask(for: request)

        if progress >= 0.99,
            let playedURL = URL(string: "\(base)/Users/\(userId)/PlayedItems/\(book.id)")
        {
            var playedRequest = URLRequest(url: playedURL)
            playedRequest.httpMethod = "POST"
            addAuthHeaders(&playedRequest)
            _ = try? await performDataTask(for: playedRequest)
        }
    }

    func fetchEbookProgress(for book: Book) async throws -> (progress: Double, locator: String?, updatedAt: Date?, isAbandoned: Bool)? {
        guard let userId = connection.userId else { return nil }
        let base = normalizeServerURL(connection.url)

        guard let url = URL(string: "\(base)/Users/\(userId)/Items/\(book.id)?Fields=UserData") else { return nil }
        var request = URLRequest(url: url)
        addAuthHeaders(&request)

        guard let (data, response) = try? await performDataTask(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let item = try? JSONDecoder().decode(JellyfinItem.self, from: data)
        else {
            return nil
        }

        let percentage = (item.UserData?.PlayedPercentage ?? 0) / 100.0
        let played = item.UserData?.Played ?? false
        return (progress: percentage, locator: nil, updatedAt: nil, isAbandoned: played)
    }

    func fetchAudiobookProgress(
        for book: Book
    ) async throws -> (positionSeconds: TimeInterval, percentage: Double, trackIndex: Int?, updatedAt: Date?, isAbandoned: Bool)? {
        guard let userId = connection.userId else { return nil }
        let base = normalizeServerURL(connection.url)

        guard let url = URL(string: "\(base)/Users/\(userId)/Items/\(book.id)?Fields=UserData") else { return nil }
        var request = URLRequest(url: url)
        addAuthHeaders(&request)

        guard let (data, response) = try? await performDataTask(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let item = try? JSONDecoder().decode(JellyfinItem.self, from: data)
        else {
            return nil
        }

        let positionSeconds = Double(item.UserData?.PlaybackPositionTicks ?? 0) / 10_000_000.0
        let percentage = (item.UserData?.PlayedPercentage ?? 0) / 100.0
        let played = item.UserData?.Played ?? false
        return (positionSeconds: positionSeconds, percentage: percentage, trackIndex: nil, updatedAt: nil, isAbandoned: played)
    }
}

private struct JellyfinItemsResponse: Decodable {
    let Items: [JellyfinItem]
    let TotalRecordCount: Int?
}

private struct JellyfinItem: Decodable {
    let Id: String
    let ParentId: String?
    let Name: String
    let itemType: String
    let MediaType: String?
    let CollectionType: String?
    let RunTimeTicks: Int64?
    let ProductionYear: Int?
    let Overview: String?
    let AlbumArtist: String?
    let AlbumArtists: [JellyfinNameIdPair]?
    let ArtistItems: [JellyfinNameIdPair]?
    let ImageTags: [String: String]?
    let Chapters: [JellyfinChapter]?
    let UserData: JellyfinUserData?
    let SeriesName: String?
    let IndexNumber: Int?
    let Studios: [JellyfinNameIdPair]?
    let Genres: [String]?
    let ChildCount: Int?
    let MediaSources: [JellyfinMediaSource]?

    enum CodingKeys: String, CodingKey {
        case Id, ParentId, Name, MediaType, CollectionType, RunTimeTicks, ProductionYear, Overview
        case AlbumArtist, AlbumArtists, ArtistItems, ImageTags, Chapters, UserData
        case SeriesName, IndexNumber, Studios, Genres, ChildCount, MediaSources
        case itemType = "Type"
    }
}

private struct JellyfinMediaSource: Decodable {
    let Id: String
    let RunTimeTicks: Int64?
    let Path: String?
    let Container: String?
}

private struct JellyfinChapter: Decodable {
    let Name: String
    let StartPositionTicks: Int64
}

private struct JellyfinUserData: Decodable {
    let PlaybackPositionTicks: Int64?
    let Played: Bool?
    let PlayedPercentage: Double?
}

private struct JellyfinNameIdPair: Decodable {
    let Name: String
    let Id: String
}
