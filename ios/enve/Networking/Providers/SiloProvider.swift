import CryptoKit
import Foundation
import Logging

struct SiloEbookProgressUpdateRequest: Encodable {
    let fileID: Int
    let location: String
    let progress: Double

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case location
        case progress
    }
}

struct SiloProgressDeltaPage {
    let progress: [UserMediaProgress]
    let nextCursor: String
}

enum SiloProgressDeltaError: Error {
    case unsupported
    case stalledCursor
}

final class SiloProvider: IncrementalCatalogProvider, PlaybackSessionProvider, AudiobookProgressProvider,
    EbookProgressProvider, EngineAwareEbookProgressProvider, EbookDownloadProvider, @unchecked Sendable
{
    var connection: ServerConnection
    var onTokenUpdated: ((ServerConnection) -> Void)?

    var capabilities: ProviderCapabilities {
        [
            .fullImport, .pagedImport, .streamingImport,
            .recentBooks, .collections,
            .audiobookProgressPull, .audiobookProgressPush,
            .ebookProgressPull, .ebookProgressPush,
            .downloads, .coverAuthHeader, .backgroundOperation,
        ]
    }

    private let pageSize = 100
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder = JSONEncoder()

    private var detailCache: [String: SiloItemDetail] = [:]
    private var activeEbookFileIDs: [String: Int] = [:]
    private var multipartSessions: [String: [MultipartPartSession]] = [:]

    private struct MultipartPartSession {
        let sessionID: String
        let startOffset: Double
        let duration: Double
    }

    init(connection: ServerConnection) {
        self.connection = connection
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = false
        if let customHeaders = connection.customHeaders {
            config.httpAdditionalHeaders = customHeaders
        }
        if connection.mtlsEnabled {
            self.session = MTLSManager.shared.makeSession(for: connection.id, configuration: config)
        } else {
            self.session = InsecureURLSession.shared
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(Self.decodeDate)
        self.decoder = decoder
    }

    func validateConnection() async throws -> Bool {
        try await ensureAuthenticated()
        _ = try await ensureProfile()
        _ = try await fetchLibraries()
        connection.isConnected = true
        connection.lastVerified = Date()
        notifyTokenUpdated()
        return true
    }

    func fetchLibraries() async throws -> [Library] {
        try await ensureAuthenticated()
        let libraries = try await fetchSiloLibraries()
        return
            libraries
            .filter { ["audiobooks", "audiobook", "ebooks", "ebook", "books", "manga"].contains($0.type.lowercased()) }
            .map {
                let rawType = $0.type.lowercased()
                return Library(
                    id: String($0.id),
                    name: $0.name,
                    type: rawType.contains("audio") ? "audiobooks" : "books",
                    providerId: connection.id
                )
            }
    }

    func fetchBooks(libraryId: String) async throws -> [Book] {
        detailCache.removeAll()
        var books: [Book] = []
        var offset = 0
        var total: Int?

        while total == nil || offset < (total ?? 0) {
            let batch = try await fetchCatalogPage(libraryId: libraryId, offset: offset, limit: pageSize)
            total = batch.total
            let mapped = try await batch.items.asyncCompactMap { try await book(from: $0, libraryId: libraryId) }
            books.append(contentsOf: mapped)
            if batch.items.count < pageSize || batch.hasMore == false { break }
            offset += batch.items.count
        }

        return books
    }

    func makeCatalogBatchSource(
        libraryId: String,
        resumeAfter: String?,
        expectedSnapshotIdentifier: String?
    ) async throws -> LibraryCatalogBatchSource {
        detailCache.removeAll()
        let firstPage = try await catalogPage(libraryId: libraryId, page: 0)
        return LibraryCatalogBatchSource.paged(
            firstPage: firstPage,
            pageSize: pageSize,
            pageConcurrency: 4,
            resumeAfter: resumeAfter,
            expectedSnapshotIdentifier: expectedSnapshotIdentifier,
            fetchPage: { try await self.catalogPage(libraryId: libraryId, page: $0) }
        )
    }

    private func catalogPage(libraryId: String, page: Int) async throws -> LibraryCatalogPage {
        let offset = page * pageSize
        let response = try await fetchCatalogPage(
            libraryId: libraryId,
            offset: offset,
            limit: pageSize
        )
        let books = try await response.items.asyncCompactMap {
            try await book(from: $0, libraryId: libraryId)
        }
        return LibraryCatalogPage(
            books: books,
            totalCount: response.total,
            isLast: response.hasMore == false || offset + response.items.count >= response.total
        )
    }

    func fetchBookBatches(libraryId: String) -> AsyncThrowingStream<LibraryFetchBatchResult, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    self.detailCache.removeAll()
                    var offset = 0
                    var loaded = 0
                    var total: Int?

                    while total == nil || offset < (total ?? 0) {
                        let batch = try await self.fetchCatalogPage(libraryId: libraryId, offset: offset, limit: self.pageSize)
                        total = batch.total
                        let books = try await batch.items.asyncCompactMap { try await self.book(from: $0, libraryId: libraryId) }
                        loaded += books.count
                        continuation.yield(LibraryFetchBatchResult(books: books, loadedSoFar: loaded, totalCount: batch.total))
                        if batch.items.count < self.pageSize || batch.hasMore == false { break }
                        offset += batch.items.count
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func fetchRecentBooks(libraryId: String, limit: Int) async throws -> [Book] {
        detailCache.removeAll()
        let batch = try await fetchCatalogPage(
            libraryId: libraryId,
            offset: 0,
            limit: min(max(limit, 1), pageSize),
            sort: "added_at",
            order: "desc"
        )
        return try await batch.items.asyncCompactMap { try await book(from: $0, libraryId: libraryId) }
    }

    func fetchCollections(libraryId: String?) async throws -> [Collection] {
        try await ensureAuthenticated()
        _ = try await ensureProfile()

        let availableLibraries = try await fetchLibraries()
        let libraryIds: [String]
        if let libraryId, !libraryId.isEmpty {
            libraryIds = [libraryId]
        } else if let selected = connection.selectedLibraryIds, !selected.isEmpty {
            libraryIds = availableLibraries.map(\.id).filter { selected.contains($0) }
        } else {
            libraryIds = availableLibraries.map(\.id)
        }

        async let personal = fetchPersonalCollections(libraryIds: libraryIds)
        async let server = fetchServerCollections(libraryIds: libraryIds)
        let (personalCollections, serverCollections) = try await (personal, server)
        return personalCollections + serverCollections
    }
    func fetchSeries(libraryId: String) async throws -> [Series] { [] }

    func fetchUserMediaProgress(libraryId: String) async throws -> [UserMediaProgress] {
        try await ensureAuthenticated()
        _ = try await ensureProfile()
        let limit = 500
        var offset = 0
        var progress: [UserMediaProgress] = []

        while true {
            var query = [
                URLQueryItem(name: "status", value: "all"),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset)),
            ]
            if !libraryId.isEmpty {
                query.append(URLQueryItem(name: "library_id", value: libraryId))
            }
            let response = try await send(
                try makeRequest(path: "/progress", query: query),
                as: SiloProgressListResponse.self
            )
            progress.append(contentsOf: response.progress.map(userMediaProgress))
            if response.progress.count < limit { break }
            offset += response.progress.count
            if offset > 5_000_000 {
                throw ProviderError.serverError("Silo progress snapshot exceeded the safety limit")
            }
        }

        return progress
    }

    func activityProfileID() async throws -> String {
        try await ensureAuthenticated()
        return try await ensureProfile()
    }

    func fetchProgressDelta(since cursor: String) async throws -> SiloProgressDeltaPage {
        try await ensureAuthenticated()
        _ = try await ensureProfile()
        let response = try await progressDeltaResponse(since: cursor)
        guard let nextCursor = response.nextCursor else {
            throw SiloProgressDeltaError.unsupported
        }
        if !response.progress.isEmpty, nextCursor == cursor {
            throw SiloProgressDeltaError.stalledCursor
        }
        return SiloProgressDeltaPage(
            progress: response.progress.map(userMediaProgress),
            nextCursor: nextCursor
        )
    }

    func syncAudiobookProgress(_ updates: [UserMediaProgress]) async throws -> Set<String> {
        guard !updates.isEmpty else { return [] }
        try await ensureAuthenticated()
        _ = try await ensureProfile()

        let items = updates.map { progress in
            let duration = max(0, progress.duration)
            return SiloProgressSyncItem(
                mediaItemID: progress.libraryItemId,
                position: progress.isFinished && duration > 0
                    ? duration
                    : max(0, progress.currentTime),
                duration: duration,
                updatedAt: Self.rfc3339Formatter.string(from: progress.lastUpdate)
            )
        }
        var request = try makeRequest(path: "/sync/progress", method: "POST")
        request.httpBody = try encoder.encode(SiloProgressSyncRequest(items: items))
        let response = try await send(request, as: SiloProgressSyncResponse.self)
        return Set(response.results.lazy.filter { $0.status == "ok" }.map(\.mediaItemID))
    }

    func fetchFullBookDetails(bookId: String, libraryId: String) async throws -> Book {
        let detail = try await itemDetail(bookId)
        guard let book = book(from: detail, libraryId: libraryId) else {
            throw ProviderError.serverError("Silo item is not an ebook or audiobook")
        }
        return book
    }

    func getAudioURL(for book: Book) -> URL? { nil }
    func chapterExtractionURL(for book: Book) -> URL? { nil }

    func getStreamingHeaders() -> [String: String] {
        var headers = connection.customHeaders ?? [:]
        if let token = connection.token, !token.isEmpty {
            headers["Authorization"] = "Bearer \(token)"
        }
        if let profileID = storedProfileID(), !profileID.isEmpty {
            headers["X-Profile-Id"] = profileID
        }
        return headers
    }

    func startPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo {
        try await ensureAuthenticated()
        let profileID = try await ensureProfile()
        let detail = try await itemDetail(book.id)
        multipartSessions[book.id] = nil

        if let parts = audiobookPartVersions(for: detail) {
            return try await startMultipartPlayback(parts: parts, profileID: profileID, book: book)
        }

        guard let version = primaryVersion(for: detail) else {
            throw ProviderError.serverError("No playable Silo file is available")
        }
        let response = try await startPartSession(
            fileID: version.fileID,
            profileID: profileID,
            disableProgressPersistence: false
        )
        let duration = response.durationSeconds ?? Double(version.duration ?? detail.runtime ?? 0)
        let streamURL = try absoluteURL(response.streamURL).absoluteString
        let track = AudioTrackInfo(
            index: 0,
            startOffset: 0,
            duration: duration,
            contentUrl: streamURL,
            mimeType: mimeType(for: version.container),
            title: version.fileName ?? book.title
        )
        let chapters = chapters(from: version, fallbackDuration: duration, isAudiobook: true) ?? []
        return PlaybackSessionInfo(
            sessionId: response.sessionID,
            audioTracks: [track],
            chapters: chapters,
            serverCurrentTime: response.position
        )
    }

    private func startMultipartPlayback(
        parts: [SiloFileVersion],
        profileID: String,
        book: Book
    ) async throws -> PlaybackSessionInfo {
        var tracks: [AudioTrackInfo] = []
        var sessions: [MultipartPartSession] = []
        var serverPosition: Double?
        var offset = 0.0

        for (index, part) in parts.enumerated() {
            let response = try await startPartSession(
                fileID: part.fileID,
                profileID: profileID,
                disableProgressPersistence: true
            )
            let partDuration = response.durationSeconds ?? Double(part.duration ?? 0)
            let streamURL = try absoluteURL(response.streamURL).absoluteString
            tracks.append(
                AudioTrackInfo(
                    index: index,
                    startOffset: offset,
                    duration: partDuration,
                    contentUrl: streamURL,
                    mimeType: mimeType(for: part.container),
                    title: part.fileName ?? book.title
                )
            )
            sessions.append(
                MultipartPartSession(
                    sessionID: response.sessionID,
                    startOffset: offset,
                    duration: partDuration
                )
            )
            if index == 0 { serverPosition = response.position }
            offset += partDuration
        }

        multipartSessions[book.id] = sessions
        return PlaybackSessionInfo(
            sessionId: sessions[0].sessionID,
            audioTracks: tracks,
            chapters: combinedChapters(for: parts),
            serverCurrentTime: serverPosition
        )
    }

    private func startPartSession(
        fileID: Int,
        profileID: String,
        disableProgressPersistence: Bool
    ) async throws -> SiloPlaybackStartResponse {
        var request = try makeRequest(path: "/playback/start", method: "POST")
        var body: [String: Any] = [
            "file_id": fileID,
            "profile_id": profileID,
            "play_method": "direct",
            "codecs_audio": ["aac", "mp3", "m4a", "m4b", "alac", "flac", "opus", "vorbis"],
            "containers": ["mp3", "m4a", "m4b", "aac", "flac", "ogg", "opus", "wav"],
            "max_resolution": "original",
            "hdr": true,
        ]
        if disableProgressPersistence {
            body["disable_progress_persistence"] = true
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request, as: SiloPlaybackStartResponse.self)
    }

    func updatePlaybackProgress(
        book: Book,
        sessionId: String?,
        currentTime: TimeInterval,
        isFinished: Bool,
        timeListened: TimeInterval
    ) async throws {
        if let sessionId, !sessionId.isEmpty {
            if let parts = multipartSessions[book.id], parts.contains(where: { $0.sessionID == sessionId }) {

                await heartbeatMultipartSession(parts: parts, currentTime: currentTime, isFinished: isFinished)
            } else {
                do {
                    var request = try makeRequest(path: "/playback/\(sessionId)/progress", method: "POST")
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "position": max(0, currentTime),
                        "is_paused": isFinished,
                    ])
                    try await sendEmpty(request)
                    return
                } catch is CancellationError {
                    throw CancellationError()
                } catch {

                }
            }
        }

        let duration = max(book.duration ?? 0, currentTime)
        let progress = UserMediaProgress(
            id: book.id,
            libraryItemId: book.id,
            providerId: connection.id,
            episodeId: nil,
            currentTime: currentTime,
            progress: duration > 0 ? min(max(currentTime / duration, 0), 1) : 0,
            isFinished: isFinished,
            duration: duration,
            lastUpdate: Date(),
            ebookProgress: nil
        )
        let succeeded = try await syncAudiobookProgress([progress])
        guard succeeded.contains(book.id) else {
            throw ProviderError.serverError("Silo rejected the progress update")
        }
    }

    func downloadEbook(for book: Book, onProgress: (@Sendable (Double) -> Void)?) async throws -> URL {
        try await ensureAuthenticated()
        _ = try await ensureProfile()
        let detail = try await itemDetail(book.id)
        guard let version = try await activeEbookVersion(for: detail) else {
            throw ProviderError.serverError("No readable ebook file is available")
        }
        let fileID = version.fileID

        onProgress?(0)
        let request = try makeRequest(path: "/ebooks/\(book.id)/files/\(fileID)/read")
        let (tempURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ProviderError.serverError("Failed to download ebook")
        }

        let ext = ebookFormat(from: version) ?? "epub"
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-\(connection.id.uuidString)-\(book.id)-\(fileID).\(ext)")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        onProgress?(1)
        return destination
    }

    func updateEbookProgress(for book: Book, progress: Double, epubLocator: String?) async throws {
        try await updateEbookProgress(
            for: book,
            progress: progress,
            epubLocator: epubLocator,
            sourceEngine: nil
        )
    }

    func updateEbookProgress(
        for book: Book,
        progress: Double,
        epubLocator: String?,
        sourceEngine: ReaderEngineKind?
    ) async throws {
        try await ensureAuthenticated()
        _ = try await ensureProfile()
        let detail = try await itemDetail(book.id)
        guard let version = try await activeEbookVersion(for: detail) else { return }
        let boundedProgress = min(max(progress, 0), 1)
        let location = siloReaderLocation(
            from: epubLocator,
            progress: boundedProgress,
            sourceEngine: sourceEngine
        )

        var request = try makeRequest(path: "/ebooks/\(book.id)/progress", method: "PUT")
        request.httpBody = try encoder.encode(
            SiloEbookProgressUpdateRequest(
                fileID: version.fileID,
                location: location,
                progress: boundedProgress
            )
        )
        try await sendEmpty(request)
    }

    func fetchEbookProgress(for book: Book) async throws -> (progress: Double, locator: String?, updatedAt: Date?, isAbandoned: Bool)? {
        try await ensureAuthenticated()
        _ = try await ensureProfile()
        guard let progress = try await siloEbookProgress(for: book.id) else {
            return nil
        }
        guard let value = progress.progress,
            let progressFileID = progress.fileID
        else {
            return nil
        }
        if let activeFileID = activeEbookFileIDs[book.id],
            activeFileID != progressFileID
        {
            return nil
        }
        let detail = try await itemDetail(book.id)
        guard
            let selectedVersion = readableEbookVersions(for: detail)
                .first(where: { $0.fileID == progressFileID })
        else {
            return nil
        }
        activeEbookFileIDs[detail.contentID] = selectedVersion.fileID
        let locator = readiumLocator(
            fromSiloLocation: progress.location,
            progress: value
        )
        return (value, locator, progress.updatedAt, value >= 0.99)
    }

    func fetchAudiobookProgress(
        for book: Book
    ) async throws -> (positionSeconds: TimeInterval, percentage: Double, trackIndex: Int?, updatedAt: Date?, isAbandoned: Bool)? {
        let detail = try await itemDetail(book.id)
        guard let userData = detail.userData,
            let position = userData.positionSeconds,
            let duration = userData.durationSeconds ?? book.duration,
            duration > 0
        else { return nil }
        let percentage = min(max(position / duration, 0), 1)

        return (position, percentage, nil, nil, userData.played ?? (percentage >= 0.99))
    }

    func fetchPageCount(for book: Book) async throws -> Int { throw ProviderError.notImplemented }
    func fetchPage(_ pageNumber: Int, for book: Book) async throws -> Data { throw ProviderError.notImplemented }

    func fetchReaderAnnotations(for book: Book) async throws -> [SiloReaderAnnotationRecord] {
        let resource = try await annotationResource(for: book)
        let envelope = try await send(
            try makeRequest(path: "/ebooks/\(book.id)/annotations"),
            as: SiloReaderAnnotationsEnvelope.self
        )
        let fingerprint = annotationResourceFingerprint(for: resource.version)
        return (envelope.items ?? []).filter { record in
            if let rawFileID = record.metadata[Self.annotationFileIDKey],
                Int(rawFileID) != resource.version.fileID
            {
                return false
            }
            if let storedFingerprint = record.metadata[Self.annotationFingerprintKey],
                storedFingerprint != fingerprint
            {
                return false
            }
            if record.metadata[Self.annotationFileIDKey] == nil {
                return resource.readableVersionCount == 1
            }
            return true
        }
    }

    func createReaderAnnotation(for book: Book, annotation: ReaderAnnotation) async throws -> SiloReaderAnnotationRecord {
        guard let cfi = extractCFI(from: annotation.locator) else {
            throw ProviderError.noCFI
        }
        let resource = try await annotationResource(for: book)
        let requestBody = SiloReaderAnnotationRequest(
            kind: annotation.note?.isEmpty == false ? "note" : "highlight",
            cfiRange: cfi,
            location: cfi,
            selectedText: annotation.text,
            note: annotation.note ?? "",
            style: annotation.style.rawValue,
            color: annotation.colorHex,
            metadata: annotationMetadata(
                [
                    "enve_local_id": annotation.id,
                    "enve_position": String(annotation.position),
                    "enve_chapter_title": annotation.chapterTitle ?? "",
                ],
                for: resource.version
            )
        )
        var request = try makeRequest(path: "/ebooks/\(book.id)/annotations", method: "POST")
        request.httpBody = try encoder.encode(requestBody)
        return try await send(request, as: SiloReaderAnnotationRecord.self)
    }

    func updateReaderAnnotation(id: String, for book: Book, annotation: ReaderAnnotation) async throws -> SiloReaderAnnotationRecord {
        guard let cfi = extractCFI(from: annotation.locator) else {
            throw ProviderError.noCFI
        }
        let resource = try await annotationResource(for: book)
        let requestBody = SiloReaderAnnotationRequest(
            kind: annotation.note?.isEmpty == false ? "note" : "highlight",
            cfiRange: cfi,
            location: cfi,
            selectedText: annotation.text,
            note: annotation.note ?? "",
            style: annotation.style.rawValue,
            color: annotation.colorHex,
            metadata: annotationMetadata(
                [
                    "enve_local_id": annotation.id,
                    "enve_position": String(annotation.position),
                    "enve_chapter_title": annotation.chapterTitle ?? "",
                ],
                for: resource.version
            )
        )
        var request = try makeRequest(path: "/ebooks/\(book.id)/annotations/\(id)", method: "PATCH")
        request.httpBody = try encoder.encode(requestBody)
        return try await send(request, as: SiloReaderAnnotationRecord.self)
    }

    func createReaderBookmark(for book: Book, bookmark: Bookmark) async throws -> SiloReaderAnnotationRecord {
        let resource = try await annotationResource(for: book)
        let location = siloReaderLocation(from: bookmark.locator, progress: bookmark.position)
        let requestBody = SiloReaderAnnotationRequest(
            kind: "bookmark",
            cfiRange: nil,
            location: location,
            selectedText: bookmark.title,
            note: bookmark.note ?? "",
            style: "bookmark",
            color: "#facc15",
            metadata: annotationMetadata(
                [
                    "enve_local_id": bookmark.id,
                    "enve_position": String(bookmark.position),
                    "enve_chapter_title": bookmark.chapterTitle ?? "",
                ],
                for: resource.version
            )
        )
        var request = try makeRequest(path: "/ebooks/\(book.id)/annotations", method: "POST")
        request.httpBody = try encoder.encode(requestBody)
        return try await send(request, as: SiloReaderAnnotationRecord.self)
    }

    func deleteReaderAnnotation(id: String, for book: Book) async throws {
        let request = try makeRequest(path: "/ebooks/\(book.id)/annotations/\(id)", method: "DELETE")
        try await sendEmpty(request)
    }

    private static let annotationFileIDKey = "enve_file_id"
    private static let annotationFingerprintKey = "enve_resource_fingerprint"

    private func annotationResource(
        for book: Book
    ) async throws -> (version: SiloFileVersion, readableVersionCount: Int) {
        try await ensureAuthenticated()
        _ = try await ensureProfile()
        let detail = try await itemDetail(book.id)
        let readableVersions = readableEbookVersions(for: detail)
        guard let version = try await activeEbookVersion(for: detail) else {
            throw ProviderError.serverError("No readable ebook file is available")
        }
        return (version, readableVersions.count)
    }

    private func annotationResourceFingerprint(
        for version: SiloFileVersion
    ) -> String {
        let identity = [
            String(version.fileID),
            String(version.fileSize ?? -1),
            version.addedAt.map { String($0.timeIntervalSince1970) } ?? "",
            version.fileName ?? "",
            version.filePath ?? "",
            version.container ?? "",
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func annotationMetadata(
        _ metadata: [String: String],
        for version: SiloFileVersion
    ) -> [String: String] {
        var metadata = metadata
        metadata[Self.annotationFileIDKey] = String(version.fileID)
        metadata[Self.annotationFingerprintKey] = annotationResourceFingerprint(
            for: version
        )
        return metadata
    }

    func ensureAuthenticated() async throws {
        if let token = connection.token, !token.isEmpty {
            return
        }
        if let storedToken = SharedKeychainStore.shared.token(forConnectionId: connection.id.uuidString), !storedToken.isEmpty {
            connection.token = storedToken
            return
        }
        if await refreshAccessToken() {
            return
        }
        if connection.password?.isEmpty ?? true,
            let storedPassword = SharedKeychainStore.shared.password(forConnectionId: connection.id.uuidString),
            !storedPassword.isEmpty
        {
            connection.password = storedPassword
        }
        if connection.password?.isEmpty ?? true,
            let storedPassword = KeychainHelper.shared.get(legacyPasswordKey),
            !storedPassword.isEmpty
        {
            connection.password = storedPassword
        }
        guard let username = connection.username, !username.isEmpty,
            let password = connection.password, !password.isEmpty
        else {
            throw ProviderError.unauthorized
        }
        try await login(username: username, password: password)
    }

    private func login(username: String, password: String) async throws {
        var request = try makeRequest(path: "/auth/login", method: "POST", profileRequired: false, includeAuth: false)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": username,
            "password": password,
        ])
        let response = try await send(request, as: SiloLoginResponse.self, retryingAuth: false)
        connection.token = response.accessToken
        connection.username = response.user.username
        connection.userId = String(response.user.id)
        storeRefreshToken(response.refreshToken)
        notifyTokenUpdated()
    }

    private func refreshAccessToken() async -> Bool {
        guard let refreshToken = storedRefreshToken(), !refreshToken.isEmpty,
            var request = try? makeRequest(path: "/auth/refresh", method: "POST", profileRequired: false, includeAuth: false)
        else {
            return false
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        guard let response = try? await send(request, as: SiloRefreshResponse.self, retryingAuth: false) else {
            return false
        }
        connection.token = response.accessToken
        storeRefreshToken(response.refreshToken)
        notifyTokenUpdated()
        return true
    }

    private func reauthenticateWithStoredCredentials() async -> Bool {
        if connection.password?.isEmpty ?? true,
            let storedPassword = SharedKeychainStore.shared.password(forConnectionId: connection.id.uuidString),
            !storedPassword.isEmpty
        {
            connection.password = storedPassword
        }
        if connection.password?.isEmpty ?? true,
            let storedPassword = KeychainHelper.shared.get(legacyPasswordKey),
            !storedPassword.isEmpty
        {
            connection.password = storedPassword
        }
        guard let username = connection.username, !username.isEmpty,
            let password = connection.password, !password.isEmpty
        else {
            return false
        }
        do {
            try await login(username: username, password: password)
            return true
        } catch {
            return false
        }
    }

    func ensureProfile() async throws -> String {
        if let stored = storedProfileID(),
            !stored.isEmpty,
            storedProfileUserID() == connection.userId
        {
            return stored
        }
        let profiles = try await listProfiles()
        guard let selected = profiles.first(where: { $0.isPrimary }) ?? profiles.first else {
            throw ProviderError.serverError("No Silo profile is available for this account")
        }
        storeProfile(selected)
        return selected.id
    }

    private func listProfiles() async throws -> [SiloProfile] {
        let response = try await send(try makeRequest(path: "/profiles", profileRequired: false), as: SiloProfilesResponse.self)
        return response.profiles
    }

    private var refreshTokenKey: String { "silo_refresh_\(connection.id.uuidString)" }
    private var legacyPasswordKey: String { "silo_password_\(connection.id.uuidString)" }
    private var profileIDKey: String { "silo_profile_id_\(connection.id.uuidString)" }
    private var profileNameKey: String { "silo_profile_name_\(connection.id.uuidString)" }
    private var profileUserIDKey: String { "silo_profile_user_id_\(connection.id.uuidString)" }

    private func storedRefreshToken() -> String? { KeychainHelper.shared.get(refreshTokenKey) }
    private func storeRefreshToken(_ token: String) { KeychainHelper.shared.set(token, key: refreshTokenKey) }
    private func storedProfileID() -> String? { UserDefaults.standard.string(forKey: profileIDKey) }
    private func storedProfileUserID() -> String? { UserDefaults.standard.string(forKey: profileUserIDKey) }
    private func storeProfile(_ profile: SiloProfile) {
        UserDefaults.standard.set(profile.id, forKey: profileIDKey)
        UserDefaults.standard.set(profile.name, forKey: profileNameKey)
        UserDefaults.standard.set(connection.userId, forKey: profileUserIDKey)
    }

    private func notifyTokenUpdated() {
        let updated = connection
        let callback = onTokenUpdated
        DispatchQueue.main.async { callback?(updated) }
    }

    private var baseURLString: String {
        var value = connection.url.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private func apiURL(path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(string: "\(baseURLString)/api/v1\(path)") else {
            throw ProviderError.invalidURL
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else { throw ProviderError.invalidURL }
        return url
    }

    func makeRequest(
        path: String,
        query: [URLQueryItem] = [],
        method: String = "GET",
        profileRequired: Bool = true,
        includeAuth: Bool = true
    ) throws -> URLRequest {
        var request = URLRequest(url: try apiURL(path: path, query: query))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Enve Book Player/1.0", forHTTPHeaderField: "User-Agent")
        if method != "GET" && method != "HEAD" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let customHeaders = connection.customHeaders {
            for (key, value) in customHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        if includeAuth, let token = connection.token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if profileRequired, let profileID = storedProfileID(), !profileID.isEmpty {
            request.setValue(profileID, forHTTPHeaderField: "X-Profile-Id")
        }
        return request
    }

    func send<T: Decodable>(_ request: URLRequest, as type: T.Type, retryingAuth: Bool = true) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        if http.statusCode == 401, retryingAuth, await recoverAuthentication() {
            var retried = request
            retried.setValue("Bearer \(connection.token ?? "")", forHTTPHeaderField: "Authorization")
            return try await send(retried, as: type, retryingAuth: false)
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw ProviderError.unauthorized }
            throw ProviderError.serverError("Silo returned HTTP \(http.statusCode)")
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            AppLogger.network.error("[Silo] Decode failed: \(error.localizedDescription)")
            throw ProviderError.decodingFailed
        }
    }

    private func sendEmpty(_ request: URLRequest, retryingAuth: Bool = true) async throws {
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        if http.statusCode == 401, retryingAuth, await recoverAuthentication() {
            var retried = request
            retried.setValue("Bearer \(connection.token ?? "")", forHTTPHeaderField: "Authorization")
            return try await sendEmpty(retried, retryingAuth: false)
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw ProviderError.unauthorized }
            throw ProviderError.serverError("Silo returned HTTP \(http.statusCode)")
        }
    }

    private func sendData(_ request: URLRequest, retryingAuth: Bool = true) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        if http.statusCode == 401, retryingAuth, await recoverAuthentication() {
            var retried = request
            retried.setValue("Bearer \(connection.token ?? "")", forHTTPHeaderField: "Authorization")
            return try await sendData(retried, retryingAuth: false)
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw ProviderError.unauthorized }
            throw ProviderError.serverError("Silo returned HTTP \(http.statusCode)")
        }
        return data
    }

    private func progressDeltaResponse(
        since cursor: String,
        retryingAuth: Bool = true
    ) async throws -> SiloProgressListResponse {
        let request = try makeRequest(
            path: "/progress",
            query: [URLQueryItem(name: "since", value: cursor)]
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }
        if http.statusCode == 401,
            retryingAuth,
            await recoverAuthentication()
        {
            return try await progressDeltaResponse(since: cursor, retryingAuth: false)
        }
        if http.statusCode == 404 || http.statusCode == 405 {
            throw SiloProgressDeltaError.unsupported
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw ProviderError.unauthorized
            }
            throw ProviderError.serverError("Silo returned HTTP \(http.statusCode)")
        }
        do {
            return try decoder.decode(SiloProgressListResponse.self, from: data)
        } catch {
            throw ProviderError.decodingFailed
        }
    }

    private func userMediaProgress(_ entry: SiloProgressEntry) -> UserMediaProgress {
        let duration = max(0, entry.durationSeconds)
        let fraction =
            duration > 0
            ? min(max(entry.positionSeconds / duration, 0), 1)
            : (entry.completed ? 1 : 0)
        return UserMediaProgress(
            id: entry.mediaItemID,
            libraryItemId: entry.mediaItemID,
            providerId: connection.id,
            episodeId: nil,
            currentTime: max(0, entry.positionSeconds),
            progress: fraction,
            isFinished: entry.completed,
            duration: duration,
            lastUpdate: entry.updatedAt,
            ebookProgress: nil
        )
    }

    private func recoverAuthentication() async -> Bool {
        if await refreshAccessToken() {
            return true
        }
        connection.token = nil
        return await reauthenticateWithStoredCredentials()
    }

    private func fetchSiloLibraries() async throws -> [SiloLibrary] {
        let request = try makeRequest(path: "/user/libraries", profileRequired: false)
        let data = try await sendData(request)
        if let array = try? decoder.decode([SiloLibrary].self, from: data) {
            return array
        }
        let envelope = try decoder.decode(SiloLibrariesEnvelope.self, from: data)
        return envelope.libraries ?? envelope.items ?? []
    }

    private func fetchCatalogPage(
        libraryId: String,
        offset: Int,
        limit: Int,
        sort: String = "title",
        order: String = "asc"
    ) async throws -> SiloCatalogResponse {
        try await ensureAuthenticated()
        _ = try await ensureProfile()
        return try await send(
            try makeRequest(
                path: "/catalog",
                query: [
                    URLQueryItem(name: "library_id", value: libraryId),
                    URLQueryItem(name: "type", value: "audiobook,ebook"),
                    URLQueryItem(name: "offset", value: String(offset)),
                    URLQueryItem(name: "limit", value: String(limit)),
                    URLQueryItem(name: "sort", value: sort),
                    URLQueryItem(name: "order", value: order),
                    URLQueryItem(name: "include_total", value: "true"),
                ]
            ),
            as: SiloCatalogResponse.self
        )
    }

    private func fetchPersonalCollections(libraryIds: [String]) async throws -> [Collection] {
        let response = try await send(
            try makeRequest(path: "/collections"),
            as: SiloPersonalCollectionsResponse.self
        )
        let fetched = try await mapConcurrently(response.collections) { collection in
            let ids = try await self.fetchPersonalCollectionBookIds(
                collectionId: collection.id,
                libraryIds: libraryIds
            )
            return (collection, ids)
        }
        let memberships = Dictionary(uniqueKeysWithValues: fetched.map { ($0.0.id, $0.1) })
        return response.collections
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { collection in
                var mapped = Collection(
                    id: "silo-\(connection.id.uuidString)-personal-\(collection.id)",
                    name: collection.name,
                    description: collection.description,
                    books: memberships[collection.id] ?? [],
                    bookCount: memberships[collection.id]?.count ?? 0,
                    iconName: collection.collectionType == "smart"
                        ? "wand.and.stars"
                        : "books.vertical",
                    color: collection.collectionType == "smart" ? "indigo" : "orange",
                    providerId: connection.id,
                    parentID: collection.groupID,
                    displayOrder: collection.sortOrder
                )
                if let posterURL = collection.posterURL, !posterURL.isEmpty {
                    mapped.representativeThumbs = [posterURL]
                }
                return mapped
            }
    }

    private func fetchPersonalCollectionBookIds(
        collectionId: String,
        libraryIds: [String]
    ) async throws -> [String] {
        let scopes: [String?] = libraryIds.isEmpty ? [nil] : libraryIds.map(Optional.some)
        var ids: [String] = []
        var seen = Set<String>()
        for libraryId in scopes {
            for id in try await fetchPersonalCollectionBookIds(
                collectionId: collectionId,
                libraryId: libraryId
            ) where seen.insert(id).inserted {
                ids.append(id)
            }
        }
        return ids
    }

    private func fetchPersonalCollectionBookIds(
        collectionId: String,
        libraryId: String?
    ) async throws -> [String] {
        var offset = 0
        var expectedTotal: Int?
        var snapshot: String?
        var ids: [String] = []

        while true {
            var query = [
                URLQueryItem(name: "source", value: "user_collection"),
                URLQueryItem(name: "collection_id", value: collectionId),
                URLQueryItem(name: "offset", value: String(offset)),
                URLQueryItem(name: "limit", value: String(pageSize)),
                URLQueryItem(name: "include_total", value: "true"),
            ]
            if let libraryId {
                query.append(URLQueryItem(name: "library_id", value: libraryId))
            }
            if let snapshot {
                query.append(URLQueryItem(name: "snapshot", value: snapshot))
            }

            let page = try await send(
                try makeRequest(path: "/catalog", query: query),
                as: SiloCatalogResponse.self
            )
            guard let hasMore = page.hasMore else {
                throw ProviderError.serverError("Silo did not return a collection pagination boundary")
            }
            if snapshot == nil {
                snapshot = page.snapshot
            } else if let pageSnapshot = page.snapshot, pageSnapshot != snapshot {
                throw ProviderError.serverError("Silo collection snapshot changed during refresh")
            }

            if snapshot != nil {
                if let expectedTotal, expectedTotal != page.total {
                    throw ProviderError.serverError("Silo collection changed during refresh")
                }
                expectedTotal = page.total
            }

            ids.append(
                contentsOf: page.items.compactMap { item in
                    let type = item.type.lowercased()
                    return type == "audiobook" || type == "ebook"
                        ? item.contentID
                        : nil
                }
            )
            offset += page.items.count
            if !hasMore {
                if snapshot != nil, offset != page.total {
                    throw ProviderError.serverError("Silo returned an incomplete collection")
                }
                break
            }
            guard !page.items.isEmpty, offset <= 1_000_000 else {
                throw ProviderError.serverError("Silo collection pagination stalled")
            }
            if snapshot != nil, offset > page.total {
                throw ProviderError.serverError("Silo collection pagination stalled")
            }
        }
        return ids
    }

    private func fetchServerCollections(libraryIds: [String]) async throws -> [Collection] {
        let collectionLists = try await mapConcurrently(libraryIds) { libraryId in
            let response = try await self.send(
                try self.makeRequest(path: "/library/\(libraryId)/collections"),
                as: SiloLibraryCollectionsResponse.self
            )
            return response.collections
        }
        var seen = Set<String>()
        let summaries =
            collectionLists
            .flatMap { $0 }
            .filter { seen.insert($0.id).inserted }

        let fetched = try await mapConcurrently(summaries) { collection in
            let response = try await self.send(
                try self.makeRequest(
                    path: "/library/\(collection.libraryID)/collections/\(collection.id)/items"
                ),
                as: SiloCollectionBrowseResponse.self
            )
            guard !response.hasMore, response.total == response.items.count else {
                throw ProviderError.serverError("Silo returned an incomplete server collection")
            }
            let ids = response.items.compactMap { item in
                let type = item.type.lowercased()
                return type == "audiobook" || type == "ebook"
                    ? item.contentID
                    : nil
            }
            return (collection, ids)
        }
        let memberships = Dictionary(uniqueKeysWithValues: fetched.map { ($0.0.id, $0.1) })
        return
            summaries
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { collection in
                var mapped = Collection(
                    id: "silo-\(connection.id.uuidString)-server-\(collection.id)",
                    name: collection.title,
                    description: collection.description,
                    books: memberships[collection.id] ?? [],
                    bookCount: memberships[collection.id]?.count ?? 0,
                    iconName: collection.collectionType == "smart"
                        ? "wand.and.stars"
                        : "books.vertical",
                    color: collection.collectionType == "smart" ? "indigo" : "blue",
                    providerId: connection.id,
                    parentID: collection.groupID,
                    displayOrder: collection.sortOrder
                )
                if let posterURL = collection.posterURL, !posterURL.isEmpty {
                    mapped.representativeThumbs = [posterURL]
                }
                return mapped
            }
    }

    private func mapConcurrently<Input: Sendable, Output: Sendable>(
        _ values: [Input],
        limit: Int = 6,
        transform: @escaping @Sendable (Input) async throws -> Output
    ) async throws -> [Output] {
        guard !values.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: (Int, Output).self) { group in
            var nextIndex = 0
            while nextIndex < min(limit, values.count) {
                let index = nextIndex
                group.addTask { (index, try await transform(values[index])) }
                nextIndex += 1
            }

            var results: [(Int, Output)] = []
            results.reserveCapacity(values.count)
            while let result = try await group.next() {
                results.append(result)
                if nextIndex < values.count {
                    let index = nextIndex
                    group.addTask { (index, try await transform(values[index])) }
                    nextIndex += 1
                }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func itemDetail(_ id: String) async throws -> SiloItemDetail {
        if let cached = detailCache[id] { return cached }
        try await ensureAuthenticated()
        _ = try await ensureProfile()
        let detail = try await send(try makeRequest(path: "/catalog/items/\(id)"), as: SiloItemDetail.self)
        detailCache[id] = detail
        return detail
    }

    private func siloEbookProgress(
        for contentID: String,
        retryingAuth: Bool = true
    ) async throws -> SiloEbookProgress? {
        let request = try makeRequest(path: "/ebooks/\(contentID)/progress")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }
        if http.statusCode == 401,
            retryingAuth,
            await recoverAuthentication()
        {
            return try await siloEbookProgress(
                for: contentID,
                retryingAuth: false
            )
        }
        if http.statusCode == 404 || http.statusCode == 204 {
            return nil
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw ProviderError.unauthorized
            }
            throw ProviderError.serverError(
                "Silo returned HTTP \(http.statusCode)"
            )
        }
        guard !data.isEmpty else { return nil }
        do {
            return try decoder.decode(SiloEbookProgress.self, from: data)
        } catch {
            throw ProviderError.decodingFailed
        }
    }

    private func book(from item: SiloCatalogItem, libraryId: String) async throws -> Book? {
        switch item.type.lowercased() {
        case "audiobook", "ebook":
            let detail = try await itemDetail(item.contentID)
            return book(from: detail, libraryId: libraryId)
        default:
            return nil
        }
    }

    private func book(from detail: SiloItemDetail, libraryId: String) -> Book? {
        let type = detail.type.lowercased()
        guard type == "audiobook" || type == "ebook" else { return nil }

        let version = primaryVersion(for: detail)
        let isAudiobook = type == "audiobook"
        let partVersions = audiobookPartVersions(for: detail)
        let authors = detail.audiobook?.authors.map(\.name) ?? detail.ebook?.authors.map(\.name) ?? []
        let narrators = detail.audiobook?.narrators.map(\.name) ?? []
        let series = detail.audiobook?.series?.name ?? detail.ebook?.series?.name ?? detail.seriesTitle
        let duration: Double
        if let partVersions {
            duration = Double(partVersions.reduce(0) { $0 + ($1.duration ?? 0) })
        } else {
            duration = Double(detail.audiobook?.totalDurationSeconds ?? version?.duration ?? detail.runtime ?? 0)
        }
        let mappedChapters: [Chapter]? = {
            if let partVersions {
                return combinedChapters(for: partVersions)
            }
            guard let version else { return nil }
            return chapters(from: version, fallbackDuration: duration, isAudiobook: isAudiobook)
        }()
        let audioTracks: [AudioTrack]?
        if let partVersions {
            var offset = 0.0
            audioTracks = partVersions.enumerated().map { index, part in
                let partDuration = Double(part.duration ?? 0)
                defer { offset += partDuration }
                return AudioTrack(
                    index: index,
                    title: part.fileName ?? detail.title,
                    filePath: part.filePath,
                    contentUrl: nil,
                    duration: partDuration,
                    startOffset: offset,
                    fileSize: part.fileSize,
                    format: part.container,
                    bitrate: part.bitrate,
                    headers: getStreamingHeaders()
                )
            }
        } else if isAudiobook, let version {
            audioTracks = [
                AudioTrack(
                    index: 0,
                    title: version.fileName ?? detail.title,
                    filePath: version.filePath,
                    contentUrl: nil,
                    duration: duration,
                    startOffset: 0,
                    fileSize: version.fileSize,
                    format: version.container,
                    bitrate: version.bitrate,
                    headers: getStreamingHeaders()
                )
            ]
        } else {
            audioTracks = nil
        }

        return Book(
            id: detail.contentID,
            title: detail.title,
            author: authors.first,
            authors: authors.isEmpty ? nil : authors,
            narrator: narrators.isEmpty ? nil : narrators.joined(separator: ", "),
            seriesInfo: series.map { SeriesInfo(name: $0, sequence: nil) },
            duration: duration > 0 ? duration : nil,
            coverURL: coverURL(from: detail.posterURL),
            partKey: version.map { String($0.fileID) },
            audioFileIno: version.map { String($0.fileID) },
            audioTracks: audioTracks,
            mediaType: isAudiobook ? .audiobook : .ebook,
            ebookFormat: isAudiobook ? nil : ebookFormat(from: version),
            dateAdded: nil,
            description: detail.overview,
            genres: detail.genres ?? [],
            chapters: mappedChapters,
            publisher: detail.audiobook?.publisher ?? detail.ebook?.publisher,
            progress: 0,
            currentTime: detail.userData?.positionSeconds ?? 0,
            isFinished: detail.userData?.played ?? false,
            libraryId: libraryId,
            providerId: connection.id,
            backendId: connection.id.uuidString,
            source: .silo,
            filePath: version?.filePath,
            publishedYear: detail.year
        )
    }

    private func primaryVersion(for detail: SiloItemDetail) -> SiloFileVersion? {
        if detail.type.caseInsensitiveCompare("ebook") == .orderedSame {
            return preferredEbookVersion(for: detail, savedFileID: nil)
        }
        return detail.versions.first
    }

    private func audiobookPartVersions(for detail: SiloItemDetail) -> [SiloFileVersion]? {
        guard detail.type.caseInsensitiveCompare("audiobook") == .orderedSame,
            let variants = detail.playbackVariants, !variants.isEmpty
        else { return nil }
        let primaryFileID = detail.versions.first?.fileID
        let variant =
            variants.first(where: { candidate in
                candidate.parts.contains { $0.versions.contains { $0.fileID == primaryFileID } }
            }) ?? variants[0]
        guard variant.parts.count > 1 else { return nil }
        let parts = variant.parts
            .sorted { $0.partIndex < $1.partIndex }
            .compactMap { part in
                part.versions.first(where: { $0.fileID == part.defaultFileID }) ?? part.versions.first
            }
        return parts.count > 1 ? parts : nil
    }

    private func combinedChapters(for parts: [SiloFileVersion]) -> [Chapter] {
        var result: [Chapter] = []
        var offset = 0.0
        for (partIndex, part) in parts.enumerated() {
            let partDuration = Double(part.duration ?? 0)
            let partChapters = part.chapters ?? []
            if partChapters.isEmpty {
                result.append(
                    Chapter(
                        id: String(result.count),
                        start: offset,
                        end: offset + partDuration,
                        title: "Part \(partIndex + 1)",
                        index: result.count
                    )
                )
            } else {
                for chapter in partChapters {
                    result.append(
                        Chapter(
                            id: String(result.count),
                            start: offset + chapter.startSeconds,
                            end: offset + chapter.endSeconds,
                            title: chapter.title,
                            index: result.count
                        )
                    )
                }
            }
            offset += partDuration
        }
        return result
    }

    private func heartbeatMultipartSession(
        parts: [MultipartPartSession],
        currentTime: TimeInterval,
        isFinished: Bool
    ) async {
        guard let active = parts.last(where: { currentTime >= $0.startOffset }) ?? parts.first,
            var request = try? makeRequest(path: "/playback/\(active.sessionID)/progress", method: "POST")
        else {
            return
        }
        let localPosition = min(max(currentTime - active.startOffset, 0), active.duration)
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "position": localPosition,
            "is_paused": isFinished,
        ])
        try? await sendEmpty(request)
    }

    private func readableEbookVersions(for detail: SiloItemDetail) -> [SiloFileVersion] {
        detail.versions.filter { ebookFormat(from: $0) != nil }
    }

    private func preferredEbookVersion(
        for detail: SiloItemDetail,
        savedFileID: Int?
    ) -> SiloFileVersion? {
        let readable = readableEbookVersions(for: detail)
        if let savedFileID,
            let saved = readable.first(where: { $0.fileID == savedFileID })
        {
            return saved
        }
        return readable.first(where: {
            ebookFormat(from: $0) == EbookFormat.epub.rawValue
        }) ?? readable.first
    }

    private func activeEbookVersion(
        for detail: SiloItemDetail
    ) async throws -> SiloFileVersion? {
        let readable = readableEbookVersions(for: detail)
        if let activeFileID = activeEbookFileIDs[detail.contentID],
            let active = readable.first(where: { $0.fileID == activeFileID })
        {
            return active
        }

        let savedProgress = try await siloEbookProgress(for: detail.contentID)
        guard
            let selected = preferredEbookVersion(
                for: detail,
                savedFileID: savedProgress?.fileID
            )
        else {
            return nil
        }
        activeEbookFileIDs[detail.contentID] = selected.fileID
        return selected
    }

    private func chapters(from version: SiloFileVersion, fallbackDuration: Double, isAudiobook: Bool) -> [Chapter]? {
        let chapters = version.chapters ?? []
        guard !chapters.isEmpty else {
            guard isAudiobook else { return nil }
            let end = fallbackDuration > 0 ? fallbackDuration : Double(version.duration ?? 0)
            return [Chapter(id: "0", start: 0, end: end, title: "Track 1", index: 0)]
        }
        return chapters.map {
            Chapter(
                id: String($0.index),
                start: $0.startSeconds,
                end: $0.endSeconds,
                title: $0.title,
                index: $0.index
            )
        }
    }

    private func coverURL(from value: String?) -> URL? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let url = URL(string: raw), url.scheme != nil {
            return url
        }
        guard var components = URLComponents(string: baseURLString) else {
            return nil
        }
        components.path = raw.hasPrefix("/") ? raw : "\(components.path)/\(raw)"
        return components.url
    }

    private func absoluteURL(_ value: String) throws -> URL {
        if let url = URL(string: value), url.scheme != nil {
            return authenticatedStreamURL(url)
        }
        let resolvedValue: String
        if value == "/stream" || value.hasPrefix("/stream/") {
            resolvedValue = "\(baseURLString)/api/v1\(value)"
        } else {
            resolvedValue = baseURLString + (value.hasPrefix("/") ? value : "/\(value)")
        }
        guard let url = URL(string: resolvedValue) else {
            throw ProviderError.invalidURL
        }
        return authenticatedStreamURL(url)
    }

    private func authenticatedStreamURL(_ url: URL) -> URL {
        guard url.path.contains("/stream/"),
            let token = connection.token,
            !token.isEmpty,
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return url
        }
        var items = components.queryItems ?? []
        if !items.contains(where: { $0.name == "token" }) {
            items.append(URLQueryItem(name: "token", value: token))
            components.queryItems = items
        }
        return components.url ?? url
    }

    private func siloReaderLocation(
        from locator: String?,
        progress: Double,
        sourceEngine: ReaderEngineKind? = nil
    ) -> String {
        let trustedSourceEngine =
            sourceEngine
            ?? EpubLocationBridge.sourceEngine(from: locator)
        if trustedSourceEngine == .foliate,
            let cfi = EpubLocationBridge.canonicalFullEPUBCFI(
                EpubLocationBridge.epubCFI(from: locator)
            )
        {
            return cfi
        }
        let fraction = String(
            format: "%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            min(max(progress, 0), 1)
        )
        return "fraction:\(fraction)"
    }

    private func readiumLocator(fromSiloLocation location: String?, progress: Double) -> String? {
        guard let location = location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty else {
            return nil
        }
        if let cfi = EpubLocationBridge.canonicalFullEPUBCFI(location) {
            return EpubLocationBridge.readiumLocator(
                href: nil,
                epubCFI: cfi,
                fraction: progress,
                sourceEngine: .foliate
            )
        }
        if location.hasPrefix("fraction:") {
            return nil
        }
        if location.hasPrefix("{") {
            guard let sanitized = EpubLocationBridge.locatorForReadiumRestore(location) else {
                return nil
            }
            return EpubLocationBridge.markingSourceEngine(.readium, in: sanitized)
        }
        return nil
    }

    private func extractCFI(from locator: String?) -> String? {
        EpubLocationBridge.canonicalFullEPUBCFI(
            EpubLocationBridge.epubCFI(from: locator)
        )
    }

    private func ebookFormat(from version: SiloFileVersion?) -> String? {
        guard let version else { return nil }
        let candidates = [
            version.container,
            version.fileName.map { URL(fileURLWithPath: $0).pathExtension },
            version.filePath.map { URL(fileURLWithPath: $0).pathExtension },
        ]
        return
            candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
            .first { EbookFormat.from(fileExtension: $0) != nil }
    }

    private func mimeType(for container: String?) -> String {
        switch container?.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a", "m4b", "aac": return "audio/mp4"
        case "flac": return "audio/flac"
        case "ogg", "opus": return "audio/ogg"
        case "wav": return "audio/wav"
        default: return "audio/mpeg"
        }
    }

    private static let rfc3339Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated private static func decodeDate(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) {
            return date
        }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) {
            return date
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(raw)")
    }
}

