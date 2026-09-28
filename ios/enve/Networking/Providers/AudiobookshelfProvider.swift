import Foundation
import Logging

#if canImport(UIKit)
import UIKit
#endif

enum ABSMediaTypeClassifier {
    static func classify(
        libraryMediaType: String?,
        itemMediaType: String?,
        hasAudio: Bool,
        ebookFormat: String?,
        hasEbookFile: Bool
    ) -> AppMediaType {
        let libraryType = libraryMediaType?.lowercased()
        if libraryType == "podcast" || libraryType == "podcasts" {
            return .podcast
        }
        let itemType = itemMediaType?.lowercased()
        if itemType == "podcast" || itemType == "podcasts" {
            return .podcast
        }
        if itemType == "ebook" {
            return .ebook
        }
        if itemType == "audiobook" {
            return .audiobook
        }
        if hasAudio {
            return .audiobook
        }
        if hasEbookFile || !(ebookFormat?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            return .ebook
        }
        return .audiobook
    }
}

enum ABSPodcastEpisodeMerge {
    /// Returns feed episodes not represented by a stored ABS episode, preserving feed order.
    static func feedOnlyEpisodes(
        stored: [AudiobookshelfProvider.PodcastItem.StoredEpisode],
        feed: [RSSPodcastParser.ParsedEpisode]
    ) -> [RSSPodcastParser.ParsedEpisode] {
        var episodes: [RSSPodcastParser.ParsedEpisode] = []
        var seenIDs = Set<String>()
        var indexByGUID: [String: Int] = [:]
        var indexByEnclosure: [String: Int] = [:]
        var indicesByTitle: [String: [Int]] = [:]

        for episode in feed {
            guard seenIDs.insert(episode.id).inserted else { continue }
            let index = episodes.count
            episodes.append(episode)
            indexByGUID[episode.id] = index
            if let enclosure = normalizedEnclosure(episode.audioURL?.absoluteString), indexByEnclosure[enclosure] == nil {
                indexByEnclosure[enclosure] = index
            }
            indicesByTitle[normalizedTitle(episode.title), default: []].append(index)
        }

        var claimed = Set<Int>()
        for episode in stored {
            if let guid = episode.guid?.trimmingCharacters(in: .whitespacesAndNewlines), !guid.isEmpty,
                let index = indexByGUID[guid], !claimed.contains(index)
            {
                claimed.insert(index)
                continue
            }
            if let enclosure = normalizedEnclosure(episode.enclosureURL),
                let index = indexByEnclosure[enclosure], !claimed.contains(index)
            {
                claimed.insert(index)
                continue
            }
            guard let publishedAt = episode.publishedAt, let title = episode.title else { continue }
            let normalized = normalizedTitle(title)
            guard !normalized.isEmpty else { continue }
            let twin = indicesByTitle[normalized]?.first { index in
                guard !claimed.contains(index), let feedDate = episodes[index].publishedDate else { return false }
                return abs(feedDate.timeIntervalSince(publishedAt)) <= 86_400
            }
            if let twin { claimed.insert(twin) }
        }

        return episodes.indices.filter { !claimed.contains($0) }.map { episodes[$0] }
    }

    private static func normalizedEnclosure(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        // Feeds move between http and https without changing the episode.
        if let separator = value.range(of: "://") {
            return String(value[separator.upperBound...])
        }
        return value
    }

    private static func normalizedTitle(_ title: String) -> String {
        title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

class AudiobookshelfProvider: IncrementalCatalogProvider, PlaybackSessionProvider, AudiobookProgressProvider,
    EbookProgressProvider, EbookDownloadProvider, @unchecked Sendable
{
    var connection: ServerConnection

    var capabilities: ProviderCapabilities {
        [
            .fullImport, .pagedImport, .streamingImport, .deltaImport,
            .recentBooks, .series, .collections,
            .audiobookProgressPull, .audiobookProgressPush, .ebookProgressPull, .ebookProgressPush,
            .downloads, .coverAuthQuery, .backgroundOperation,
        ]
    }

    var onTokenUpdated: ((ServerConnection) -> Void)?

    private let absService = AudiobookshelfService.shared

    private var libraryMediaTypes: [String: String] = [:]
    private var itemAudioDurations: [String: TimeInterval] = [:]

    private lazy var credentialsActor = ABSCredentialsActor(provider: self)

    init(connection: ServerConnection) {
        self.connection = connection
    }

    var tokenSnapshot: ABSTokenSnapshot {
        ABSTokenSnapshot(token: connection.token, refreshToken: storedRefreshToken())
    }

    private var refreshTokenKey: String {
        "abs_refresh_\(connection.id.uuidString)"
    }

    private func storedRefreshToken() -> String? {
        KeychainHelper.shared.get(refreshTokenKey)
    }

    private func saveRefreshToken(_ refreshToken: String?) {
        guard let refreshToken, !refreshToken.isEmpty else { return }
        KeychainHelper.shared.set(refreshToken, key: refreshTokenKey)
    }

    private func resolvedPassword() -> String? {
        if let pw = connection.password, !pw.isEmpty { return pw }
        return KeychainHelper.shared.get("abs_password_\(connection.id.uuidString)")
    }

    func performTokenRefresh() async throws -> ABSCredentials {
        if let refreshToken = storedRefreshToken(), !refreshToken.isEmpty {
            do {
                let refreshed = try await absService.refreshToken(
                    serverURL: connection.url,
                    refreshToken: refreshToken,
                    customHeaders: connection.customHeaders ?? [:]
                )
                connection.token = refreshed.accessToken
                connection.lastVerified = Date()
                connection.isConnected = true
                saveRefreshToken(refreshed.refreshToken ?? refreshToken)
                await MainActor.run { onTokenUpdated?(connection) }
                AppLogger.network.info("[ABS Provider] Proactively refreshed access token")

                if let jwt = ABSJWT(refreshed.accessToken), let exp = jwt.exp {
                    return .bearer(
                        accessToken: refreshed.accessToken,
                        refreshToken: refreshed.refreshToken ?? refreshToken,
                        expiresAt: exp
                    )
                }
                return .legacy(token: refreshed.accessToken)
            } catch {
                AppLogger.network.error("[ABS Provider] Refresh token flow failed: \(error.localizedDescription)")
            }
        }

        if let username = connection.username, !username.isEmpty,
            let password = resolvedPassword(),
            connection.authMode != .token,
            connection.authMode != .sso
        {
            let success = try await loginWithCredentials(username: username, password: password)
            if success, let token = connection.token {
                if let jwt = ABSJWT(token), let exp = jwt.exp,
                    let rt = storedRefreshToken()
                {
                    return .bearer(accessToken: token, refreshToken: rt, expiresAt: exp)
                }
                return .legacy(token: token)
            }
        }

        throw ProviderError.unauthorized
    }

    private func loginWithCredentials(username: String, password: String) async throws -> Bool {
        guard let baseURL = URL(string: connection.url) else {
            throw ProviderError.invalidURL
        }

        let loginURL = baseURL.appendingPathComponent("login")
        var loginRequest = URLRequest(url: loginURL)
        loginRequest.httpMethod = "POST"
        loginRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        loginRequest.setValue("true", forHTTPHeaderField: "x-return-tokens")

        let body = ["username": username, "password": password]
        loginRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await InsecureURLSession.shared.data(for: loginRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }

        if httpResponse.statusCode == 200 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let user = json["user"] as? [String: Any]
            {
                let accessToken = user["accessToken"] as? String
                let refreshToken = user["refreshToken"] as? String
                let legacyToken = user["token"] as? String

                if let authToken = accessToken ?? legacyToken, !authToken.isEmpty {
                    AppLogger.network.info("[ABS Provider] Login successful")

                    connection.token = authToken
                    connection.password = password
                    connection.isConnected = true
                    connection.lastVerified = Date()
                    saveRefreshToken(refreshToken)

                    await MainActor.run {
                        onTokenUpdated?(connection)
                    }

                    return true
                }
            }
        } else if httpResponse.statusCode == 401 {
            throw ProviderError.unauthorized
        }

        throw ProviderError.invalidResponse
    }

    func validateConnection() async throws -> Bool {
        guard let baseURL = URL(string: connection.url) else {
            throw ProviderError.invalidURL
        }

        let creds: ABSCredentials
        do {
            creds = try await credentialsActor.freshCredentials
        } catch {
            creds = connection.token.map { ABSCredentials.legacy(token: $0) } ?? ABSCredentials.legacy(token: "")
        }

        let validateURL = baseURL.appendingPathComponent("api/authorize")
        var validateRequest = URLRequest(url: validateURL)
        validateRequest.httpMethod = "POST"

        if let customHeaders = connection.customHeaders {
            for (key, value) in customHeaders {
                validateRequest.setValue(value, forHTTPHeaderField: key)
            }
        }

        validateRequest.setValue(creds.authorizationHeader, forHTTPHeaderField: "Authorization")

        let (_, validateResponse) = try await InsecureURLSession.shared.data(for: validateRequest)
        guard let validationHTTP = validateResponse as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }
        if validationHTTP.statusCode == 200 || validationHTTP.statusCode == 204 {
            connection.isConnected = true
            connection.lastVerified = Date()
            return true
        }
        guard validationHTTP.statusCode == 401 || validationHTTP.statusCode == 403 else { return false }

        let freshCreds = try await credentialsActor.forceRefresh()
        connection.token = freshCreds.accessToken
        validateRequest.setValue(freshCreds.authorizationHeader, forHTTPHeaderField: "Authorization")
        let (_, retryResponse) = try await InsecureURLSession.shared.data(for: validateRequest)
        guard let retryHTTP = retryResponse as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }
        if retryHTTP.statusCode == 200 || retryHTTP.statusCode == 204 {
            connection.isConnected = true
            connection.lastVerified = Date()
            return true
        }
        if retryHTTP.statusCode == 401 || retryHTTP.statusCode == 403 {
            throw ProviderError.unauthorized
        }

        return false
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var mutableRequest = request
        mutableRequest.cachePolicy = .reloadIgnoringLocalCacheData

        if let customHeaders = connection.customHeaders {
            for (key, value) in customHeaders {
                mutableRequest.setValue(value, forHTTPHeaderField: key)
            }
        }

        do {
            let creds = try await credentialsActor.freshCredentials
            mutableRequest.setValue(creds.authorizationHeader, forHTTPHeaderField: "Authorization")
            if connection.token != creds.accessToken {
                connection.token = creds.accessToken
                connection.isConnected = true
            }
        } catch {
            if let token = connection.token {
                mutableRequest.setValue(
                    token.contains(".") ? "Bearer \(token)" : token,
                    forHTTPHeaderField: "Authorization"
                )
            }
        }