struct SiloReaderAnnotationRecord: Decodable, Sendable {
    let id: String
    let contentID: String
    let kind: String
    let cfiRange: String?
    let location: String?
    let selectedText: String
    let note: String
    let style: String
    let color: String
    let metadata: [String: String]
    let createdAt: Date?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, kind, location, note, style, color, metadata
        case contentID = "content_id"
        case cfiRange = "cfi_range"
        case selectedText = "selected_text"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        contentID = try container.decode(String.self, forKey: .contentID)
        kind = try container.decode(String.self, forKey: .kind)
        cfiRange = try container.decodeIfPresent(String.self, forKey: .cfiRange)
        location = try container.decodeIfPresent(String.self, forKey: .location)
        selectedText = try container.decodeIfPresent(String.self, forKey: .selectedText) ?? ""
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        style = try container.decodeIfPresent(String.self, forKey: .style) ?? "highlight"
        color = try container.decodeIfPresent(String.self, forKey: .color) ?? "#facc15"
        metadata = (try? container.decode([String: String].self, forKey: .metadata)) ?? [:]
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

private struct SiloReaderAnnotationsEnvelope: Decodable {
    let items: [SiloReaderAnnotationRecord]?
}

private struct SiloReaderAnnotationRequest: Encodable {
    let kind: String
    let cfiRange: String?
    let location: String
    let selectedText: String
    let note: String
    let style: String
    let color: String
    let metadata: [String: String]

    enum CodingKeys: String, CodingKey {
        case kind, location, note, style, color, metadata
        case cfiRange = "cfi_range"
        case selectedText = "selected_text"
    }
}

private struct SiloLoginResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let user: SiloUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case user
    }
}

private struct SiloRefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

private struct SiloUser: Decodable {
    let id: Int
    let username: String
}

private struct SiloProfilesResponse: Decodable {
    let profiles: [SiloProfile]
}

private struct SiloProfile: Decodable {
    let id: String
    let name: String
    let isPrimary: Bool

    enum CodingKeys: String, CodingKey {
        case id, name
        case isPrimary = "is_primary"
    }
}

private struct SiloLibrary: Decodable {
    let id: Int
    let name: String
    let type: String
}

nonisolated private struct SiloPersonalCollectionsResponse: Decodable, Sendable {
    let collections: [SiloPersonalCollection]
}

nonisolated private struct SiloPersonalCollection: Decodable, Sendable {
    let id: String
    let name: String
    let description: String?
    let collectionType: String
    let sortOrder: Int
    let groupID: String?
    let posterURL: String?

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case collectionType = "collection_type"
        case sortOrder = "sort_order"
        case groupID = "group_id"
        case posterURL = "poster_url"
    }
}

nonisolated private struct SiloLibraryCollectionsResponse: Decodable, Sendable {
    let collections: [SiloLibraryCollection]
}