        let (data, response) = try await InsecureURLSession.shared.data(for: mutableRequest)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
            AppLogger.network.info("[ABS Provider] Got 401 despite proactive refresh - forcing token refresh...")
            do {
                let freshCreds = try await credentialsActor.forceRefresh()
                var retryRequest = mutableRequest
                retryRequest.setValue(freshCreds.authorizationHeader, forHTTPHeaderField: "Authorization")
                connection.token = freshCreds.accessToken
                connection.isConnected = true
                return try await InsecureURLSession.shared.data(for: retryRequest)
            } catch {
                AppLogger.network.error("[ABS Provider] Force refresh after 401 failed: \(error.localizedDescription)")
                connection.isConnected = false
            }
        } else if let httpResponse = response as? HTTPURLResponse,
            200...299 ~= httpResponse.statusCode
        {
            connection.isConnected = true
        }

        return (data, response)
    }

    private static let absDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let ms = try? container.decode(Int64.self) {
                return Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
            } else if let ms = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: ms / 1000.0)
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected millisecond timestamp")
        }
        return decoder
    }()

    private struct LibrariesResponse: Decodable {
        let libraries: [ABSLibrary]
    }

    private struct ABSLibrary: Decodable {
        let id: String
        let name: String
        let mediaType: String

        enum CodingKeys: String, CodingKey { case id, name, mediaType }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            mediaType = (try? c.decode(String.self, forKey: .mediaType)) ?? "book"
        }
    }

    private struct PageResponse<T: Decodable>: Decodable {
        let results: [T]
        let total: Int
        let page: Int
        let failures: Int
        let rejectedItems: [RejectedContentCandidate]

        enum CodingKeys: String, CodingKey { case results, total, page }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let decodedPage = (try? c.decode(Int.self, forKey: .page)) ?? 0
            let safe = (try? c.decode([RejectedDecodable<T>].self, forKey: .results)) ?? []
            var good: [T] = []
            var rejected: [RejectedContentCandidate] = []
            for (index, item) in safe.enumerated() {
                if let value = item.value {
                    good.append(value)
                } else if let failure = item.rejection {
                    rejected.append(
                        RejectedContentCandidate(
                            itemIdentifier: failure.itemIdentifier,
                            title: failure.title,
                            reason: failure.reason,
                            fallbackIdentifier: "page-\(decodedPage)-item-\(index)"
                        )
                    )
                }
            }
            if !rejected.isEmpty {
                AppLogger.network.error("\(rejected.count) item(s) failed to decode on this page")
            }
            results = good
            rejectedItems = rejected
            failures = rejected.count
            total = (try? c.decode(Int.self, forKey: .total)) ?? good.count
            page = decodedPage
        }
    }

    private struct FlexibleStringID: Decodable {
        let value: String

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                value = string
            } else if let int = try? container.decode(Int.self) {
                value = String(int)
            } else if let int64 = try? container.decode(Int64.self) {
                value = String(int64)
            } else {
                throw DecodingError.typeMismatch(
                    String.self,
                    .init(codingPath: decoder.codingPath, debugDescription: "Expected string or integer ID")
                )
            }
        }
    }

    private struct ABSItem: Decodable {
        let id: String
        let libraryId: String?
        let mediaType: String?
        let relPath: String?
        let media: Media
        let addedAt: Date?
        let updatedAt: Date?

        struct Media: Decodable {
            let metadata: Metadata
            let coverPath: String?
            let duration: Double?
            let size: Int64?
            let numTracks: Int?
            let numAudioFiles: Int?
            let numEpisodes: Int?
            let ebookFormat: String?
            let chapters: [Chapter]?
            let audioFiles: [AudioFile]?
            let episodes: [PodcastEpisode]?
            let ebookFile: EbookFile?
            let tags: [String]?

            enum CodingKeys: String, CodingKey {
                case metadata, coverPath, duration, size, numTracks, numAudioFiles, numEpisodes, ebookFormat
                case chapters, audioFiles, episodes, ebookFile, tags
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                metadata = try c.decode(Metadata.self, forKey: .metadata)
                coverPath = try c.decodeIfPresent(String.self, forKey: .coverPath)
                duration = try c.decodeIfPresent(Double.self, forKey: .duration)
                size = try c.decodeIfPresent(Int64.self, forKey: .size)
                numTracks = try c.decodeIfPresent(Int.self, forKey: .numTracks)
                numAudioFiles = try c.decodeIfPresent(Int.self, forKey: .numAudioFiles)
                numEpisodes = try c.decodeIfPresent(Int.self, forKey: .numEpisodes)
                ebookFormat = try c.decodeIfPresent(String.self, forKey: .ebookFormat)
                chapters = try c.decodeIfPresent([Chapter].self, forKey: .chapters)
                if let raw = try? c.decode([RejectedDecodable<AudioFile>].self, forKey: .audioFiles) {
                    audioFiles = raw.compactMap(\.value)
                } else {
                    audioFiles = nil
                }
                episodes = try c.decodeIfPresent([PodcastEpisode].self, forKey: .episodes)
                ebookFile = try c.decodeIfPresent(EbookFile.self, forKey: .ebookFile)
                tags = try c.decodeIfPresent([String].self, forKey: .tags)
            }
        }

        struct Metadata: Decodable {
            let title: String?
            let titleIgnorePrefix: String?
            let subtitle: String?
            let publishedYear: String?
            let publishedDate: String?
            let publisher: String?
            let description: String?
            let isbn: String?
            let asin: String?
            let language: String?
            let genres: [String]?
            let authorName: String?
            let narratorName: String?
            let seriesName: String?
            let authors: [Author]?
            let narrators: [String]?
            let series: [SeriesTag]?
            let author: String?
            let feedUrl: String?

            enum CodingKeys: String, CodingKey {
                case title, titleIgnorePrefix, subtitle, publishedYear, publishedDate
                case publisher, description, isbn, asin, language, genres
                case authorName, narratorName, seriesName
                case authors, narrators, series
                case author, feedUrl
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                title = try c.decodeIfPresent(String.self, forKey: .title)
                titleIgnorePrefix = try c.decodeIfPresent(String.self, forKey: .titleIgnorePrefix)
                subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
                publishedYear = try c.decodeIfPresent(String.self, forKey: .publishedYear)
                publishedDate = try c.decodeIfPresent(String.self, forKey: .publishedDate)
                publisher = try c.decodeIfPresent(String.self, forKey: .publisher)
                description = try c.decodeIfPresent(String.self, forKey: .description)
                isbn = try c.decodeIfPresent(String.self, forKey: .isbn)
                asin = try c.decodeIfPresent(String.self, forKey: .asin)
                language = try c.decodeIfPresent(String.self, forKey: .language)
                genres = try c.decodeIfPresent([String].self, forKey: .genres)
                authorName = try c.decodeIfPresent(String.self, forKey: .authorName)
                narratorName = try c.decodeIfPresent(String.self, forKey: .narratorName)
                seriesName = try c.decodeIfPresent(String.self, forKey: .seriesName)
                authors = try c.decodeIfPresent([Author].self, forKey: .authors)
                narrators = try c.decodeIfPresent([String].self, forKey: .narrators)
                series = try c.decodeIfPresent([SeriesTag].self, forKey: .series)
                author = try c.decodeIfPresent(String.self, forKey: .author)
                feedUrl = try c.decodeIfPresent(String.self, forKey: .feedUrl)
            }
        }

        struct Author: Decodable {
            let id: String
            let name: String
        }

        struct SeriesTag: Decodable {
            let id: String
            let name: String
            let sequence: String?
        }

        struct Chapter: Decodable {
            let id: Int
            let start: Double
            let end: Double
            let title: String
        }

        struct AudioFile: Decodable {
            let index: Int?
            let ino: String?
            let duration: Double?
            let chapters: [Chapter]?
            let metadata: FileMetadata?
            enum CodingKeys: String, CodingKey { case index, ino, duration, chapters, metadata }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                index = try c.decodeIfPresent(Int.self, forKey: .index)
                ino = try c.decodeIfPresent(FlexibleStringID.self, forKey: .ino)?.value
                duration = try c.decodeIfPresent(Double.self, forKey: .duration)
                chapters = try c.decodeIfPresent([Chapter].self, forKey: .chapters)
                metadata = try c.decodeIfPresent(FileMetadata.self, forKey: .metadata)
            }
            struct FileMetadata: Decodable {
                let filename: String?
            }
        }

        struct PodcastEpisode: Decodable {
            let id: String
            let title: String?
            let description: String?
            let pubDate: String?
            let guid: String?
            let enclosure: Enclosure?
            let audioFile: AudioFile?
            let publishedAt: Int64?
            let addedAt: Int64?
            let duration: Double?
            var effectiveDuration: Double? { duration ?? audioFile?.duration }

            struct Enclosure: Decodable {
                let url: String?
            }
        }

        struct EbookFile: Decodable {
            let ino: String?
            let ebookFormat: String?
        }
    }

    private struct ABSSeriesItem: Decodable {
        let id: String
        let name: String
        let numBooks: Int?
        let books: [SeriesBook]?

        struct SeriesBook: Decodable {
            let id: String
            let media: Media

            struct Media: Decodable {
                let metadata: Metadata
            }

            struct Metadata: Decodable {
                let seriesName: String?
            }
        }
    }

    private struct CollectionsResponse: Decodable {
        let results: [ABSCollectionItem]?
        let collections: [ABSCollectionItem]?

        var items: [ABSCollectionItem] { results ?? collections ?? [] }
    }

    private struct ABSCollectionItem: Decodable {
        let id: String
        let name: String
        let description: String?
        let libraryId: String?
        let books: [CollectionBook]?

        struct CollectionBook: Decodable {
            let id: String
        }
    }

    private struct ABSProgressItem: Decodable {
        let id: String
        let libraryItemId: String?
        let episodeId: String?
        let currentTime: Double?
        let progress: Double?
        let isFinished: Bool?
        let duration: Double?
        let lastUpdate: Double?
        let ebookProgress: Double?
        let ebookLocation: String?

        var hasEbookPosition: Bool {
            ABSMediaProgress.hasEbookPosition(ebookProgress: ebookProgress, ebookLocation: ebookLocation)
        }

        func ebookFraction(itemHasAudio: Bool) -> Double? {
            ABSMediaProgress.ebookFraction(ebookProgress: ebookProgress, ebookLocation: ebookLocation, progress: progress, itemHasAudio: itemHasAudio)
        }

        var resolvedIsFinished: Bool {
            if isFinished == true || (progress ?? 0) >= Book.finishedProgressThreshold {
                return true
            }
            guard let duration, duration > 0, let currentTime else { return false }
            return currentTime >= duration * Book.finishedProgressThreshold
        }
    }

    func fetchLibraries() async throws -> [Library] {
        guard let baseURL = URL(string: connection.url) else {
            throw ProviderError.unauthorized
        }

        let url = baseURL.appendingPathComponent("api/libraries")
        let request = URLRequest(url: url)
        let (data, response) = try await performRequest(request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError.invalidResponse
        }

        let decoded: LibrariesResponse
        do {
            decoded = try Self.absDecoder.decode(LibrariesResponse.self, from: data)
        } catch {
            AppLogger.network.error("fetchLibraries decode failed: \(error)")
            throw error
        }

        AppLogger.network.info("Fetched \(decoded.libraries.count) libraries")

        let filtered = decoded.libraries.filter {
            let mt = $0.mediaType.lowercased()
            return mt == "book" || mt == "audiobook" || mt == "podcast" || mt == "podcasts"
        }

        for lib in filtered {
            libraryMediaTypes[lib.id] = lib.mediaType
        }

        return filtered.map { lib in
            Library(id: lib.id, name: lib.name, type: lib.mediaType, providerId: connection.id)
        }
    }

    func fetchBooks(libraryId: String) async throws -> [Book] {
        return try await fetchBooks(libraryId: libraryId, onBatch: nil)
    }

    func makeCatalogBatchSource(
        libraryId: String,
        resumeAfter: String?,
        expectedSnapshotIdentifier: String?
    ) async throws -> LibraryCatalogBatchSource {
        guard let baseURL = URL(string: connection.url),
            let token = connection.token, !token.isEmpty
        else { throw ProviderError.unauthorized }

        let progressList = (try? await fetchUserMediaProgress(libraryId: libraryId)) ?? []
        let progressMap = Dictionary(
            progressList.map { ($0.libraryItemId, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        let libraryMediaType = libraryMediaTypes[libraryId]
        let firstPage = try await catalogPage(
            libraryId: libraryId,
            baseURL: baseURL,
            token: token,
            page: 0,
            progressMap: progressMap,
            libraryMediaType: libraryMediaType
        )
        return LibraryCatalogBatchSource.paged(
            firstPage: firstPage,
            pageSize: 500,
            pageConcurrency: 6,
            resumeAfter: resumeAfter,
            expectedSnapshotIdentifier: expectedSnapshotIdentifier,
            fetchPage: {
                try await self.catalogPage(
                    libraryId: libraryId,
                    baseURL: baseURL,
                    token: token,
                    page: $0,
                    progressMap: progressMap,
                    libraryMediaType: libraryMediaType
                )
            }
        )
    }

    private func catalogPage(
        libraryId: String,
        baseURL: URL,
        token: String,
        page: Int,
        progressMap: [String: UserMediaProgress],
        libraryMediaType: String?
    ) async throws -> LibraryCatalogPage {
        let pageSize = 500
        let response = try await fetchPage(
            libraryId: libraryId,
            baseURL: baseURL,
            token: token,
            page: page,
            limit: pageSize
        )
        let books = response.results.flatMap { item in
            convertItemToBooks(
                item,
                libraryId: libraryId,
                baseURL: baseURL,
                token: token,
                libraryMediaType: libraryMediaType
            ).map { incoming in
                var book = incoming
                if let progress = progressMap[book.partKey ?? book.id] ?? progressMap[book.id] {
                    Self.applyServerProgress(progress, to: &book)
                }
                return book
            }
        }
        let rawCount = response.results.count + response.failures
        return LibraryCatalogPage(
            books: books,
            totalCount: response.total,
            isLast: rawCount < pageSize || (page + 1) * pageSize >= response.total,
            isComplete: response.failures == 0
        )
    }

    func fetchBookBatches(libraryId: String) -> AsyncThrowingStream<LibraryFetchBatchResult, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let baseURL = URL(string: connection.url),
                        let token = connection.token, !token.isEmpty
                    else {
                        throw ProviderError.unauthorized
                    }

                    let progressList: [UserMediaProgress]
                    do {
                        progressList = try await self.fetchUserMediaProgress(libraryId: libraryId)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        progressList = []
                    }
                    let progressMap = Dictionary(
                        progressList.map { ($0.libraryItemId, $0) },
                        uniquingKeysWith: { _, b in b }
                    )

                    let limit = 500
                    let iterationCeiling = 2_000
                    let pageConcurrency = 6
                    let libType = self.libraryMediaTypes[libraryId]

                    let firstPage = try await self.fetchPage(libraryId: libraryId, baseURL: baseURL, token: token, page: 0, limit: limit)
                    try Task.checkCancellation()

                    var loadedSoFar = 0
                    let totalCount = firstPage.total

                    let firstBatch = firstPage.results.flatMap { item -> [Book] in
                        self.convertItemToBooks(item, libraryId: libraryId, baseURL: baseURL, token: token, libraryMediaType: libType).map {
                            book in
                            var book = book
                            if let p = progressMap[book.partKey ?? book.id] ?? progressMap[book.id] {
                                Self.applyServerProgress(p, to: &book)
                            }
                            return book
                        }
                    }
                    loadedSoFar += firstBatch.count
                    continuation.yield(
                        LibraryFetchBatchResult(
                            books: firstBatch,
                            loadedSoFar: loadedSoFar,
                            totalCount: totalCount
                        )
                    )

                    let firstRaw = firstPage.results.count + firstPage.failures
                    if firstRaw >= limit {
                        let serverProvidedTotal = firstPage.total > firstRaw
                        let neededPagesFromTotal =
                            serverProvidedTotal
                            ? max(1, (firstPage.total + limit - 1) / limit)
                            : iterationCeiling + 1
                        let totalPages = min(iterationCeiling + 1, neededPagesFromTotal)
                        if serverProvidedTotal && neededPagesFromTotal > totalPages {
                            AppLogger.network.error(
                                "[ABS] Library has \(firstPage.total) items, exceeds \(iterationCeiling * limit)-item runaway guard. Server may be reporting an unbounded total."
                            )
                        }

                        var nextPage = 1
                        var sawShortPage = false
                        while nextPage < totalPages && !sawShortPage {
                            try Task.checkCancellation()
                            let chunkEnd = min(nextPage + pageConcurrency, totalPages)
                            let pages = Array(nextPage..<chunkEnd)
                            let pageBatches = try await self.fetchPagesConcurrently(
                                pages: pages,
                                libraryId: libraryId,
                                baseURL: baseURL,
                                token: token,
                                limit: limit,
                                libType: libType
                            )

                            for pageBatch in pageBatches {
                                var mergedBooks: [Book] = []
                                mergedBooks.reserveCapacity(pageBatch.books.count)
                                for var book in pageBatch.books {
                                    if let p = progressMap[book.partKey ?? book.id] ?? progressMap[book.id] {
                                        Self.applyServerProgress(p, to: &book)
                                    }
                                    mergedBooks.append(book)
                                }
                                loadedSoFar += mergedBooks.count
                                continuation.yield(
                                    LibraryFetchBatchResult(
                                        books: mergedBooks,
                                        loadedSoFar: loadedSoFar,
                                        totalCount: totalCount
                                    )
                                )
                                if pageBatch.rawCount < limit {
                                    sawShortPage = true
                                }
                            }
                            nextPage = chunkEnd
                        }
                    }
                    AppLogger.network.info("[ABS] streamed \(loadedSoFar) books from library \(libraryId)")
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func fetchBooks(libraryId: String, onBatch: ((_ batch: LibraryFetchBatchResult) -> Void)?) async throws -> [Book] {
        guard let baseURL = URL(string: connection.url),
            let token = connection.token, !token.isEmpty
        else {
            throw ProviderError.unauthorized
        }

        let progressTask = Task<[UserMediaProgress], Never> {
            (try? await self.fetchUserMediaProgress(libraryId: libraryId)) ?? []
        }

        let limit = 500

        let iterationCeiling = 2_000
        let pageConcurrency = 6

        AppLogger.network.info("Starting paginated fetch for library \(libraryId)...")

        let firstPage = try await fetchPage(libraryId: libraryId, baseURL: baseURL, token: token, page: 0, limit: limit)
        AppLogger.network.info(
            "Library has \(firstPage.total) total items (\(firstPage.results.count) decoded, \(firstPage.failures) failed)"
        )

        let libType = self.libraryMediaTypes[libraryId]
        var allBooks: [Book] = []
        allBooks.reserveCapacity(firstPage.total)
        let firstBatch = firstPage.results.flatMap { item -> [Book] in
            self.convertItemToBooks(item, libraryId: libraryId, baseURL: baseURL, token: token, libraryMediaType: libType)
        }
        allBooks.append(contentsOf: firstBatch)
        onBatch?(LibraryFetchBatchResult(books: firstBatch, loadedSoFar: allBooks.count, totalCount: firstPage.total))
        self.publishImportProgress(libraryId: libraryId, loadedCount: allBooks.count, totalCount: firstPage.total)

        let pageCount = firstPage.results.count + firstPage.failures
        if pageCount >= limit {

            let serverProvidedTotal = firstPage.total > pageCount
            let neededPagesFromTotal = serverProvidedTotal ? max(1, (firstPage.total + limit - 1) / limit) : iterationCeiling + 1
            let totalPages = min(iterationCeiling + 1, neededPagesFromTotal)
            if serverProvidedTotal && neededPagesFromTotal > totalPages {
                AppLogger.network.error(
                    "[ABS] Library has \(firstPage.total) items, exceeds \(iterationCeiling * limit)-item runaway guard. Server may be reporting an unbounded total."
                )
            }
            var nextPage = 1
            var sawShortPage = false
            while nextPage < totalPages && !sawShortPage {
                let chunkEnd = min(nextPage + pageConcurrency, totalPages)
                let pages = Array(nextPage..<chunkEnd)
                let pageBatches = try await fetchPagesConcurrently(
                    pages: pages,
                    libraryId: libraryId,
                    baseURL: baseURL,
                    token: token,
                    limit: limit,
                    libType: libType
                )

                for pageBatch in pageBatches {
                    allBooks.append(contentsOf: pageBatch.books)
                    onBatch?(LibraryFetchBatchResult(books: pageBatch.books, loadedSoFar: allBooks.count, totalCount: firstPage.total))
                    if pageBatch.rawCount < limit {
                        sawShortPage = true
                    }
                }
                self.publishImportProgress(libraryId: libraryId, loadedCount: allBooks.count, totalCount: firstPage.total)
                AppLogger.network.info("Progress: \(allBooks.count)/\(firstPage.total) (pages \(nextPage)..<\(chunkEnd) done)")

                nextPage = chunkEnd
            }
        }

        AppLogger.network.info("Fetched \(allBooks.count) books from library \(libraryId)")

        let progressList = await progressTask.value
        if !progressList.isEmpty {
            let map = Dictionary(
                progressList.map { ($0.libraryItemId, $0) },
                uniquingKeysWith: { _, b in b }
            )
            for i in allBooks.indices {
                if let p = map[allBooks[i].partKey ?? allBooks[i].id] ?? map[allBooks[i].id] {
                    Self.applyServerProgress(p, to: &allBooks[i])
                }
            }
            AppLogger.network.info("Merged progress for \(progressList.count) items")
        }

        return allBooks
    }

    private struct PageBatch: Sendable {
        let books: [Book]
        let rawCount: Int
    }

    private func fetchPagesConcurrently(
        pages: [Int],
        libraryId: String,
        baseURL: URL,
        token: String,
        limit: Int,
        libType: String?
    ) async throws -> [PageBatch] {
        func fetchAndConvert(_ page: Int) async throws -> PageBatch {
            let resp = try await fetchPage(libraryId: libraryId, baseURL: baseURL, token: token, page: page, limit: limit)
            let books = resp.results.flatMap { item in
                convertItemToBooks(item, libraryId: libraryId, baseURL: baseURL, token: token, libraryMediaType: libType)
            }
            return PageBatch(books: books, rawCount: resp.results.count + resp.failures)
        }

        switch pages.count {
        case 0: return []
        case 1:
            async let a = fetchAndConvert(pages[0])
            return [try await a]
        case 2:
            async let a = fetchAndConvert(pages[0])
            async let b = fetchAndConvert(pages[1])
            return [try await a, try await b]
        case 3:
            async let a = fetchAndConvert(pages[0])
            async let b = fetchAndConvert(pages[1])
            async let c = fetchAndConvert(pages[2])
            return [try await a, try await b, try await c]
        case 4:
            async let a = fetchAndConvert(pages[0])
            async let b = fetchAndConvert(pages[1])
            async let c = fetchAndConvert(pages[2])
            async let d = fetchAndConvert(pages[3])
            return [try await a, try await b, try await c, try await d]
        case 5:
            async let a = fetchAndConvert(pages[0])
            async let b = fetchAndConvert(pages[1])
            async let c = fetchAndConvert(pages[2])
            async let d = fetchAndConvert(pages[3])
            async let e = fetchAndConvert(pages[4])
            return [try await a, try await b, try await c, try await d, try await e]
        default:
            async let a = fetchAndConvert(pages[0])
            async let b = fetchAndConvert(pages[1])
            async let c = fetchAndConvert(pages[2])
            async let d = fetchAndConvert(pages[3])
            async let e = fetchAndConvert(pages[4])
            async let f = fetchAndConvert(pages[5])
            return [try await a, try await b, try await c, try await d, try await e, try await f]
        }
    }

    private func fetchPage(libraryId: String, baseURL: URL, token: String, page: Int, limit: Int) async throws -> PageResponse<ABSItem> {
        guard
            var components = URLComponents(
                url: baseURL.appendingPathComponent("api/libraries/\(libraryId)/items"),
                resolvingAgainstBaseURL: false
            )
        else { throw ProviderError.invalidURL }
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "minified", value: "1"),
            URLQueryItem(name: "sort", value: "media.metadata.title"),
        ]
        guard let requestURL = components.url else { throw ProviderError.invalidURL }
        let request = URLRequest(url: requestURL)
        let (data, response) = try await performRequest(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            AppLogger.network.info("fetchBooks HTTP \(code) on page \(page)")
            throw ProviderError.invalidResponse
        }
        do {
            let page = try Self.absDecoder.decode(PageResponse<ABSItem>.self, from: data)
            updateRejectedContent(page, libraryId: libraryId)
            return page
        } catch {
            AppLogger.network.error("fetchBooks decode failed page \(page): \(error)")
            throw error
        }
    }

    private func publishImportProgress(libraryId: String, loadedCount: Int, totalCount: Int) {
        Task { @MainActor in
            let existing = AppState.shared.presentation.libraryImportProgress
            AppState.shared.presentation.libraryImportProgress = LibraryImportProgress(
                libraryId: libraryId,
                libraryName: existing?.libraryName ?? "Library",
                providerName: existing?.providerName ?? "",
                loadedCount: loadedCount,
                totalCount: totalCount,
                isComplete: false,
                phase: .indexing,
                startTime: existing?.startTime ?? Date()
            )
        }
    }

    struct PodcastShow: Identifiable {
        let id: String
        let title: String
        let author: String?
        let description: String?
        let coverURL: URL?
        let genres: [String]
        let episodes: [Book]
        let addedAt: Date?
        var feedURL: String?
    }

    struct PodcastItem {
        struct StoredEpisode {
            let id: String
            let title: String?
            let description: String?
            let guid: String?
            let enclosureURL: String?
            let publishedAt: Date?
            let addedAt: Date?
            let duration: Double?
            let audioFileIno: String?
        }

        let id: String
        let title: String
        let author: String?
        let description: String?
        let genres: [String]
        let hasCover: Bool
        let addedAt: Date?
        let feedURL: String?
        let storedEpisodeCount: Int?
        /// nil when the payload omits `media.episodes`, which the library list does for every show.
        let storedEpisodes: [StoredEpisode]?
    }

    static func decodePodcastItem(_ data: Data) throws -> PodcastItem {
        try podcastItem(from: absDecoder.decode(ABSItem.self, from: data))
    }

    private static func podcastItem(from item: ABSItem) -> PodcastItem {
        let metadata = item.media.metadata
        let feedURL = metadata.feedUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PodcastItem(
            id: item.id,
            title: metadata.title ?? "Unknown Podcast",
            author: metadata.author ?? metadata.authorName ?? metadata.authors?.map(\.name).joined(separator: ", "),
            description: metadata.description,
            genres: metadata.genres ?? [],
            hasCover: item.media.coverPath != nil,
            addedAt: item.addedAt,
            feedURL: feedURL?.isEmpty == false ? feedURL : nil,
            storedEpisodeCount: item.media.numEpisodes,
            storedEpisodes: item.media.episodes?.map { episode in
                PodcastItem.StoredEpisode(
                    id: episode.id,
                    title: episode.title,
                    description: episode.description,
                    guid: episode.guid,
                    enclosureURL: episode.enclosure?.url,
                    publishedAt: episode.publishedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                    addedAt: episode.addedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                    duration: episode.effectiveDuration,
                    audioFileIno: episode.audioFile?.ino
                )
            }
        )
    }

    func fetchPodcasts(libraryId: String) async throws -> [PodcastShow] {
        guard let baseURL = URL(string: connection.url),
            let token = connection.token, !token.isEmpty
        else {
            throw ProviderError.unauthorized
        }

        let progressList = (try? await fetchUserMediaProgress(libraryId: libraryId)) ?? []
        var progressMap: [String: UserMediaProgress] = [:]
        for p in progressList {
            if let epId = p.episodeId, !epId.isEmpty {
                progressMap["\(p.libraryItemId)/\(epId)"] = p
            } else {
                progressMap[p.libraryItemId] = p
            }
        }

        var items: [PodcastItem] = []
        var page = 0
        let limit = 50

        while true {
            guard
                var components = URLComponents(
                    url: baseURL.appendingPathComponent("api/libraries/\(libraryId)/items"),
                    resolvingAgainstBaseURL: false
                )
            else { throw ProviderError.invalidURL }
            components.queryItems = [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "minified", value: "0"),
                URLQueryItem(name: "expanded", value: "1"),
            ]

            guard let requestURL = components.url else { throw ProviderError.invalidURL }
            let request = URLRequest(url: requestURL)
            let (data, response) = try await performRequest(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw ProviderError.invalidResponse
            }

            let pageResp = try Self.absDecoder.decode(PageResponse<ABSItem>.self, from: data)
            updateRejectedContent(pageResp, libraryId: libraryId)
            items.append(contentsOf: pageResp.results.map(Self.podcastItem(from:)))

            if pageResp.results.count < limit { break }
            page += 1
            if page > 200 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let shows = await resolvePodcastShows(items, libraryId: libraryId, baseURL: baseURL, token: token, progress: progressMap)
        AppLogger.network.info("[ABS] Fetched \(shows.count) podcast shows")
        return shows
    }

    private static let podcastShowConcurrency = 4

    /// Feed-only episodes belong to no connection; this is the sentinel local books already use.
    private static let feedEpisodeProviderId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private func resolvePodcastShows(
        _ items: [PodcastItem],
        libraryId: String,
        baseURL: URL,
        token: String,
        progress: [String: UserMediaProgress]
    ) async -> [PodcastShow] {
        var shows = [PodcastShow?](repeating: nil, count: items.count)
        await withTaskGroup(of: (Int, PodcastShow).self) { group in
            var nextIndex = 0
            func addNextShow() {
                guard nextIndex < items.count else { return }
                let index = nextIndex
                nextIndex += 1
                group.addTask {
                    (
                        index,
                        await self.resolvePodcastShow(
                            items[index], libraryId: libraryId, baseURL: baseURL, token: token, progress: progress
                        )
                    )
                }
            }
            for _ in 0..<min(Self.podcastShowConcurrency, items.count) { addNextShow() }
            for await (index, show) in group {
                shows[index] = show
                addNextShow()
            }
        }
        return shows.compactMap { $0 }
    }

    private func resolvePodcastShow(
        _ item: PodcastItem,
        libraryId: String,
        baseURL: URL,
        token: String,
        progress: [String: UserMediaProgress]
    ) async -> PodcastShow {
        async let stored = storedEpisodes(for: item)
        async let feed = feedEpisodes(for: item)
        return await podcastShow(
            from: item,
            storedEpisodes: stored,
            feedEpisodes: feed,
            libraryId: libraryId,
            baseURL: baseURL,
            token: token,
            progress: progress
        )
    }

    private func storedEpisodes(for item: PodcastItem) async -> [PodcastItem.StoredEpisode] {
        if let episodes = item.storedEpisodes { return episodes }
        if item.storedEpisodeCount == 0 { return [] }
        do {
            return try await fetchPodcastItem(id: item.id).storedEpisodes ?? []
        } catch {
            AppLogger.network.warning(
                "[ABS] Podcast detail unavailable showDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: item.id)): \(error.localizedDescription)"
            )
            return []
        }
    }

    private func feedEpisodes(for item: PodcastItem) async -> [RSSPodcastParser.ParsedEpisode] {
        guard let feedURL = item.feedURL else { return [] }
        do {
            return try await RSSPodcastParser.shared.parseFeed(from: feedURL).episodes
        } catch {
            AppLogger.network.warning(
                "[ABS] Podcast feed unavailable showDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: item.id)): \(error.localizedDescription)"
            )
            return []
        }
    }

    private func fetchPodcastItem(id: String) async throws -> PodcastItem {
        guard let baseURL = URL(string: connection.url) else { throw ProviderError.invalidURL }
        let request = URLRequest(url: baseURL.appendingPathComponent("api/items/\(id)"))
        let (data, response) = try await performRequest(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError.invalidResponse
        }
        return try Self.decodePodcastItem(data)
    }

    /// Keeps stored episodes on ABS while routing feed-only episodes directly to their enclosures.
    func podcastShow(
        from item: PodcastItem,
        storedEpisodes: [PodcastItem.StoredEpisode],
        feedEpisodes: [RSSPodcastParser.ParsedEpisode],
        libraryId: String,
        baseURL: URL,
        token: String,
        progress: [String: UserMediaProgress]
    ) -> PodcastShow {
        let coverURL = coverURL(for: item.id, baseURL: baseURL, token: token, hasCover: item.hasCover)

        let stored: [Book] = storedEpisodes.compactMap { episode in
            guard let title = episode.title, !title.isEmpty else { return nil }
            var book = Book(
                id: "\(item.id)_\(episode.id)",
                title: title,
                author: item.author,
                duration: episode.duration ?? 0,
                coverURL: coverURL,
                partKey: item.id,
                audioFileIno: episode.audioFileIno,
                isPodcastEpisode: true,
                episodeId: episode.id,
                podcastLibraryItemId: item.id,
                podcastName: item.title,
                dateAdded: episode.publishedAt ?? episode.addedAt,
                description: episode.description,
                genres: item.genres,
                libraryId: libraryId,
                providerId: connection.id,
                backendId: connection.id.uuidString,
                source: .audiobookshelf
            )
            if let entry = progress["\(item.id)/\(episode.id)"] {
                book.currentTime = entry.currentTime
                book.isFinished = entry.isFinished
                book.lastUpdate = entry.lastUpdate
            }
            return book
        }

        let feedOnly: [Book] = ABSPodcastEpisodeMerge.feedOnlyEpisodes(stored: storedEpisodes, feed: feedEpisodes)
            .compactMap { episode in
                guard !episode.title.isEmpty, let audioURL = episode.audioURL else { return nil }
                return Book(
                    id: "\(item.id)_rss_\(episode.id)",
                    title: episode.title,
                    author: item.author,
                    thumb: (episode.coverURL ?? coverURL)?.absoluteString,
                    partKey: audioURL.absoluteString,
                    duration: episode.duration > 0 ? episode.duration : nil,
                    isPodcastEpisode: true,
                    episodeId: episode.id,
                    podcastLibraryItemId: item.id,
                    podcastName: item.title,
                    description: episode.description,
                    genres: item.genres.isEmpty ? nil : item.genres,
                    addedAt: episode.publishedDate,
                    providerId: Self.feedEpisodeProviderId,
                    libraryId: libraryId
                )
            }

        return PodcastShow(
            id: item.id,
            title: item.title,
            author: item.author,
            description: item.description,
            coverURL: coverURL,
            genres: item.genres,
            episodes: stored + feedOnly,
            addedAt: item.addedAt
        )
    }

    // 1: minified series names split into name and sequence.
    var catalogMappingRevision: Int { 1 }

    func fetchBooksDelta(libraryId: String, since: Date) async throws -> (books: [Book], cursor: Date)? {
        guard let baseURL = URL(string: connection.url),
            let token = connection.token, !token.isEmpty
        else { return nil }

        let pageSize = 500

        let iterationCeiling = 2_000
        var page = 0
        var collected: [Book] = []
        var maxSeen: Date = since
        var hadDecodeFailures = false
        let libType = libraryMediaTypes[libraryId]

        while page < iterationCeiling {
            guard
                var components = URLComponents(
                    url: baseURL.appendingPathComponent("api/libraries/\(libraryId)/items"),
                    resolvingAgainstBaseURL: false
                )
            else { return nil }
            components.queryItems = [
                URLQueryItem(name: "limit", value: String(pageSize)),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "minified", value: "1"),
                URLQueryItem(name: "sort", value: "updatedAt"),
                URLQueryItem(name: "desc", value: "1"),
            ]
            guard let requestURL = components.url else { return nil }
            let request = URLRequest(url: requestURL)
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await performRequest(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return nil
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

            let resp: PageResponse<ABSItem>
            do {
                resp = try Self.absDecoder.decode(PageResponse<ABSItem>.self, from: data)
            } catch { return nil }
            updateRejectedContent(resp, libraryId: libraryId)
            if resp.failures > 0 {
                hadDecodeFailures = true
            }
            if resp.results.isEmpty { break }

            var pageHadNew = false
            var pageMaxSeen: Date = .distantPast
            for item in resp.results {

                let itemDate = item.updatedAt ?? item.addedAt ?? .distantPast
                if itemDate > pageMaxSeen { pageMaxSeen = itemDate }
                if itemDate > since,
                    let book = convertItemToBook(item, libraryId: libraryId, baseURL: baseURL, token: token, libraryMediaType: libType)
                {
                    collected.append(book)
                    pageHadNew = true
                }
            }
            if pageMaxSeen > maxSeen { maxSeen = pageMaxSeen }

            if !pageHadNew { break }
            if resp.results.count < pageSize { break }
            page += 1
        }

        AppLogger.network.info("[ABS] Delta: \(collected.count) changed items since \(since)")
        return (collected, hadDecodeFailures ? since : maxSeen)
    }

    func fetchRecentBooks(libraryId: String, limit: Int) async throws -> [Book] {
        guard let baseURL = URL(string: connection.url),
            let token = connection.token
        else {
            throw ProviderError.unauthorized
        }

        guard
            var components = URLComponents(
                url: baseURL.appendingPathComponent("api/libraries/\(libraryId)/items"),
                resolvingAgainstBaseURL: false
            )
        else { throw ProviderError.invalidURL }
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(max(1, limit))),
            URLQueryItem(name: "minified", value: "1"),
            URLQueryItem(name: "sort", value: "addedAt"),
            URLQueryItem(name: "desc", value: "1"),
        ]

        guard let requestURL = components.url else { throw ProviderError.invalidURL }
        let request = URLRequest(url: requestURL)
        let (data, response) = try await performRequest(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError.invalidResponse
        }

        let pageResp = try Self.absDecoder.decode(PageResponse<ABSItem>.self, from: data)
        updateRejectedContent(pageResp, libraryId: libraryId)

        let libType = self.libraryMediaTypes[libraryId]
        return pageResp.results.compactMap { item in
            convertItemToBook(item, libraryId: libraryId, baseURL: baseURL, token: token, libraryMediaType: libType)
        }
    }

    private func updateRejectedContent(_ page: PageResponse<ABSItem>, libraryId: String) {
        RejectedContentStore.shared.update(
            connection: connection,
            libraryId: libraryId,
            acceptedItemIdentifiers: Set(page.results.map(\.id)),
            rejectedItems: page.rejectedItems
        )
        guard !page.rejectedItems.isEmpty else { return }
        AppLogger.network.warning(
            "[ABS] Skipped \(page.rejectedItems.count) malformed item(s) on page \(page.page)"
        )
    }

    func fetchCollections(libraryId: String?) async throws -> [Collection] {
        guard let baseURL = URL(string: connection.url),
            connection.token != nil
        else {
            throw ProviderError.unauthorized
        }

        let path = libraryId.map { "api/libraries/\($0)/collections" } ?? "api/collections"
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw ProviderError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "limit", value: "500")]

        guard let requestURL = components.url else { throw ProviderError.invalidURL }
        let request = URLRequest(url: requestURL)
        let (data, response) = try await performRequest(request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError.invalidResponse
        }

        let decoded: CollectionsResponse
        do {
            decoded = try Self.absDecoder.decode(CollectionsResponse.self, from: data)
        } catch {
            AppLogger.network.error("fetchCollections decode failed: \(error)")
            throw error
        }

        return decoded.items.compactMap { item in
            let bookIds = item.books?.map(\.id) ?? []
            return Collection(
                id: item.id,
                name: item.name,
                description: item.description,
                books: bookIds,
                bookCount: bookIds.count,
                iconName: "square.stack.3d.down.right.fill",
                color: "blue",
                providerId: connection.id
            )
        }
    }

    // Minified items join a book's series as "Name #sequence, Other #sequence".
    static func seriesEntries(fromMinifiedName value: String?) -> [SeriesInfo] {
        guard let value, !value.isEmpty else { return [] }
        return value.components(separatedBy: ", ").compactMap { part in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            guard let marker = trimmed.range(of: " #", options: .backwards) else {
                return SeriesInfo(name: trimmed, sequence: nil)
            }
            return SeriesInfo(name: String(trimmed[..<marker.lowerBound]), sequence: String(trimmed[marker.upperBound...]))
        }
    }

    func fetchSeries(libraryId: String) async throws -> [Series] {
        guard let baseURL = URL(string: connection.url),
            connection.token != nil
        else {
            throw ProviderError.unauthorized
        }

        let url = baseURL.appendingPathComponent("api/libraries/\(libraryId)/series")
        var allResults: [ABSSeriesItem] = []
        var page = 0
        let pageSize = 500

        while true {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw ProviderError.invalidURL }
            components.queryItems = [
                URLQueryItem(name: "limit", value: String(pageSize)),
                URLQueryItem(name: "page", value: String(page)),
            ]

            guard let requestURL = components.url else { throw ProviderError.invalidURL }
            let request = URLRequest(url: requestURL)
            let (data, response) = try await performRequest(request)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw ProviderError.invalidResponse
            }

            let pageResp = try Self.absDecoder.decode(PageResponse<ABSSeriesItem>.self, from: data)
            allResults.append(contentsOf: pageResp.results)

            if pageResp.results.count < pageSize { break }
            page += 1
            if page > 20 { break }
        }

        AppLogger.network.info("Fetched \(allResults.count) series")

        return allResults.map { item in
            let bookIds = item.books?.map(\.id) ?? []
            var bookSequences: [String: String] = [:]
            for book in item.books ?? [] {
                let entry = Self.seriesEntries(fromMinifiedName: book.media.metadata.seriesName).first { $0.name == item.name }
                if let sequence = entry?.sequence { bookSequences[book.id] = sequence }
            }
            return Series(
                id: item.id,
                name: item.name,
                description: nil,
                books: bookIds,
                bookSequences: bookSequences,
                bookCount: item.numBooks ?? bookIds.count,
                libraryId: libraryId,
                providerId: connection.id
            )
        }
    }

    func fetchUserMediaProgress(libraryId: String) async throws -> [UserMediaProgress] {
        guard let baseURL = URL(string: connection.url),
            connection.token != nil
        else {
            throw ProviderError.unauthorized
        }

        let url = baseURL.appendingPathComponent("api/me")
        let request = URLRequest(url: url)
        let (data, response) = try await performRequest(request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            AppLogger.network.info("/api/me returned \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            return []
        }

        do {
            let user = try JSONDecoder().decode(ABSUser.self, from: data)
            let all = user.mediaProgress ?? []
            AppLogger.network.info("/api/me returned \(all.count) progress entries")

            return all.compactMap { item -> UserMediaProgress? in
                guard let itemId = item.libraryItemId else { return nil }
                return UserMediaProgress(
                    id: item.id ?? itemId,
                    libraryItemId: itemId,
                    providerId: connection.id,
                    episodeId: item.episodeId,
                    currentTime: item.currentTime ?? 0,
                    progress: item.progress ?? 0,
                    isFinished: item.resolvedIsFinished,
                    duration: item.duration ?? 0,
                    lastUpdate: item.lastUpdateDate ?? Date.distantPast,
                    ebookProgress: item.hasEbookPosition ? item.ebookProgress : nil
                )
            }
        } catch {
            AppLogger.network.error("/api/me decode failed: \(error)")
            return []
        }
    }

    func updateChapters(itemId: String, chapters: [Chapter]) async throws {
        guard let baseURL = URL(string: connection.url), connection.token != nil else {
            throw ProviderError.unauthorized
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/items/\(itemId)/chapters"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "chapters": chapters.map {
                ["id": $0.index, "start": $0.start, "end": $0.end, "title": $0.title]
            }
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, response) = try await performRequest(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError.serverError("Chapter update failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
    }

    func fetchFullBookDetails(bookId: String, libraryId: String) async throws -> Book {
        guard let baseURL = URL(string: connection.url),
            let token = connection.token
        else {
            throw ProviderError.unauthorized
        }

        let itemId = Self.itemId(forBookId: bookId)
        guard let requestURL = Self.expandedItemURL(baseURL: baseURL, itemId: itemId) else { throw ProviderError.invalidURL }

        let request = URLRequest(url: requestURL)
        let (data, response) = try await performRequest(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ProviderError.invalidResponse
        }

        let item = try Self.absDecoder.decode(ABSItem.self, from: data)

        var progress: UserMediaProgress?
        let progressURL = baseURL.appendingPathComponent("api/me/progress/\(itemId)")
        let progressRequest = URLRequest(url: progressURL)
        if let (pData, pResp) = try? await performRequest(progressRequest),
            (pResp as? HTTPURLResponse)?.statusCode == 200,
            let p = try? Self.absDecoder.decode(ABSProgressItem.self, from: pData)
        {
            progress = UserMediaProgress(
                id: p.id,
                libraryItemId: p.libraryItemId ?? itemId,
                providerId: connection.id,
                episodeId: p.episodeId,
                currentTime: p.currentTime ?? 0,
                progress: p.progress ?? 0,
                isFinished: p.resolvedIsFinished,
                duration: p.duration ?? 0,
                lastUpdate: p.lastUpdate.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date.distantPast,
                ebookProgress: p.hasEbookPosition ? p.ebookProgress : nil
            )
        }

        guard
            var book = convertItemToBooks(
                item,
                libraryId: item.libraryId ?? libraryId,
                baseURL: baseURL,
                token: token,
                libraryMediaType: libraryMediaTypes[libraryId]
            ).first(where: { $0.id == bookId })
        else {
            throw ProviderError.invalidResponse
        }
        if let progress {
            Self.applyServerProgress(progress, to: &book)
        }
        return book
    }

    /// An empty side leaves a dual item's book for that side untouched: ABS stamps both sides' pushes on one record.
    static func applyServerProgress(_ progress: UserMediaProgress, to book: inout Book) {
        if book.mediaType == .ebook, book.hasAlternateFormat, progress.ebookProgress == nil { return }
        if book.mediaType == .audiobook, book.hasAlternateFormat,
            !ABSMediaProgress.hasAudioPosition(currentTime: progress.currentTime, progress: progress.progress, isFinished: progress.isFinished)
        {
            return
        }
        book.progress = progress.progress
        book.currentTime = book.mediaType == .ebook ? 0 : progress.currentTime
        book.ebookProgress = progress.ebookProgress ?? book.ebookProgress
        book.isFinished = progress.isFinished
        book.lastUpdate = progress.lastUpdate
    }

    private func chapters(from media: ABSItem.Media) -> [Chapter] {
        if let mediaChapters = media.chapters, !mediaChapters.isEmpty {
            return mediaChapters.enumerated().map { index, chapter in
                Chapter(
                    id: String(chapter.id),
                    start: chapter.start,
                    end: chapter.end,
                    title: chapter.title,
                    index: index
                )
            }
        }

        if let audioFiles = media.audioFiles {
            let nested = nestedAudioFileChapters(from: audioFiles)
            if !nested.isEmpty { return nested }

            if audioFiles.count > 1 {
                return trackBasedChapters(from: audioFiles)
            }
        }

        return []
    }

    private func nestedAudioFileChapters(from audioFiles: [ABSItem.AudioFile]) -> [Chapter] {
        var chapters: [Chapter] = []
        var fileOffset: TimeInterval = 0

        for (fileIndex, file) in audioFiles.enumerated() {
            let fileChapters = file.chapters ?? []
            for chapter in fileChapters {
                let start = fileOffset + chapter.start
                let end = fileOffset + chapter.end
                guard end > start else { continue }
                chapters.append(
                    Chapter(
                        id: "file_\(fileIndex)_\(chapter.id)",
                        start: start,
                        end: end,
                        title: chapter.title,
                        index: chapters.count
                    )
                )
            }
            fileOffset += file.duration ?? 0
        }

        return chapters
    }

    private func trackBasedChapters(from audioFiles: [ABSItem.AudioFile]) -> [Chapter] {
        var offset: TimeInterval = 0
        return audioFiles.enumerated().compactMap { index, file in
            let duration = file.duration ?? 0
            guard duration > 0 else { return nil }
            let title = file.metadata?.filename ?? "Track \(index + 1)"
            let chapter = Chapter(
                id: "track_\(file.index ?? index)",
                start: offset,
                end: offset + duration,
                title: title,
                index: index
            )
            offset += duration
            return chapter
        }
    }

    private func trackBasedChapters(from tracks: [AudioTrackInfo]) -> [Chapter] {
        var offset: TimeInterval = 0
        return tracks.enumerated().compactMap { index, track in
            let start = track.startOffset > 0 ? track.startOffset : offset
            let end = start + max(track.duration, 0)
            offset = end
            guard end > start else { return nil }
            return Chapter(
                id: "track_\(track.index)",
                start: start,
                end: end,
                title: track.title ?? "Track \(index + 1)",
                index: index
            )
        }
    }

    private func coverURL(for itemId: String, baseURL: URL, token: String, hasCover: Bool) -> URL? {
        guard hasCover else { return nil }
        var components = URLComponents(url: baseURL.appendingPathComponent("api/items/\(itemId)/cover"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        return components?.url
    }

    private func convertItemToBook(
        _ item: ABSItem,
        libraryId: String,
        baseURL: URL,
        token: String,
        libraryMediaType: String? = nil
    ) -> Book? {
        let title: String
        if let value = item.media.metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        {
            title = value
        } else {
            title = "(Untitled)"
        }

        let author =
            item.media.metadata.authorName
            ?? item.media.metadata.authors?.map(\.name).joined(separator: ", ")
            ?? item.media.metadata.author
            ?? "Unknown Author"

        let hasAudio =
            !(item.media.audioFiles ?? []).isEmpty
            || (item.media.numTracks ?? 0) > 0
            || (item.media.numAudioFiles ?? 0) > 0
        let appMediaType = ABSMediaTypeClassifier.classify(
            libraryMediaType: libraryMediaType,
            itemMediaType: item.mediaType,
            hasAudio: hasAudio,
            ebookFormat: item.media.ebookFormat,
            hasEbookFile: item.media.ebookFile != nil
        )

        let coverURL = self.coverURL(for: item.id, baseURL: baseURL, token: token, hasCover: item.media.coverPath != nil)

        var seriesInfo: SeriesInfo?
        if let first = item.media.metadata.series?.first {
            seriesInfo = SeriesInfo(name: first.name, sequence: first.sequence)
        } else {
            seriesInfo = Self.seriesEntries(fromMinifiedName: item.media.metadata.seriesName).first
        }

        let chapters = chapters(from: item.media)

        let fileInos = item.media.audioFiles?.compactMap(\.ino) ?? []
        let primaryIno = appMediaType == .ebook ? (item.media.ebookFile?.ino ?? fileInos.first) : fileInos.first

        let audioTracks: [AudioTrack]? = {
            guard let files = item.media.audioFiles, files.count > 1 else { return nil }
            let sorted = files.sorted { ($0.index ?? 0) < ($1.index ?? 0) }
            var tracks: [AudioTrack] = []
            var offset: TimeInterval = 0
            for file in sorted {
                let dur = file.duration ?? 0
                tracks.append(
                    AudioTrack(
                        index: file.index ?? tracks.count,
                        title: file.metadata?.filename,
                        duration: dur,
                        startOffset: offset,
                        headers: self.getStreamingHeaders()
                    )
                )
                offset += dur
            }
            return tracks
        }()

        let resolvedFilePath: String? = {
            if let rp = item.relPath?.trimmingCharacters(in: .whitespacesAndNewlines), !rp.isEmpty { return rp }

            let parts = [author, title].filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: "/")
        }()

        var book = Book(
            id: item.id,
            title: title,
            author: author,
            narrator: item.media.metadata.narratorName,
            seriesInfo: seriesInfo,
            duration: item.media.duration ?? item.media.audioFiles?.compactMap(\.duration).reduce(0, +) ?? 0,
            coverURL: coverURL,
            partKey: item.id,
            audioFileIno: primaryIno,
            audioFileInos: fileInos.isEmpty ? nil : fileInos,
            audioTracks: audioTracks,
            dateAdded: item.addedAt,
            description: item.media.metadata.description,
            genres: item.media.metadata.genres ?? [],
            chapters: chapters,
            progress: 0,
            currentTime: 0,
            isFinished: false,
            libraryId: libraryId,
            providerId: connection.id,
            backendId: connection.id.uuidString,
            source: .audiobookshelf,
            filePath: resolvedFilePath
        )
        book.mediaType = appMediaType
        book.ebookFormat = item.media.ebookFile?.ebookFormat ?? item.media.ebookFormat
        return book
    }

    private func convertItemToBooks(
        _ item: ABSItem,
        libraryId: String,
        baseURL: URL,
        token: String,
        libraryMediaType: String? = nil
    ) -> [Book] {
        guard
            var primary = convertItemToBook(item, libraryId: libraryId, baseURL: baseURL, token: token, libraryMediaType: libraryMediaType)
        else {
            return []
        }

        let hasAudio =
            !(item.media.audioFiles ?? []).isEmpty
            || (item.media.numTracks ?? 0) > 0
            || (item.media.numAudioFiles ?? 0) > 0
        let hasEbook =
            item.media.ebookFile != nil
            || !(item.media.ebookFormat?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard hasAudio, hasEbook, primary.mediaType == .audiobook else {
            return [primary]
        }

        primary.hasAlternateFormat = true
        var ebook = Book(
            id: "\(item.id)\(Self.ebookSideIdSuffix)",
            title: primary.title,
            author: primary.author,
            narrator: primary.narrator,
            seriesInfo: primary.seriesInfo,
            duration: nil,
            coverURL: primary.coverURL,
            partKey: item.id,
            audioFileIno: item.media.ebookFile?.ino,
            audioFileInos: nil,
            audioTracks: nil,
            dateAdded: primary.addedAt,
            description: primary.description,
            genres: primary.genres ?? [],
            chapters: nil,
            progress: 0,
            currentTime: 0,
            isFinished: primary.isFinished,
            libraryId: primary.libraryId,
            providerId: primary.providerId,
            backendId: primary.backendId,
            source: .audiobookshelf,
            filePath: primary.filePath
        )
        ebook.mediaType = .ebook
        ebook.ebookFormat = item.media.ebookFile?.ebookFormat ?? item.media.ebookFormat
        ebook.ebookProgress = primary.ebookProgress
        ebook.linkedAudiobookStableId = primary.stableId
        ebook.hasAlternateFormat = true
        return [primary, ebook]
    }

    func updatePlaybackProgress(
        book: Book,
        sessionId: String?,
        currentTime: TimeInterval,
        isFinished: Bool,
        timeListened: TimeInterval
    ) async throws {
        guard let baseURL = URL(string: connection.url),
            let token = connection.token
        else {
            throw ProviderError.unauthorized
        }

        if let sessionId = sessionId {
            let url = baseURL.appendingPathComponent("api/session/\(sessionId)/sync")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any] = [
                "currentTime": currentTime,
                "duration": book.duration ?? 0,
                "timeListened": timeListened,
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            let (_, response) = try await performRequest(request)
            let sessionStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            // ABS keeps sessions in memory; after a server restart the session is gone but the progress PATCH still lands.
            if sessionStatus == 404 {
                AppLogger.network.info("ABS no longer holds the playback session; saving progress without it")
            } else if (200...299).contains(sessionStatus) {
                AppLogger.network.info("Synced session \(sessionId) to \(currentTime)s (listened: \(timeListened)s)")
            } else {
                throw ProviderError.invalidResponse
            }

            var progressPath = "api/me/progress/\(Self.libraryItemId(for: book))"
            if book.isPodcastEpisode, let epId = book.episodeId {
                progressPath += "/\(epId)"
            }
            let progressURL = baseURL.appendingPathComponent(progressPath)
            var progressRequest = URLRequest(url: progressURL)
            progressRequest.httpMethod = "PATCH"
            progressRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            progressRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let duration = book.duration ?? 0
            var progressBody: [String: Any] = [
                "currentTime": currentTime,
                "duration": duration,
                "progress": currentTime / (duration > 0 ? duration : 1),
            ]
            // ABS clears currentTime when isFinished changes from true to false.
            if isFinished || currentTime <= 0 { progressBody["isFinished"] = isFinished }
            progressRequest.httpBody = try JSONSerialization.data(withJSONObject: progressBody)

            let (_, progressResponse) = try await performRequest(progressRequest)
            guard let progressHttp = progressResponse as? HTTPURLResponse, (200...299).contains(progressHttp.statusCode) else {
                throw ProviderError.invalidResponse
            }
            AppLogger.network.debug(
                "Synced progress bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) position=\(Int(currentTime))s"
            )
        } else {
            var progressPath = "api/me/progress/\(Self.libraryItemId(for: book))"
            if book.isPodcastEpisode, let epId = book.episodeId {
                progressPath += "/\(epId)"
            }
            let url = baseURL.appendingPathComponent(progressPath)
            var request = URLRequest(url: url)
            request.httpMethod = "PATCH"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let duration = book.duration ?? 0
            var body: [String: Any] = [
                "currentTime": currentTime,
                "duration": duration,
                "progress": currentTime / (duration > 0 ? duration : 1),
            ]
            if isFinished || currentTime <= 0 { body["isFinished"] = isFinished }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (_, response) = try await performRequest(request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                throw ProviderError.invalidResponse
            }
            AppLogger.network.debug(
                "Synced progress bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) position=\(Int(currentTime))s"
            )
        }
        if book.hasAlternateFormat, !book.isPodcastEpisode {
            NarratedAudioPositionStore.shared.recordPush(
                audioTime: currentTime,
                forItem: NarratedAudioPositionStore.itemKey(connectionId: connection.id, itemId: Self.libraryItemId(for: book))
            )
        }
    }

    func getAudioURL(for book: Book) -> URL? {
        guard let baseURL = URL(string: connection.url),
            let token = connection.token
        else {
            return nil
        }

        let itemId = Self.libraryItemId(for: book)
        var playPath = "api/items/\(itemId)/play"
        if book.isPodcastEpisode, let epId = book.episodeId {
            playPath = "api/items/\(itemId)/play/\(epId)"
        }

        var components = URLComponents(url: baseURL.appendingPathComponent(playPath), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        return components?.url
    }

    func chapterExtractionURL(for book: Book) -> URL? {
        guard let baseURL = URL(string: connection.url),
            let token = connection.token,
            let ino = book.audioFileIno
        else {
            return nil
        }

        let itemId = book.isPodcastEpisode ? (book.podcastLibraryItemId ?? book.id) : (book.partKey ?? book.id)
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/items/\(itemId)/file/\(ino)/download"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        return components?.url
    }

    func getStreamingHeaders() -> [String: String] {
        var headers: [String: String] = [:]

        if let customHeaders = connection.customHeaders {
            for (key, value) in customHeaders {
                headers[key] = value
            }
        }

        guard let token = connection.token else {
            return headers
        }
        if token.contains(".") {
            headers["Authorization"] = "Bearer \(token)"
        } else {
            headers["Authorization"] = token
        }
        return headers
    }

    func startPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo {

        guard let baseURL = URL(string: connection.url),
            connection.token != nil
        else {
            throw ProviderError.unauthorized
        }

        let itemId = Self.libraryItemId(for: book)
        var playPath = "api/items/\(itemId)/play"
        if book.isPodcastEpisode, let epId = book.episodeId {
            playPath = "api/items/\(itemId)/play/\(epId)"
        }
        let url = baseURL.appendingPathComponent(playPath)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var deviceId = "unknown"
        var deviceName = "Enve Client"

        #if canImport(UIKit)
        deviceId = UIDevice.current.identifierForVendor?.uuidString ?? StorageService.shared.loadDeviceUUID()
        deviceName = UIDevice.current.name
        #else
        deviceId = StorageService.shared.loadDeviceUUID()
        deviceName = Host.current().localizedName ?? "Mac"
        #endif

        let body: [String: Any] = [
            "deviceInfo": [
                "clientName": "Enve",
                "deviceId": deviceId,
                "deviceName": deviceName,
            ],
            "supportedMimeTypes": ["audio/mpeg", "audio/mp4", "audio/x-m4a", "audio/aac", "audio/flac", "audio/ogg"],
            "mediaPlayer": "AVPlayer",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await performRequest(request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            AppLogger.network.error("Playback session failed: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            throw ProviderError.invalidResponse
        }

        struct PlaybackChapter: Codable {
            let id: Int?
            let start: Double
            let end: Double
            let title: String
        }

        struct PlaybackAudioTrack: Codable {
            let index: Int
            let startOffset: Double
            let duration: Double
            let contentUrl: String
            let mimeType: String
        }

        struct PlaybackResponse: Codable {
            let id: String
            let audioTracks: [PlaybackAudioTrack]
            let chapters: [PlaybackChapter]?
            let currentTime: Double?
        }

        let sessionResponse = try JSONDecoder().decode(PlaybackResponse.self, from: data)

        AppLogger.network.info("Playback session started: \(sessionResponse.id)")
        AppLogger.network.info("Audio tracks: \(sessionResponse.audioTracks.count)")

        let tracks = sessionResponse.audioTracks.map { track in
            let fullUrl = baseURL.absoluteString + track.contentUrl
            return AudioTrackInfo(
                index: track.index,
                startOffset: track.startOffset,
                duration: track.duration,
                contentUrl: fullUrl,
                mimeType: track.mimeType
            )
        }

        let chapters =
            sessionResponse.chapters?.enumerated().map { index, chapter in
                Chapter(id: String(chapter.id ?? index), start: chapter.start, end: chapter.end, title: chapter.title, index: index)
            } ?? trackBasedChapters(from: tracks)

        return PlaybackSessionInfo(
            sessionId: sessionResponse.id,
            audioTracks: tracks,
            chapters: chapters,
            serverCurrentTime: sessionResponse.currentTime
        )
    }

    func downloadEbook(for book: Book, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        if let cached = LocalEbookImporter.shared.cachedEbook(forBookId: book.id) {
            onProgress?(1)
            return cached
        }

        guard let baseURL = URL(string: connection.url),
            let token = connection.token
        else {
            throw ProviderError.unauthorized
        }

        let downloadURL = baseURL.appendingPathComponent("api/items/\(book.partKey ?? book.id)/ebook")

        var request = URLRequest(url: downloadURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

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

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ProviderError.invalidResponse
        }

        let fileExtension = book.ebookFormat?.lowercased() ?? EbookFormat.epub.rawValue
        return try LocalEbookImporter.shared.cacheRemoteEbook(
            tempURL: tempURL,
            preferredFilename: "\(book.title.replacingOccurrences(of: "/", with: "-")).\(fileExtension)",
            bookIdentifier: book.id
        )
    }

    func updateEbookProgress(for book: Book, progress: Double, epubLocator: String?) async throws {
        guard let baseURL = URL(string: connection.url),
            let token = connection.token
        else {
            throw ProviderError.unauthorized
        }

        let updateURL = baseURL.appendingPathComponent("api/me/progress/\(book.partKey ?? book.id)")
        var request = URLRequest(url: updateURL)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var ebookLocation: String?
        var audioPosition: (currentTime: TimeInterval, duration: TimeInterval)?
        #if os(iOS)
        if let epubLocator, let epubURL = UnifiedDownloadService.shared.existingReaderAsset(for: book) {
            ebookLocation = await EpubCFI.providerCFI(forLocatorJSON: epubLocator, epubFileURL: epubURL)
            if ebookLocation == nil {
                AppLogger.network.info("ABS ebook position did not round-trip as a CFI; sending progress only")
            }
        }
        audioPosition = await narrationAudioPosition(for: book, locator: epubLocator)
        #endif

        let body = Self.ebookProgressBody(
            progress: progress,
            ebookLocation: ebookLocation,
            itemHasAudio: book.hasAlternateFormat,
            audioPosition: audioPosition
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await performRequest(request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw ProviderError.serverError("Failed to sync ABS ebook progress (HTTP \(httpResponse.statusCode))")
        }
        if book.hasAlternateFormat {
            NarratedAudioPositionStore.shared.recordPush(
                audioTime: audioPosition?.currentTime,
                forItem: NarratedAudioPositionStore.itemKey(connectionId: connection.id, itemId: book.partKey ?? book.id)
            )
        }
        AppLogger.network.info("Successfully synced ebook progress: \(Int(progress * 100))%")
    }

    func fetchEbookProgress(for book: Book) async throws -> (progress: Double, locator: String?, updatedAt: Date?, isFinished: Bool)? {
        guard let baseURL = URL(string: connection.url),
            let token = connection.token
        else {
            throw ProviderError.unauthorized
        }

        let progressURL = baseURL.appendingPathComponent("api/me/progress/\(book.partKey ?? book.id)")
        var request = URLRequest(url: progressURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await performRequest(request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw ProviderError.invalidResponse }
        let p = try Self.absDecoder.decode(ABSProgressItem.self, from: data)

        var progress = p.ebookFraction(itemHasAudio: book.hasAlternateFormat)
        var locator: String?
        switch Self.ebookLocation(fromServerValue: p.ebookLocation) {
        case .readiumLocatorJSON(let json):
            locator = json
        case .cfi(let cfi):
            #if os(iOS)
            if let epubURL = UnifiedDownloadService.shared.existingReaderAsset(for: book) {
                locator = await EpubCFI.readiumLocatorJSON(forCFI: cfi, totalProgression: progress ?? 0, epubFileURL: epubURL)
            }
            #endif
        case nil:
            break
        }
        #if os(iOS)
        if let narrated = await narratedPositionFromItemAudio(record: p, book: book) {
            locator = narrated.locator
            progress = narrated.progress
        }
        #endif
        guard let progress else { return nil }
        let updatedAt = p.lastUpdate.map { Date(timeIntervalSince1970: $0 / 1000) }
        return (progress: progress, locator: locator, updatedAt: updatedAt, isFinished: p.isFinished == true)
    }

    enum ServerEbookLocation: Equatable {
        case readiumLocatorJSON(String)
        case cfi(String)
    }

    /// Older Enve builds stored Readium locator JSON in `ebookLocation`; ABS readers store an EPUB CFI.
    static func ebookLocation(fromServerValue value: String?) -> ServerEbookLocation? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.hasPrefix("{"), EpubCFI.jsonObject(value) != nil { return .readiumLocatorJSON(value) }
        if value.hasPrefix("epubcfi("), EpubCFI.parse(value) != nil { return .cfi(value) }
        return nil
    }

    /// ABS keeps audio and ebook fields on one mediaProgress record, and a PATCH overwrites only the keys it sends.
    static func ebookProgressBody(
        progress: Double,
        ebookLocation: String?,
        itemHasAudio: Bool,
        audioPosition: (currentTime: TimeInterval, duration: TimeInterval)?
    ) -> [String: Any] {
        var body: [String: Any] = ["ebookProgress": progress]
        let isFinished = progress >= Book.finishedProgressThreshold
        // Un-finishing an item on ABS also zeroes its audio currentTime.
        if isFinished || !itemHasAudio { body["isFinished"] = isFinished }
        if let ebookLocation { body["ebookLocation"] = ebookLocation }
        if let audioPosition, audioPosition.duration > 0 {
            body["currentTime"] = audioPosition.currentTime
            body["duration"] = audioPosition.duration
            body["progress"] = min(max(audioPosition.currentTime / audioPosition.duration, 0), 1)
        }
        return body
    }

    /// A dual item's ebook side is a separate Book whose id carries this suffix; ABS knows only the item id.
    static let ebookSideIdSuffix = "_ebook"

    static func itemId(forBookId bookId: String) -> String {
        bookId.hasSuffix(ebookSideIdSuffix) ? String(bookId.dropLast(ebookSideIdSuffix.count)) : bookId
    }

    static func libraryItemId(for book: Book) -> String {
        book.isPodcastEpisode ? (book.podcastLibraryItemId ?? book.id) : itemId(forBookId: book.id)
    }

    /// ABS omits `media.duration` (and tracks) from a library item unless it is requested expanded.
    static func expandedItemURL(baseURL: URL, itemId: String) -> URL? {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/items/\(itemId)"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "expanded", value: "1")]
        return components?.url
    }

    private func itemAudioDuration(itemId: String) async -> TimeInterval? {
        if let cached = itemAudioDurations[itemId] { return cached }
        guard let baseURL = URL(string: connection.url),
            let url = Self.expandedItemURL(baseURL: baseURL, itemId: itemId),
            let (data, response) = try? await performRequest(URLRequest(url: url)),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let duration = (try? Self.absDecoder.decode(ABSItem.self, from: data))?.media.duration,
            duration > 0
        else { return nil }
        itemAudioDurations[itemId] = duration
        return duration
    }

    #if os(iOS)
    /// The item's audio time for a narrated sentence, sent only while Enve narrates that very sentence.
    private func narrationAudioPosition(
        for book: Book,
        locator: String?
    ) async -> (currentTime: TimeInterval, duration: TimeInterval)? {
        guard book.hasAlternateFormat, let locator,
            let narrationTime = NarratedAudioPositionStore.shared.narrationAudioTime(for: book),
            let timeline = MediaOverlayPlaybackService.shared.narrationTimeline(for: book),
            let resolved = timeline.resolveEPUB3Locator(locatorJSON: locator),
            resolved.source == .fragment,
            let itemDuration = await itemAudioDuration(itemId: book.partKey ?? book.id)
        else { return nil }
        return Self.itemAudioPosition(
            narrationTime: narrationTime,
            clip: timeline.clipTimings[resolved.clipIndex],
            overlayDuration: timeline.totalAudioDuration,
            itemAudioDuration: itemDuration
        )
    }

    static func itemAudioPosition(
        narrationTime: TimeInterval,
        clip: MediaOverlayTimeline.ClipTiming,
        overlayDuration: TimeInterval,
        itemAudioDuration: TimeInterval
    ) -> (currentTime: TimeInterval, duration: TimeInterval)? {
        guard LinkedBookProgressCoordinator.narrationMatchesAudio(
            narrationDuration: overlayDuration,
            audioDuration: itemAudioDuration
        ),
            // A locator saved while paging keeps the last narration time, which then lies outside its sentence.
            narrationTime >= clip.audioStart - 0.5, narrationTime <= clip.audioEnd + 0.5
        else { return nil }
        return (narrationTime * itemAudioDuration / overlayDuration, itemAudioDuration)
    }

    /// ABS stamps one lastUpdate for both sides, so its audio side is newer only when it moved off the time Enve last synced.
    private func narratedPositionFromItemAudio(
        record: ABSProgressItem,
        book: Book
    ) async -> (locator: String, progress: Double)? {
        let itemId = book.partKey ?? book.id
        guard book.hasAlternateFormat, let audioTime = record.currentTime else { return nil }
        let itemKey = NarratedAudioPositionStore.itemKey(connectionId: connection.id, itemId: itemId)
        NarratedAudioPositionStore.shared.noteServerAudioTime(audioTime, forItem: itemKey)
        guard book.hasEPUB3MediaOverlay, audioTime > 0,
            NarratedAudioPositionStore.shared.isServerAudioNewer(audioTime, forItem: itemKey),
            let itemDuration = await itemAudioDuration(itemId: itemId),
            let timeline = await MediaOverlayPlaybackService.shared.overlayTimeline(forLocalBook: book),
            LinkedBookProgressCoordinator.narrationMatchesAudio(
                narrationDuration: timeline.totalAudioDuration,
                audioDuration: itemDuration
            )
        else { return nil }
        return Self.narratedLocator(itemAudioTime: audioTime, itemAudioDuration: itemDuration, timeline: timeline)
    }

    static func narratedLocator(
        itemAudioTime: TimeInterval,
        itemAudioDuration: TimeInterval,
        timeline: MediaOverlayTimeline
    ) -> (locator: String, progress: Double)? {
        let overlayTime = itemAudioTime * timeline.totalAudioDuration / itemAudioDuration
        guard let audioClip = timeline.clipIndex(atAudioTime: overlayTime),
            let locator = timeline.textLocatorJSONString(clipIndex: audioClip, audioTime: overlayTime)
        else {
            return nil
        }
        return (locator, timeline.readingProgression(atAudioTime: overlayTime, clipIndex: audioClip))
    }
    #endif

    func fetchAudiobookProgress(
        for book: Book
    ) async throws -> (positionSeconds: TimeInterval, percentage: Double, trackIndex: Int?, updatedAt: Date?, isFinished: Bool)? {
        guard let baseURL = URL(string: connection.url),
            let token = connection.token
        else {
            throw ProviderError.unauthorized
        }

        var path = "api/me/progress/\(book.podcastLibraryItemId ?? book.partKey ?? book.id)"
        if book.isPodcastEpisode, let episodeId = book.episodeId { path += "/\(episodeId)" }
        let progressURL = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: progressURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await performRequest(request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw ProviderError.invalidResponse }
        let p = try Self.absDecoder.decode(ABSProgressItem.self, from: data)

        let positionSeconds = p.currentTime ?? 0
        let percentage = p.progress ?? 0
        let updatedAt = p.lastUpdate.map { Date(timeIntervalSince1970: $0 / 1000) }
        return (
            positionSeconds: positionSeconds, percentage: percentage, trackIndex: nil, updatedAt: updatedAt,
            isFinished: p.isFinished == true
        )
    }
}