nonisolated private struct SiloLibraryCollection: Decodable, Sendable {
    let id: String
    let libraryID: Int
    let title: String
    let description: String?
    let collectionType: String
    let sortOrder: Int
    let groupID: String?
    let posterURL: String?

    enum CodingKeys: String, CodingKey {
        case id, title, description
        case libraryID = "library_id"
        case collectionType = "collection_type"
        case sortOrder = "sort_order"
        case groupID = "group_id"
        case posterURL = "poster_url"
    }
}

nonisolated private struct SiloCollectionBrowseResponse: Decodable, Sendable {
    let items: [SiloCollectionBrowseItem]
    let total: Int
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case items, total
        case hasMore = "has_more"
    }
}

nonisolated private struct SiloCollectionBrowseItem: Decodable, Sendable {
    let contentID: String
    let type: String

    enum CodingKeys: String, CodingKey {
        case type
        case contentID = "content_id"
    }
}

private struct SiloLibrariesEnvelope: Decodable {
    let libraries: [SiloLibrary]?
    let items: [SiloLibrary]?
}

private struct SiloCatalogResponse: Decodable {
    let total: Int
    let hasMore: Bool?
    let items: [SiloCatalogItem]
    let snapshot: String?

    enum CodingKeys: String, CodingKey {
        case total, items, snapshot
        case hasMore = "has_more"
    }
}

private struct SiloCatalogItem: Decodable {
    let contentID: String
    let type: String

    enum CodingKeys: String, CodingKey {
        case type
        case contentID = "content_id"
    }
}

private struct SiloItemDetail: Decodable {
    let contentID: String
    let type: String
    let title: String
    let year: Int?
    let overview: String?
    let runtime: Int?
    let genres: [String]?
    let posterURL: String?
    let seriesTitle: String?
    let userData: SiloProgressState?
    let versions: [SiloFileVersion]
    let playbackVariants: [SiloPlaybackVariant]?
    let audiobook: SiloAudiobookExtension?
    let ebook: SiloEbookExtension?

    enum CodingKeys: String, CodingKey {
        case type, title, year, overview, runtime, genres, versions, audiobook, ebook
        case contentID = "content_id"
        case posterURL = "poster_url"
        case seriesTitle = "series_title"
        case userData = "user_data"
        case playbackVariants = "playback_variants"
    }
}

private struct SiloPlaybackVariant: Decodable {
    let parts: [SiloPlaybackVariantPart]
}

private struct SiloPlaybackVariantPart: Decodable {
    let partIndex: Int
    let defaultFileID: Int?
    let versions: [SiloFileVersion]

    enum CodingKeys: String, CodingKey {
        case versions
        case partIndex = "part_index"
        case defaultFileID = "default_file_id"
    }
}

private struct SiloProgressState: Decodable {
    let positionSeconds: Double?
    let durationSeconds: Double?
    let played: Bool?

    enum CodingKeys: String, CodingKey {
        case positionSeconds = "position_seconds"
        case durationSeconds = "duration_seconds"
        case played
    }
}

private struct SiloProgressListResponse: Decodable {
    let progress: [SiloProgressEntry]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case progress
        case nextCursor = "next_cursor"
    }
}

private struct SiloProgressEntry: Decodable {
    let mediaItemID: String
    let positionSeconds: Double
    let durationSeconds: Double
    let completed: Bool
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case mediaItemID = "media_item_id"
        case positionSeconds = "position_seconds"
        case durationSeconds = "duration_seconds"
        case completed
        case updatedAt = "updated_at"
    }
}

private struct SiloProgressSyncRequest: Encodable {
    let items: [SiloProgressSyncItem]
}

private struct SiloProgressSyncItem: Encodable {
    let mediaItemID: String
    let position: Double
    let duration: Double
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case mediaItemID = "media_item_id"
        case position, duration
        case updatedAt = "updated_at"
    }
}

private struct SiloProgressSyncResponse: Decodable {
    let results: [SiloProgressSyncResult]
}

private struct SiloProgressSyncResult: Decodable {
    let mediaItemID: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case mediaItemID = "media_item_id"
        case status
    }
}

private struct SiloAudiobookExtension: Decodable {
    let authors: [SiloPerson]
    let narrators: [SiloPerson]
    let publisher: String?
    let totalDurationSeconds: Int?
    let series: SiloSeriesGroup?

    enum CodingKeys: String, CodingKey {
        case authors, narrators, publisher, series
        case totalDurationSeconds = "total_duration_seconds"
    }
}

private struct SiloEbookExtension: Decodable {
    let authors: [SiloPerson]
    let publisher: String?
    let series: SiloSeriesGroup?
}

private struct SiloPerson: Decodable {
    let name: String
}

private struct SiloSeriesGroup: Decodable {
    let name: String?
}

private struct SiloFileVersion: Decodable {
    let fileID: Int
    let fileName: String?
    let filePath: String?
    let container: String?
    let fileSize: Int64?
    let duration: Int?
    let bitrate: Int?
    let addedAt: Date?
    let chapters: [SiloChapter]?

    enum CodingKeys: String, CodingKey {
        case container, duration, bitrate, chapters
        case fileID = "file_id"
        case fileName = "file_name"
        case filePath = "file_path"
        case fileSize = "file_size"
        case addedAt = "added_at"
    }
}

private struct SiloChapter: Decodable {
    let index: Int
    let title: String
    let startSeconds: Double
    let endSeconds: Double

    enum CodingKeys: String, CodingKey {
        case index, title
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
    }
}

private struct SiloPlaybackStartResponse: Decodable {
    let sessionID: String
    let streamURL: String
    let position: Double?
    let durationSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case position
        case sessionID = "session_id"
        case streamURL = "stream_url"
        case durationSeconds = "duration_seconds"
    }
}

private struct SiloEbookProgress: Decodable {
    let fileID: Int?
    let location: String?
    let progress: Double?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case location, progress
        case fileID = "file_id"
        case updatedAt = "updated_at"
    }
}

private extension Sequence {
    func asyncCompactMap<T>(_ transform: (Element) async throws -> T?) async throws -> [T] {
        var values: [T] = []
        for element in self {
            if let value = try await transform(element) {
                values.append(value)
            }
        }
        return values
    }
}
