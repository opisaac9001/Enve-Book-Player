import CryptoKit
import Foundation
import Logging

struct SiloEbookProgressUpdateRequest: Encodable {
    let fileID: String
    let location: String
    let progress: Double
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case location
        case progress
        case updatedAt = "updated_at"
    }
}

struct SiloReaderAnnotationMutation {
    let record: SiloReaderAnnotationRecord
    let created: Bool
}

enum SiloReaderAnnotationError: Error, Equatable {
    case preconditionFailed
    case notFound
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
    private let progressPageSize = 200
    private let annotationPageSize = 50
    private let progressBatchLimit = 100
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder = JSONEncoder()

    private var detailCache: [String: SiloItemDetail] = [:]
    private var activeEbookFileIDs: [String: String] = [:]
    private var multipartSessions: [String: [MultipartPartSession]] = [:]
    private var singleSessionFiles: [String: String] = [:]
    private var replacementSessionIDs: [String: String] = [:]
    private var pausedSessionIDs: Set<String> = []
    private var playbackInstallationID: String?
    private var progressSequences: [String: Int64] = [:]
    private var pendingStops: [String: PendingStop] = [:]
    private var authenticationRecovery: Task<Bool, Never>?

    private struct MultipartPartSession {
        let sessionID: String
        let startOffset: Double
        let duration: Double
    }

    private struct PendingStop {
        let stopID: String
        let sequence: Int64?
        let position: Double?
    }

    private let keychain: SharedKeychainStore
    private let legacyKeychain: KeychainHelper
    private let defaults: UserDefaults
    private let rejectedContent: RejectedContentStore
    private var streamTasks: [UUID: Task<Void, Never>] = [:]
    private var isRetired = false
    private let ownsSession: Bool
    private let serverSyncEnabled: () -> Bool

    func retire() async {
        isRetired = true
        onTokenUpdated = nil
        let tasks = Array(streamTasks.values)
        for task in tasks { task.cancel() }
        if ownsSession { session.invalidateAndCancel() }
        for task in tasks { await task.value }
        streamTasks.removeAll()
    }

    init(connection: ServerConnection, session overrideSession: URLSession? = nil, profileSession: ProfileSession? = nil) {
        self.connection = connection
        if let profileSession {
            serverSyncEnabled = { [unowned profileSession] in profileSession.serverSyncEnabled }
        } else {
            serverSyncEnabled = { true }
        }
        ownsSession = profileSession != nil && overrideSession == nil
        keychain = profileSession?.keychain ?? .shared
        legacyKeychain = profileSession?.legacyKeychain ?? .shared
        defaults = profileSession?.defaults ?? .standard
        rejectedContent = profileSession?.rejectedContent ?? .shared
        let config = profileSession?.isOwner == false ? URLSessionConfiguration.ephemeral : .default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = false
        if let customHeaders = connection.customHeaders {
            config.httpAdditionalHeaders = customHeaders
        }
        if let overrideSession {
            self.session = overrideSession
        } else if let profileSession {
            self.session = profileSession.transport.makeSession(configuration: config)
        } else if connection.mtlsEnabled {
            self.session = MTLSManager.shared.makeSession(for: connection.id, configuration: config)
        } else {
            self.session = InsecureURLSession.shared
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(Self.decodeDate)
        self.decoder = decoder
    }

    func validateConnection() async throws -> Bool {
        try EnveProvenance.checkServerAddress(connection.url)
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
        _ = try await ensureProfile()
        let libraries = try await send(
            try makeRequest(path: "/user/libraries"),
            as: SiloLibrariesResponse.self
        ).items
        return
            libraries
            .filter { ["audiobooks", "audiobook", "ebooks", "ebook", "books", "manga"].contains($0.type.lowercased()) }
            .map {
                let rawType = $0.type.lowercased()
                return Library(
                    id: $0.id,
                    name: $0.name,
                    type: rawType.contains("audio") ? "audiobooks" : "books",
                    providerId: connection.id
                )
            }
    }

    func fetchBooks(libraryId: String) async throws -> [Book] {
        let traversal = try await catalogTraversal(libraryId: libraryId, resumeAfter: nil, expectedSnapshotIdentifier: nil)
        var books: [Book] = []
        while let batch = try await traversal.next() {
            books.append(contentsOf: batch.books)
        }
        return books
    }

    func makeCatalogBatchSource(
        libraryId: String,
        resumeAfter: String?,
        expectedSnapshotIdentifier: String?
    ) async throws -> LibraryCatalogBatchSource {
        let traversal = try await catalogTraversal(
            libraryId: libraryId,
            resumeAfter: resumeAfter,
            expectedSnapshotIdentifier: expectedSnapshotIdentifier
        )
        return LibraryCatalogBatchSource(
            snapshotIdentifier: traversal.snapshotIdentifier,
            resumed: traversal.resumed,
            next: { try await traversal.next() }
        )
    }

    // A stored cursor resumes only when the first page still fingerprints the same snapshot and the server accepts it.
    private func catalogTraversal(
        libraryId: String,
        resumeAfter: String?,
        expectedSnapshotIdentifier: String?
    ) async throws -> SiloCatalogTraversal {
        detailCache.removeAll()
        let firstPage = try await catalogPage(libraryId: libraryId, cursor: nil, index: 0)
        let snapshotIdentifier = Self.snapshotIdentifier(of: firstPage)
        var start = firstPage
        var resumed = false
        if let resumeAfter, !resumeAfter.isEmpty, expectedSnapshotIdentifier == snapshotIdentifier {
            do {
                start = try await catalogPage(libraryId: libraryId, cursor: resumeAfter, index: 1)
                resumed = true
            } catch SiloCursorError.invalid {}
        }
        return SiloCatalogTraversal(
            snapshotIdentifier: snapshotIdentifier,
            resumed: resumed,
            firstPage: start,
            totalCount: firstPage.totalCount,
            fetchPage: { try await self.catalogPage(libraryId: libraryId, cursor: $0, index: $1) }
        )
    }

    private func catalogPage(libraryId: String, cursor: String?, index: Int) async throws -> SiloCatalogPage {
        let response = try await fetchCatalogPage(
            libraryId: libraryId,
            cursor: cursor,
            sort: "title",
            limit: pageSize,
            fallbackScope: "page-\(index)"
        )
        let mapped = try await mapCatalogItems(
            response.items,
            libraryId: libraryId,
            fallbackScope: "page-\(index)-detail"
        )
        return SiloCatalogPage(
            books: mapped.books,
            totalCount: response.total,
            nextCursor: try SiloPageInfo.continuation(of: response.page),
            isComplete: response.rejectedItems.isEmpty && mapped.rejectedItems.isEmpty
        )
    }

    func fetchBookBatches(libraryId: String) -> AsyncThrowingStream<LibraryFetchBatchResult, Error> {
        AsyncThrowingStream { continuation in
            guard !isRetired else {
                continuation.finish(throwing: CancellationError())
                return
            }
            let id = UUID()
            let task = Task {
                defer { self.streamTasks[id] = nil }
                do {
                    try Task.checkCancellation()
                    let traversal = try await self.catalogTraversal(
                        libraryId: libraryId,
                        resumeAfter: nil,
                        expectedSnapshotIdentifier: nil
                    )
                    var loaded = 0
                    while let batch = try await traversal.next() {
                        try Task.checkCancellation()
                        loaded += batch.books.count
                        continuation.yield(
                            LibraryFetchBatchResult(books: batch.books, loadedSoFar: loaded, totalCount: batch.totalCount)
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            streamTasks[id] = task
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func fetchRecentBooks(libraryId: String, limit: Int) async throws -> [Book] {
        detailCache.removeAll()
        let batch = try await fetchCatalogPage(
            libraryId: libraryId,
            cursor: nil,
            sort: "-added_at",
            limit: min(max(limit, 1), pageSize),
            fallbackScope: "recent"
        )
        return try await mapCatalogItems(
            batch.items,
            libraryId: libraryId,
            fallbackScope: "recent-detail"
        ).books
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
        var progress: [UserMediaProgress] = []
        try await traversePages(SiloProgressPage.self) { cursor in
            var query = [URLQueryItem(name: "limit", value: String(self.progressPageSize))]
            if !libraryId.isEmpty {
                query.append(URLQueryItem(name: "library_id", value: libraryId))
            }
            if let cursor {
                query.append(URLQueryItem(name: "cursor", value: cursor))
            }
            return try self.makeRequest(path: "/progress", query: query)
        } handle: { page in
            progress.append(contentsOf: page.items.map(self.userMediaProgress))
        }
        return progress
    }

    func activityProfileID() async throws -> String {
        try await ensureAuthenticated()
        return try await ensureProfile()
    }

    func syncAudiobookProgress(_ updates: [UserMediaProgress]) async throws -> Set<String> {
        guard !updates.isEmpty else { return [] }
        try await ensureAuthenticated()
        _ = try await ensureProfile()

        // The batch refuses duplicate targets, so only each item's latest write is sent.
        var latest: [String: UserMediaProgress] = [:]
        var order: [String] = []
        for update in updates {
            if let existing = latest[update.libraryItemId] {
                if update.lastUpdate >= existing.lastUpdate { latest[update.libraryItemId] = update }
            } else {
                order.append(update.libraryItemId)
                latest[update.libraryItemId] = update
            }
        }

        var succeeded = Set<String>()
        for start in stride(from: 0, to: order.count, by: progressBatchLimit) {
            let items = order[start..<min(start + progressBatchLimit, order.count)].compactMap { id in
                latest[id].map { progress in
                    let duration = max(0, progress.duration)
                    let position = progress.isFinished && duration > 0 ? duration : max(0, progress.currentTime)
                    return SiloProgressSyncItem(
                        mediaItemID: progress.libraryItemId,
                        positionMs: Self.milliseconds(position),
                        durationMs: Self.milliseconds(duration),
                        updatedAt: Self.rfc3339Formatter.string(from: progress.lastUpdate)
                    )
                }
            }
            var request = try makeRequest(path: "/sync/progress", method: "POST")
            request.httpBody = try encoder.encode(SiloProgressSyncRequest(items: items))
            let response = try await send(request, as: SiloProgressSyncResponse.self)
            succeeded.formUnion(response.items.lazy.filter { $0.status == "success" }.map(\.mediaItemID))
        }
        return succeeded
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
            if let proof = legacyKeychain.get(profileTokenKey) { headers["X-Profile-Token"] = proof }
        }
        return headers
    }

    func audiobookDownloadRequests(for book: Book) async throws -> [(request: URLRequest, mimeType: String?)] {
        try await ensureAuthenticated()
        _ = try await ensureProfile()
        let detail = try await itemDetail(book.id)
        let versions = audiobookPartVersions(for: detail) ?? primaryVersion(for: detail).map { [$0] } ?? []
        guard !versions.isEmpty else { throw ProviderError.invalidResponse }
        return try versions.map { version in
            let request = try makeRequest(path: "/direct-download", query: [URLQueryItem(name: "file_id", value: version.fileID)])
            return (request, mimeType(for: version.container))
        }
    }

    func startPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo {
        try await ensureAuthenticated()
        let profileID = try await ensureProfile()
        await flushPendingStops()
        let detail = try await itemDetail(book.id)
        multipartSessions[book.id] = nil
        singleSessionFiles[book.id] = nil

        if let parts = audiobookPartVersions(for: detail) {
            return try await startMultipartPlayback(parts: parts, profileID: profileID, book: book)
        }

        guard let version = primaryVersion(for: detail) else {
            throw ProviderError.serverError("No playable Silo file is available")
        }
        let response = try await startPartSession(
            fileID: version.fileID,
            profileID: profileID,
            disableProgressPersistence: !serverSyncEnabled()
        )
        let (sessionID, plan) = try response.audioPlan()
        singleSessionFiles[book.id] = version.fileID
        let duration = plan.source.durationSeconds ?? Double(version.duration ?? detail.runtimeSeconds ?? 0)
        let streamURL = try absoluteURL(plan.stream.url).absoluteString
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
            sessionId: sessionID,
            audioTracks: [track],
            chapters: chapters,
            serverCurrentTime: serverSyncEnabled() ? plan.timeline.sourceStartSeconds : nil
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
            let (sessionID, plan) = try response.audioPlan()
            let partDuration = plan.source.durationSeconds ?? Double(part.duration ?? 0)
            let streamURL = try absoluteURL(plan.stream.url).absoluteString
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
                    sessionID: sessionID,
                    startOffset: offset,
                    duration: partDuration
                )
            )
            if index == 0 { serverPosition = 0 }
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
        fileID: String,
        profileID: String,
        disableProgressPersistence: Bool,
        startPosition: Double? = nil
    ) async throws -> SiloPlaybackStartResponse {
        let attemptID = Self.canonicalUUID()
        let audioCodecs = ["aac", "mp3"]
        let containers = ["mp3", "m4a", "m4b", "aac", "mp4"]
        let (data, http) = try await sendPlaybackCommand(path: "/playback/start", method: "POST") { installationID in
            var body: [String: Any] = [
                "installation_id": installationID,
                "protocol_version": 3,
                "client_features": [],
                "file_id": fileID,
                "profile_id": profileID,
                "playback_attempt_id": attemptID,
                "quality_preference": "original",
                "subtitle_fidelity_preference": "compatible",
                "progress_persistence": disableProgressPersistence ? "client" : "server",
                "client_capabilities": [
                    "video_evidence": "declared", "audio_evidence": "declared",
                    "codecs_video": [String](), "codecs_video_hardware": [String](),
                    "codecs_audio": audioCodecs, "containers": containers, "hdr": false,
                ],
                "client_playback_context": [
                    "protocol_version": 3, "form_factor": "phone",
                    "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                    "output": [String: String](),
                    "device": ["platform": "ios"],
                    "deliveries": ["original_http": [
                        "enabled": true, "supported_on_device": true,
                        "containers": containers, "video_codecs": [String](), "audio_decode_codecs": audioCodecs,
                        "audio_passthrough_codecs": [], "subtitles": [
                            "embedded_text": false, "sidecar_text": false, "ass_styling": false,
                            "embedded_bitmap": false, "sidecar_bitmap": false, "font_attachments": false,
                        ], "features": [], "auth_header_refresh": false,
                        "validated_claims": [], "transformations": [],
                    ]],
                ],
            ]
            if disableProgressPersistence || startPosition != nil {
                body["start_position"] = startPosition ?? 0
            }
            return try JSONSerialization.data(withJSONObject: body)
        }
        try validate(http, data)
        return try decode(SiloPlaybackStartResponse.self, from: data)
    }

    func updatePlaybackProgress(
        book: Book,
        sessionId: String?,
        currentTime: TimeInterval,
        isFinished: Bool,
        timeListened: TimeInterval
    ) async throws {
        guard serverSyncEnabled() else { return }
        if let sessionId, !sessionId.isEmpty {
            if let parts = multipartSessions[book.id], parts.contains(where: { $0.sessionID == sessionId }) {
                await heartbeatMultipartSession(parts: parts, currentTime: currentTime, isPaused: pausedSessionIDs.contains(sessionId))
            } else {
                let activeSessionID = replacementSessionIDs[sessionId] ?? sessionId
                let isPaused = pausedSessionIDs.contains(sessionId) || pausedSessionIDs.contains(activeSessionID)
                do {
                    try await sendProgressSample(sessionID: activeSessionID, position: currentTime, isPaused: isPaused)
                    return
                } catch is CancellationError {
                    throw CancellationError()
                } catch SiloPlaybackError.sessionNotFound {
                    if let fileID = singleSessionFiles[book.id] {
                        do {
                            let profileID = try await ensureProfile()
                            let response = try await startPartSession(
                                fileID: fileID,
                                profileID: profileID,
                                disableProgressPersistence: !serverSyncEnabled(),
                                startPosition: max(0, currentTime)
                            )
                            let (newSessionID, _) = try response.audioPlan()
                            replacementSessionIDs[sessionId] = newSessionID
                            replacementSessionIDs[activeSessionID] = newSessionID
                            try await sendProgressSample(sessionID: newSessionID, position: currentTime, isPaused: isPaused)
                            return
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            // Keep the position through item-level sync when session recovery fails.
                        }
                    }
                } catch {}
            }
        }

        // Replayed queue entries carry their original event time on the book.
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
            lastUpdate: book.lastUpdate,
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
        let request = try makeRequest(
            path: "/ebooks/\(Self.pathSegment(book.id))/files/\(Self.pathSegment(fileID))/read"
        )
        let tempURL = try await downloadFile(request)

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
        let eventDate = book.lastUpdate
        let detail = try await itemDetail(book.id)
        guard let version = try await activeEbookVersion(for: detail) else {
            throw ProviderError.invalidResponse
        }
        let boundedProgress = min(max(progress, 0), 1)
        let location = siloReaderLocation(
            from: epubLocator,
            progress: boundedProgress,
            sourceEngine: sourceEngine
        )

        var request = try makeRequest(path: "/ebooks/\(Self.pathSegment(book.id))/progress", method: "PUT")
        request.httpBody = try encoder.encode(
            SiloEbookProgressUpdateRequest(
                fileID: version.fileID,
                location: location,
                progress: boundedProgress,
                updatedAt: Self.rfc3339Formatter.string(from: eventDate)
            )
        )
        try await sendEmpty(request)
    }

    func fetchEbookProgress(for book: Book) async throws -> (progress: Double, locator: String?, updatedAt: Date?, isFinished: Bool)? {
        try await ensureAuthenticated()
        _ = try await ensureProfile()
        guard let progress = try await siloEbookProgress(for: book.id) else {
            return nil
        }
        if let activeFileID = activeEbookFileIDs[book.id],
            activeFileID != progress.fileID
        {
            return nil
        }
        let detail = try await itemDetail(book.id)
        guard
            let selectedVersion = readableEbookVersions(for: detail)
                .first(where: { $0.fileID == progress.fileID })
        else {
            return nil
        }
        activeEbookFileIDs[detail.contentID] = selectedVersion.fileID
        let locator = readiumLocator(
            fromSiloLocation: progress.location,
            progress: progress.progress
        )
        return (progress.progress, locator, progress.updatedAt, progress.progress >= Book.finishedProgressThreshold)
    }

    func fetchAudiobookProgress(
        for book: Book
    ) async throws -> (positionSeconds: TimeInterval, percentage: Double, trackIndex: Int?, updatedAt: Date?, isFinished: Bool)? {
        detailCache.removeValue(forKey: book.id)
        let detail = try await itemDetail(book.id)
        guard let userData = detail.userData,
            let position = userData.positionSeconds,
            let duration = userData.durationSeconds ?? book.duration,
            duration > 0
        else { return nil }
        let percentage = min(max(position / duration, 0), 1)

        return (position, percentage, nil, nil, userData.played ?? (percentage >= Book.finishedProgressThreshold))
    }

    func fetchPageCount(for book: Book) async throws -> Int { throw ProviderError.notImplemented }
    func fetchPage(_ pageNumber: Int, for book: Book) async throws -> Data { throw ProviderError.notImplemented }

    func readerArtifactScope(for book: Book) async throws -> SiloReaderArtifactScope {
        try await ensureAuthenticated()
        let profileID = try await ensureProfile()
        return SiloReaderArtifactScope(
            connectionID: connection.id,
            account: "\(connection.userId ?? "")/\(profileID)",
            bookID: book.stableId
        )
    }

    func fetchReaderAnnotations(for book: Book) async throws -> [SiloReaderAnnotationRecord] {
        let resource = try await annotationResource(for: book)
        var records: [SiloReaderAnnotationRecord] = []
        try await traversePages(SiloReaderAnnotationsPage.self) { cursor in
            var query = [URLQueryItem(name: "limit", value: String(self.annotationPageSize))]
            if let cursor {
                query.append(URLQueryItem(name: "cursor", value: cursor))
            }
            return try self.makeRequest(path: "/ebooks/\(Self.pathSegment(book.id))/annotations", query: query)
        } handle: { page in
            records.append(contentsOf: page.items)
        }
        let fingerprint = annotationResourceFingerprint(for: resource.version)
        return records.filter { record in
            if let rawFileID = record.metadata[Self.annotationFileIDKey],
                rawFileID != resource.version.fileID
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

    // The local artifact ID is the client-selected server identity, so a retried create resolves to the same row.
    func createReaderAnnotation(for book: Book, annotation: ReaderAnnotation) async throws -> SiloReaderAnnotationMutation {
        let body = try await annotationBody(for: book, annotation: annotation)
        return try await createAnnotationRecord(id: annotation.id, body: body, for: book)
    }

    func createReaderBookmark(for book: Book, bookmark: Bookmark) async throws -> SiloReaderAnnotationMutation {
        let body = try await bookmarkBody(for: book, bookmark: bookmark)
        return try await createAnnotationRecord(id: bookmark.id, body: body, for: book)
    }

    func updateReaderAnnotation(
        id: String,
        etag: String,
        for book: Book,
        annotation: ReaderAnnotation
    ) async throws -> SiloReaderAnnotationRecord {
        let body = try await annotationBody(for: book, annotation: annotation)
        return try await patchAnnotationRecord(id: id, etag: etag, body: body, for: book)
    }

    func updateReaderBookmark(
        id: String,
        etag: String,
        for book: Book,
        bookmark: Bookmark
    ) async throws -> SiloReaderAnnotationRecord {
        let body = try await bookmarkBody(for: book, bookmark: bookmark)
        return try await patchAnnotationRecord(id: id, etag: etag, body: body, for: book)
    }

    func deleteReaderAnnotation(id: String, etag: String, for book: Book) async throws {
        try await ensureAuthenticated()
        _ = try await ensureProfile()
        var request = try makeRequest(
            path: "/ebooks/\(Self.pathSegment(book.id))/annotations/\(Self.pathSegment(id))",
            method: "DELETE"
        )
        request.setValue(etag, forHTTPHeaderField: "If-Match")
        let (data, http) = try await perform(request)
        switch http.statusCode {
        case 404: return
        case 412: throw SiloReaderAnnotationError.preconditionFailed
        default: try validate(http, data)
        }
    }

    private static let annotationFileIDKey = "enve_file_id"
    private static let annotationFingerprintKey = "enve_resource_fingerprint"

    private func annotationBody(for book: Book, annotation: ReaderAnnotation) async throws -> SiloReaderAnnotationRequest {
        guard let cfi = extractCFI(from: annotation.locator) else {
            throw ProviderError.noCFI
        }
        let resource = try await annotationResource(for: book)
        return SiloReaderAnnotationRequest(
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
    }

    private func bookmarkBody(for book: Book, bookmark: Bookmark) async throws -> SiloReaderAnnotationRequest {
        let resource = try await annotationResource(for: book)
        return SiloReaderAnnotationRequest(
            kind: "bookmark",
            cfiRange: nil,
            location: siloReaderLocation(from: bookmark.locator, progress: bookmark.position),
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
    }

    private func createAnnotationRecord(
        id: String,
        body: SiloReaderAnnotationRequest,
        for book: Book
    ) async throws -> SiloReaderAnnotationMutation {
        var body = body
        body.id = id
        var request = try makeRequest(path: "/ebooks/\(Self.pathSegment(book.id))/annotations", method: "POST")
        request.httpBody = try encoder.encode(body)
        let (data, http) = try await perform(request)
        try validate(http, data)
        return SiloReaderAnnotationMutation(
            record: try decode(SiloReaderAnnotationRecord.self, from: data),
            created: http.statusCode == 201
        )
    }

    private func patchAnnotationRecord(
        id: String,
        etag: String,
        body: SiloReaderAnnotationRequest,
        for book: Book
    ) async throws -> SiloReaderAnnotationRecord {
        var request = try makeRequest(
            path: "/ebooks/\(Self.pathSegment(book.id))/annotations/\(Self.pathSegment(id))",
            method: "PATCH"
        )
        request.setValue(etag, forHTTPHeaderField: "If-Match")
        request.httpBody = try encoder.encode(body)
        let (data, http) = try await perform(request)
        switch http.statusCode {
        case 404: throw SiloReaderAnnotationError.notFound
        case 412: throw SiloReaderAnnotationError.preconditionFailed
        default: try validate(http, data)
        }
        return try decode(SiloReaderAnnotationRecord.self, from: data)
    }

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
            version.fileID,
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
        metadata[Self.annotationFileIDKey] = version.fileID
        metadata[Self.annotationFingerprintKey] = annotationResourceFingerprint(
            for: version
        )
        return metadata
    }

    func ensureAuthenticated() async throws {
        if let token = connection.token, !token.isEmpty {
            return
        }
        if let storedToken = keychain.token(forConnectionId: connection.id.uuidString), !storedToken.isEmpty {
            connection.token = storedToken
            return
        }
        if await refreshAccessToken() {
            return
        }
        if connection.password?.isEmpty ?? true,
            let storedPassword = keychain.password(forConnectionId: connection.id.uuidString),
            !storedPassword.isEmpty
        {
            connection.password = storedPassword
        }
        if connection.password?.isEmpty ?? true,
            let storedPassword = legacyKeychain.get(legacyPasswordKey),
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
        applySession(response)
    }

    private func applySession(_ response: SiloLoginResponse) {
        connection.token = response.accessToken
        connection.username = response.user.username
        connection.userId = response.user.id
        storeRefreshToken(response.refreshToken)
        notifyTokenUpdated()
    }

    func nativeOAuthOptions() async throws -> [OAuthOption] {
        let capabilitiesRequest = try makeRequest(
            path: "/auth/oauth/capabilities", profileRequired: false, includeAuth: false
        )
        let (data, http) = try await perform(capabilitiesRequest, retryingAuth: false)
        // Servers that predate the v2 OAuth contract do not expose the capabilities endpoint.
        if http.statusCode == 404 { throw SiloOAuthError.nativeSignInUnavailable }
        guard (200...299).contains(http.statusCode) else {
            throw ProviderError.serverError("Silo returned HTTP \(http.statusCode)")
        }
        guard let capabilities = try? decoder.decode(SiloOAuthCapabilities.self, from: data) else {
            throw ProviderError.decodingFailed
        }
        guard capabilities.native else { throw SiloOAuthError.nativeSignInUnavailable }

        let providers = try await send(
            try makeRequest(path: "/auth/providers", profileRequired: false, includeAuth: false),
            as: SiloAuthProvidersResponse.self,
            retryingAuth: false
        )
        let options = providers.items.compactMap { item -> OAuthOption? in
            guard item.mode == "oauth", let path = item.nativeStartPath, !path.isEmpty else { return nil }
            return OAuthOption(displayName: item.displayName.isEmpty ? "Single Sign-On" : item.displayName, nativeStartPath: path)
        }
        guard !options.isEmpty else { throw SiloOAuthError.noProviders }
        return options
    }

    func beginNativeOAuth(with option: OAuthOption) async throws -> NativeOAuthAttempt {
        guard let base = URL(string: baseURLString), let issuer = Self.origin(of: base) else {
            throw ProviderError.invalidURL
        }
        let identity = try await send(
            try makeRequest(path: "/system/identity", profileRequired: false, includeAuth: false),
            as: SiloServerIdentity.self,
            retryingAuth: false
        )
        guard !identity.serverID.isEmpty else { throw ProviderError.invalidResponse }

        let path = option.nativeStartPath
        guard path.hasPrefix("/api/v2/auth/oauth/"), path.hasSuffix("/native/start"),
            !path.contains("?"), !path.contains("#"), !path.contains(".."),
            var components = URLComponents(string: baseURLString + path),
            let startURL = components.url,
            Self.origin(of: startURL) == issuer
        else {
            throw SiloOAuthError.invalidStartPath
        }

        let codeVerifier = Self.randomURLSafeString(byteCount: 32)
        let state = Self.randomURLSafeString(byteCount: 32)
        let challenge = Self.base64URLEncoded(Data(SHA256.hash(data: Data(codeVerifier.utf8))))
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "app_state", value: state),
        ]
        guard let authorizationURL = components.url else { throw SiloOAuthError.invalidStartPath }
        return NativeOAuthAttempt(
            authorizationURL: authorizationURL,
            codeVerifier: codeVerifier,
            state: state,
            serverID: identity.serverID,
            issuer: issuer
        )
    }

    func completeNativeOAuth(callbackURL: URL, attempt: NativeOAuthAttempt) async throws {
        let code = try attempt.authorizationCode(from: callbackURL)
        var request = try makeRequest(
            path: "/auth/oauth/complete", method: "POST", profileRequired: false, includeAuth: false
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code,
            "code_verifier": attempt.codeVerifier,
        ])
        let response = try await send(request, as: SiloLoginResponse.self, retryingAuth: false)
        connection.authMode = .sso
        applySession(response)
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
            let storedPassword = keychain.password(forConnectionId: connection.id.uuidString),
            !storedPassword.isEmpty
        {
            connection.password = storedPassword
        }
        if connection.password?.isEmpty ?? true,
            let storedPassword = legacyKeychain.get(legacyPasswordKey),
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

    func loginProfiles() async throws -> [SiloProfile] {
        try await ensureAuthenticated()
        let user = try await send(try makeRequest(path: "/account/me", profileRequired: false), as: SiloUser.self)
        connection.userId = user.id
        connection.username = user.username
        return try await send(
            try makeRequest(path: "/profiles", profileRequired: false), as: SiloProfilesResponse.self
        ).items
    }

    func selectLoginProfile(_ profile: SiloProfile, pin: String?) async throws {
        if let stored = storedProfileID(), stored != profile.id {
            throw ProviderError.serverError("Add a separate connection to use another Silo profile.")
        }
        if profile.hasPIN == true {
            var request = try makeRequest(
                path: "/profiles/\(Self.pathSegment(profile.id))/verify-pin", method: "POST", profileRequired: false
            )
            request.httpBody = try JSONSerialization.data(withJSONObject: ["pin": pin ?? ""])
            let proof = try await send(request, as: SiloProfileProof.self)
            guard proof.valid, let token = proof.profileToken, !token.isEmpty else {
                throw ProviderError.serverError("Incorrect Silo profile PIN.")
            }
            legacyKeychain.set(token, key: profileTokenKey)
        } else {
            legacyKeychain.delete(profileTokenKey)
        }
        storeProfile(profile)
    }

    func restoreLoginProfile(from original: ServerConnection) throws {
        guard original.userId == nil || original.userId == connection.userId else {
            throw ProviderError.serverError("Sign in to the same Silo account to preserve this connection’s downloads and progress.")
        }
        let oldID = defaults.string(forKey: "silo_profile_id_\(original.id.uuidString)")
        guard oldID == nil || oldID == storedProfileID() else {
            throw ProviderError.serverError("Sign in to the same Silo profile to preserve this connection’s downloads and progress.")
        }
        for suffix in ["id", "name", "user_id"] {
            let source = "silo_profile_\(suffix)_\(connection.id.uuidString)"
            if let value = defaults.string(forKey: source) {
                defaults.set(value, forKey: "silo_profile_\(suffix)_\(original.id.uuidString)")
                defaults.removeObject(forKey: source)
            }
        }
        let destination = "silo_profile_token_\(original.id.uuidString)"
        if let token = legacyKeychain.get(profileTokenKey) {
            legacyKeychain.set(token, key: destination)
        } else {
            legacyKeychain.delete(destination)
        }
        legacyKeychain.delete(profileTokenKey)
    }

    func ensureProfile() async throws -> String {
        if let stored = storedProfileID(),
            !stored.isEmpty,
            storedProfileUserID() == connection.userId
        {
            return stored
        }
        let profiles = try await send(
            try makeRequest(path: "/profiles", profileRequired: false),
            as: SiloProfilesResponse.self
        ).items
        guard let selected = profiles.first(where: { $0.isPrimary }) ?? profiles.first else {
            throw ProviderError.serverError("No Silo profile is available for this account")
        }
        guard selected.hasPIN != true else {
            throw ProviderError.serverError("Sign in again to unlock your Silo profile with its PIN.")
        }
        storeProfile(selected)
        return selected.id
    }

    private var refreshTokenKey: String { "silo_refresh_\(connection.id.uuidString)" }
    private var legacyPasswordKey: String { "silo_password_\(connection.id.uuidString)" }
    private var profileTokenKey: String { "silo_profile_token_\(connection.id.uuidString)" }
    private var profileIDKey: String { "silo_profile_id_\(connection.id.uuidString)" }
    private var profileNameKey: String { "silo_profile_name_\(connection.id.uuidString)" }
    private var profileUserIDKey: String { "silo_profile_user_id_\(connection.id.uuidString)" }

    private func storedRefreshToken() -> String? { legacyKeychain.get(refreshTokenKey) }
    private func storeRefreshToken(_ token: String) { legacyKeychain.set(token, key: refreshTokenKey) }
    private func storedProfileID() -> String? { defaults.string(forKey: profileIDKey) }
    private func storedProfileUserID() -> String? { defaults.string(forKey: profileUserIDKey) }
    private func storeProfile(_ profile: SiloProfile) {
        defaults.set(profile.id, forKey: profileIDKey)
        defaults.set(profile.name, forKey: profileNameKey)
        defaults.set(connection.userId, forKey: profileUserIDKey)
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

    private func apiURL(path: String, query: [URLQueryItem] = [], apiVersion: String = "v2") throws -> URL {
        guard var components = URLComponents(string: "\(baseURLString)/api/\(apiVersion)\(path)") else {
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
        includeAuth: Bool = true,
        apiVersion: String = "v2"
    ) throws -> URLRequest {
        guard !isRetired else { throw CancellationError() }
        try Task.checkCancellation()
        var request = URLRequest(url: try apiURL(path: path, query: query, apiVersion: apiVersion))
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
            if let proof = legacyKeychain.get(profileTokenKey) {
                request.setValue(proof, forHTTPHeaderField: "X-Profile-Token")
            }
        }
        return request
    }

    func send<T: Decodable>(_ request: URLRequest, as type: T.Type, retryingAuth: Bool = true) async throws -> T {
        let (data, http) = try await perform(request, retryingAuth: retryingAuth)
        try validate(http, data)
        return try decode(T.self, from: data)
    }

    private func sendEmpty(_ request: URLRequest, retryingAuth: Bool = true) async throws {
        let (data, http) = try await perform(request, retryingAuth: retryingAuth)
        try validate(http, data)
    }

    // A recovered 401 resends the identical request, so sequenced and identity-bearing bodies are never re-minted.
    private func perform(_ request: URLRequest, retryingAuth: Bool = true) async throws -> (Data, HTTPURLResponse) {
        guard !isRetired else { throw CancellationError() }
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard !isRetired else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        if http.statusCode == 401, retryingAuth, await recoverAuthentication() {
            var retried = request
            retried.setValue("Bearer \(connection.token ?? "")", forHTTPHeaderField: "Authorization")
            return try await perform(retried, retryingAuth: false)
        }
        return (data, http)
    }

    private func validate(_ http: HTTPURLResponse, _ data: Data) throws {
        guard !(200...299).contains(http.statusCode) else { return }
        if Self.problemType(data) == "profile_verification_required" {
            throw ProviderError.serverError("Sign in again to unlock your Silo profile with its PIN.")
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw ProviderError.unauthorized }
        if http.statusCode == 400, Self.problemType(data) == "invalid_cursor" { throw SiloCursorError.invalid }
        throw ProviderError.serverError("Silo returned HTTP \(http.statusCode)")
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            AppLogger.network.error("[Silo] Decode failed: \(error.localizedDescription)")
            throw ProviderError.decodingFailed
        }
    }

    private func downloadFile(_ request: URLRequest, retryingAuth: Bool = true) async throws -> URL {
        guard !isRetired else { throw CancellationError() }
        try Task.checkCancellation()
        let (tempURL, response) = try await session.download(for: request)
        guard !isRetired, !Task.isCancelled else {
            try? FileManager.default.removeItem(at: tempURL)
            throw CancellationError()
        }
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ProviderError.invalidResponse
        }
        if http.statusCode == 401, retryingAuth {
            try? FileManager.default.removeItem(at: tempURL)
            guard await recoverAuthentication() else { throw ProviderError.unauthorized }
            var retried = request
            retried.setValue("Bearer \(connection.token ?? "")", forHTTPHeaderField: "Authorization")
            return try await downloadFile(retried, retryingAuth: false)
        }
        guard (200...299).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: tempURL)
            if http.statusCode == 401 || http.statusCode == 403 { throw ProviderError.unauthorized }
            throw ProviderError.serverError("Failed to download ebook")
        }
        return tempURL
    }

    // Every v2 list follows page.next_cursor until has_more is false, whatever each page's length.
    private func traversePages<Page: SiloCursorPaged>(
        _ type: Page.Type,
        request: (String?) throws -> URLRequest,
        handle: (Page) async throws -> Void
    ) async throws {
        var cursor: String?
        var seen = Set<String>()
        repeat {
            let page = try await send(try request(cursor), as: Page.self)
            try await handle(page)
            cursor = try SiloPageInfo.continuation(of: page.page)
            if let cursor, !seen.insert(cursor).inserted {
                throw ProviderError.serverError("Silo pagination repeated a cursor")
            }
        } while cursor != nil
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
        if let authenticationRecovery { return await authenticationRecovery.value }
        let task = Task { () -> Bool in
            if await self.refreshAccessToken() { return true }
            self.connection.token = nil
            return await self.reauthenticateWithStoredCredentials()
        }
        authenticationRecovery = task
        defer { authenticationRecovery = nil }
        return await task.value
    }

    private func fetchCatalogPage(
        libraryId: String,
        cursor: String?,
        sort: String,
        limit: Int,
        fallbackScope: String
    ) async throws -> SiloCatalogResponse {
        try await ensureAuthenticated()
        _ = try await ensureProfile()
        var query = [
            URLQueryItem(name: "library_id", value: libraryId),
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let cursor {
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        let result = try await send(try makeRequest(path: "/catalog", query: query), as: SiloCatalogResponse.self)
        rejectedContent.record(
            providerId: connection.id,
            providerType: connection.type,
            sourceName: connection.name,
            libraryId: libraryId,
            candidates: result.rejectedItems.map { candidate in
                RejectedContentCandidate(
                    itemIdentifier: candidate.itemIdentifier,
                    title: candidate.title,
                    reason: candidate.reason,
                    fallbackIdentifier: "\(fallbackScope)-\(candidate.fallbackIdentifier)"
                )
            }
        )
        return result
    }

    private func fetchPersonalCollections(libraryIds: [String]) async throws -> [Collection] {
        let response = try await send(
            try makeRequest(path: "/collections"),
            as: SiloPersonalCollectionsResponse.self
        )
        let fetched = try await mapConcurrently(response.items) { collection in
            let ids = try await self.fetchPersonalCollectionBookIds(
                collectionId: collection.id,
                libraryIds: libraryIds
            )
            return (collection, ids)
        }
        let memberships = Dictionary(uniqueKeysWithValues: fetched.map { ($0.0.id, $0.1) })
        return response.items
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
            try await traversePages(SiloCatalogItemPage.self) { cursor in
                var query = [
                    URLQueryItem(name: "source", value: "user_collection"),
                    URLQueryItem(name: "collection_id", value: collectionId),
                    URLQueryItem(name: "limit", value: String(self.pageSize)),
                ]
                if let libraryId {
                    query.append(URLQueryItem(name: "library_id", value: libraryId))
                }
                if let cursor {
                    query.append(URLQueryItem(name: "cursor", value: cursor))
                }
                return try self.makeRequest(path: "/catalog", query: query)
            } handle: { page in
                for id in page.readableContentIDs where seen.insert(id).inserted {
                    ids.append(id)
                }
            }
        }
        return ids
    }

    private func fetchServerCollections(libraryIds: [String]) async throws -> [Collection] {
        let collectionLists = try await mapConcurrently(libraryIds) { libraryId in
            let response = try await self.send(
                try self.makeRequest(path: "/library/\(Self.pathSegment(libraryId))/collections"),
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
            (collection, try await self.fetchServerCollectionBookIds(collection))
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

    private func fetchServerCollectionBookIds(_ collection: SiloLibraryCollection) async throws -> [String] {
        let path = "/library/\(Self.pathSegment(collection.libraryID))/collections/\(Self.pathSegment(collection.id))/items"
        var ids: [String] = []
        try await traversePages(SiloCatalogItemPage.self) { cursor in
            var query = [URLQueryItem(name: "limit", value: String(self.pageSize))]
            if let cursor {
                query.append(URLQueryItem(name: "cursor", value: cursor))
            }
            return try self.makeRequest(path: path, query: query)
        } handle: { page in
            ids.append(contentsOf: page.readableContentIDs)
        }
        return ids
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
        let detail = try await send(
            try makeRequest(path: "/catalog/items/\(Self.pathSegment(id))"),
            as: SiloItemDetail.self
        )
        detailCache[id] = detail
        return detail
    }

    private func siloEbookProgress(for contentID: String) async throws -> SiloEbookProgress? {
        let (data, http) = try await perform(
            try makeRequest(path: "/ebooks/\(Self.pathSegment(contentID))/progress")
        )
        if http.statusCode == 404 { return nil }
        try validate(http, data)
        return try decode(SiloEbookProgressEnvelope.self, from: data).progress
    }

    private func mapCatalogItems(
        _ items: [SiloCatalogItem],
        libraryId: String,
        fallbackScope: String
    ) async throws -> (books: [Book], rejectedItems: [RejectedContentCandidate]) {
        var books: [Book] = []
        var acceptedItemIdentifiers = Set<String>()
        var rejectedItems: [RejectedContentCandidate] = []

        for (index, item) in items.enumerated() {
            do {
                if let book = try await book(from: item, libraryId: libraryId) {
                    books.append(book)
                }
                acceptedItemIdentifiers.insert(item.contentID)
            } catch ProviderError.decodingFailed {
                rejectedItems.append(
                    RejectedContentCandidate(
                        itemIdentifier: item.contentID,
                        title: nil,
                        reason: "The source returned malformed item details.",
                        fallbackIdentifier: "item-\(index)"
                    )
                )
            }
        }

        rejectedContent.update(
            connection: connection,
            libraryId: libraryId,
            acceptedItemIdentifiers: acceptedItemIdentifiers,
            rejectedItems: rejectedItems,
            fallbackScope: fallbackScope
        )
        return (books, rejectedItems)
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
            duration = Double(detail.audiobook?.totalDurationSeconds ?? version?.duration ?? detail.runtimeSeconds ?? 0)
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
            partKey: version?.fileID,
            audioFileIno: version?.fileID,
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

    func reportPlayback(_ event: ServerPlaybackEvent, book: Book, sessionId: String, position: TimeInterval) async {
        guard serverSyncEnabled() else { return }
        guard !sessionId.hasPrefix("local-") else { return }
        let parts = multipartSessions[book.id]
        let activeSessionID = replacementSessionIDs[sessionId] ?? sessionId
        let sessionIDs = parts?.map(\.sessionID) ?? [activeSessionID]
        switch event {
        case .started, .resumed, .paused:
            if event == .paused { pausedSessionIDs.formUnion(sessionIDs) } else { pausedSessionIDs.subtract(sessionIDs) }
            if let parts {
                await heartbeatMultipartSession(parts: parts, currentTime: position, isPaused: event == .paused)
            } else {
                try? await sendProgressSample(sessionID: activeSessionID, position: position, isPaused: event == .paused)
            }
        case .stopped:
            // Silo writes watch history when the session stops, from the stop's final sample.
            pausedSessionIDs.subtract(sessionIDs)
            multipartSessions[book.id] = nil
            singleSessionFiles[book.id] = nil
            replacementSessionIDs[sessionId] = nil
            replacementSessionIDs[activeSessionID] = nil
            if let parts {
                for part in parts {
                    await stopPlaybackSession(part.sessionID, finalPosition: nil)
                }
            } else {
                await stopPlaybackSession(activeSessionID, finalPosition: position)
            }
        }
    }

    private func heartbeatMultipartSession(
        parts: [MultipartPartSession],
        currentTime: TimeInterval,
        isPaused: Bool
    ) async {
        guard let active = parts.last(where: { currentTime >= $0.startOffset }) ?? parts.first else {
            return
        }
        let localPosition = min(max(currentTime - active.startOffset, 0), active.duration)
        try? await sendProgressSample(sessionID: active.sessionID, position: localPosition, isPaused: isPaused)
    }

    private func playbackInstallation(refresh: Bool = false) async throws -> String {
        if !refresh, let playbackInstallationID { return playbackInstallationID }
        let capabilities = try await send(
            try makeRequest(path: "/playback/capabilities"),
            as: SiloPlaybackCapabilities.self
        )
        guard capabilities.state == "available", capabilities.allowed != false,
            let installationID = capabilities.installationID, !installationID.isEmpty
        else {
            throw ProviderError.serverError("Silo playback is not available")
        }
        playbackInstallationID = installationID
        return installationID
    }

    // A server restart rotates the installation; the same command is resent once under the new one.
    private func sendPlaybackCommand(
        path: String,
        method: String,
        body: (String) throws -> Data
    ) async throws -> (Data, HTTPURLResponse) {
        var request = try makeRequest(path: path, method: method)
        request.httpBody = try body(try await playbackInstallation())
        let (data, http) = try await perform(request)
        guard http.statusCode == 409, Self.problemType(data) == "installation_changed" else {
            return (data, http)
        }
        let installationID = try await playbackInstallation(refresh: true)
        var retried = try makeRequest(path: path, method: method)
        retried.httpBody = try body(installationID)
        return try await perform(retried)
    }

    private func sendProgressSample(sessionID: String, position: TimeInterval, isPaused: Bool) async throws {
        let sequence = (progressSequences[sessionID] ?? 0) + 1
        progressSequences[sessionID] = sequence
        let (data, http) = try await sendPlaybackCommand(
            path: "/playback/\(Self.pathSegment(sessionID))/progress",
            method: "POST"
        ) { installationID in
            try JSONSerialization.data(withJSONObject: [
                "installation_id": installationID,
                "sequence": sequence,
                "position": max(0, position),
                "is_paused": isPaused,
            ])
        }
        if http.statusCode == 404 || http.statusCode == 410 { throw SiloPlaybackError.sessionNotFound }
        try validate(http, data)
        let mutation = try decode(SiloPlaybackMutation.self, from: data)
        switch mutation.outcome {
        case "applied", "replayed": return
        case "stale_sample":
            if let accepted = mutation.accepted?.sequence,
                accepted > sequence, accepted <= (progressSequences[sessionID] ?? sequence)
            { return }
            throw ProviderError.serverError("Silo kept a newer playback sample")
        default: throw ProviderError.invalidResponse
        }
    }

    // The stop identity and final sample are fixed on first attempt so every retry replays the same stop.
    private func stopPlaybackSession(_ sessionID: String, finalPosition: TimeInterval?) async {
        let stop: PendingStop
        if let pending = pendingStops[sessionID] {
            stop = pending
        } else {
            let sequence = finalPosition.map { _ in (progressSequences[sessionID] ?? 0) + 1 }
            if let sequence { progressSequences[sessionID] = sequence }
            stop = PendingStop(stopID: Self.canonicalUUID(), sequence: sequence, position: finalPosition.map { max(0, $0) })
            pendingStops[sessionID] = stop
        }
        do {
            let (_, http) = try await sendPlaybackCommand(
                path: "/playback/\(Self.pathSegment(sessionID))",
                method: "DELETE"
            ) { installationID in
                var body: [String: Any] = ["installation_id": installationID, "stop_id": stop.stopID]
                if let sequence = stop.sequence, let position = stop.position {
                    body["sequence"] = sequence
                    body["position"] = position
                }
                return try JSONSerialization.data(withJSONObject: body)
            }
            let retryable = http.statusCode >= 500 || [401, 403, 429].contains(http.statusCode)
            if !retryable {
                pendingStops[sessionID] = nil
                progressSequences[sessionID] = nil
            }
        } catch {}
    }

    private func flushPendingStops() async {
        for sessionID in Array(pendingStops.keys) {
            await stopPlaybackSession(sessionID, finalPosition: nil)
        }
    }

    private func readableEbookVersions(for detail: SiloItemDetail) -> [SiloFileVersion] {
        detail.versions.filter { ebookFormat(from: $0) != nil }
    }

    private func preferredEbookVersion(
        for detail: SiloItemDetail,
        savedFileID: String?
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
        guard let url = URL(string: baseURLString + (value.hasPrefix("/") ? value : "/\(value)")) else {
            throw ProviderError.invalidURL
        }
        return authenticatedStreamURL(url)
    }

    private func authenticatedStreamURL(_ url: URL) -> URL {
        guard let serverURL = URL(string: baseURLString),
            url.scheme == serverURL.scheme,
            url.host == serverURL.host,
            url.port == serverURL.port,
            url.path.contains("/stream/"),
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

    private static func milliseconds(_ seconds: TimeInterval) -> Int64 {
        Int64((max(0, seconds) * 1000).rounded())
    }

    // Playback and stop identities must be canonical lowercase UUIDs.
    private static func canonicalUUID() -> String {
        UUID().uuidString.lowercased()
    }

    static func pathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func problemType(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String,
            let url = URL(string: type)
        else { return nil }
        return url.lastPathComponent
    }

    private static func snapshotIdentifier(of page: SiloCatalogPage) -> String {
        let identity = "\(page.totalCount)|" + page.books.map(\.uniqueId).sorted().joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated private static func decodeDate(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if let date = ISO8601Timestamp.parse(raw) {
            return date
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(raw)")
    }

    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased(), !host.isEmpty else {
            return nil
        }
        let defaultPort = scheme == "https" ? 443 : scheme == "http" ? 80 : nil
        let authority = host.contains(":") ? "[\(host)]" : host
        if let port = url.port, port != defaultPort {
            return "\(scheme)://\(authority):\(port)"
        }
        return "\(scheme)://\(authority)"
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URLEncoded(Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension SiloProvider {
    struct OAuthOption: Equatable {
        let displayName: String
        let nativeStartPath: String
    }

    struct NativeOAuthAttempt {
        static let callbackScheme = "org.siloserver.silo"

        let authorizationURL: URL
        let codeVerifier: String
        let state: String
        let serverID: String
        let issuer: String

        func authorizationCode(from callbackURL: URL) throws -> String {
            guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                components.scheme?.lowercased() == Self.callbackScheme,
                components.host?.isEmpty ?? true,
                components.path == "/auth/callback"
            else {
                throw SiloOAuthError.invalidCallback
            }
            let items = components.queryItems ?? []
            func value(_ name: String) -> String? {
                let values = items.filter { $0.name == name }.compactMap(\.value)
                return values.count == 1 ? values[0] : nil
            }

            guard value("state") == state else { throw SiloOAuthError.invalidCallback }
            guard value("server") == serverID else { throw SiloOAuthError.serverMismatch }
            guard let iss = value("iss"),
                let issuerURL = URL(string: iss),
                issuerURL.path.isEmpty || issuerURL.path == "/",
                issuerURL.query == nil, issuerURL.fragment == nil, issuerURL.user == nil,
                SiloProvider.origin(of: issuerURL) == issuer
            else {
                throw SiloOAuthError.issuerMismatch
            }
            guard !items.contains(where: { $0.name == "link" }) else { throw SiloOAuthError.invalidCallback }
            if items.contains(where: { $0.name == "error" }) && value("error") == nil {
                throw SiloOAuthError.invalidCallback
            }
            if items.contains(where: { $0.name == "code" }) && value("code") == nil {
                throw SiloOAuthError.invalidCallback
            }
            if let error = value("error") {
                guard !items.contains(where: { $0.name == "code" }) else { throw SiloOAuthError.invalidCallback }
                throw SiloOAuthError.authorizationFailed(error)
            }
            guard let code = value("code"), !code.isEmpty else { throw SiloOAuthError.invalidCallback }
            return code
        }
    }
}

enum SiloOAuthError: LocalizedError, Equatable {
    case nativeSignInUnavailable
    case noProviders
    case invalidStartPath
    case invalidCallback
    case serverMismatch
    case issuerMismatch
    case authorizationFailed(String)

    var errorDescription: String? {
        switch self {
        case .nativeSignInUnavailable:
            "This Silo server doesn't support single sign-on from apps. Update Silo, or sign in with a password or token."
        case .noProviders:
            "No single sign-on providers are configured on this Silo server."
        case .invalidStartPath:
            "Silo returned an invalid sign-in address."
        case .invalidCallback:
            "Silo returned an unexpected sign-in response. Try again."
        case .serverMismatch:
            "The sign-in response came from a different Silo server."
        case .issuerMismatch:
            "The sign-in response doesn't match this server's address."
        case .authorizationFailed(let reason):
            "Silo sign-in failed (\(reason))."
        }
    }
}

private enum SiloCursorError: Error {
    case invalid
}

private enum SiloPlaybackError: Error {
    case sessionNotFound
}

private struct SiloCatalogPage {
    let books: [Book]
    let totalCount: Int
    let nextCursor: String?
    let isComplete: Bool
}

private final class SiloCatalogTraversal {
    let snapshotIdentifier: String
    let resumed: Bool
    private let totalCount: Int
    private let fetchPage: (String, Int) async throws -> SiloCatalogPage
    private var pendingPage: SiloCatalogPage?
    private var cursor: String?
    private var seenCursors = Set<String>()
    private var pageIndex = 1
    private var loaded = 0
    private var isComplete = true

    init(
        snapshotIdentifier: String,
        resumed: Bool,
        firstPage: SiloCatalogPage,
        totalCount: Int,
        fetchPage: @escaping (String, Int) async throws -> SiloCatalogPage
    ) {
        self.snapshotIdentifier = snapshotIdentifier
        self.resumed = resumed
        self.totalCount = totalCount
        self.fetchPage = fetchPage
        pendingPage = firstPage
    }

    func next() async throws -> LibraryCatalogBatch? {
        let page: SiloCatalogPage
        if let pendingPage {
            page = pendingPage
            self.pendingPage = nil
        } else if let cursor {
            pageIndex += 1
            page = try await fetchPage(cursor, pageIndex)
        } else {
            return nil
        }
        if let next = page.nextCursor, !seenCursors.insert(next).inserted {
            throw ProviderError.serverError("Silo catalog pagination repeated a cursor")
        }
        cursor = page.nextCursor
        loaded += page.books.count
        isComplete = isComplete && page.isComplete
        return LibraryCatalogBatch(
            books: page.books,
            loadedSoFar: loaded,
            totalCount: totalCount,
            resumeToken: isComplete ? (page.nextCursor ?? "") : nil,
            completesSnapshot: page.nextCursor == nil && isComplete
        )
    }
}

private protocol SiloCursorPaged: Decodable {
    var page: SiloPageInfo? { get }
}

private struct SiloPageInfo: Decodable {
    let nextCursor: String?
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }

    static func continuation(of page: SiloPageInfo?) throws -> String? {
        guard let page, page.hasMore else { return nil }
        guard let nextCursor = page.nextCursor, !nextCursor.isEmpty else {
            throw ProviderError.serverError("Silo reported more results without a cursor")
        }
        return nextCursor
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
    let etag: String

    enum CodingKeys: String, CodingKey {
        case id, kind, location, note, style, color, metadata, etag
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
        // Metadata is a shared extension bag; values other clients store as non-strings are ignored.
        metadata =
            (try? container.decode([String: SiloMetadataValue].self, forKey: .metadata))?
            .compactMapValues(\.string) ?? [:]
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        etag = try container.decode(String.self, forKey: .etag)
    }
}

private struct SiloMetadataValue: Decodable {
    let string: String?

    init(from decoder: Decoder) throws {
        string = try? decoder.singleValueContainer().decode(String.self)
    }
}

private struct SiloReaderAnnotationsPage: @MainActor SiloCursorPaged {
    let items: [SiloReaderAnnotationRecord]
    let page: SiloPageInfo?
}

private struct SiloReaderAnnotationRequest: Encodable {
    var id: String?
    let kind: String
    let cfiRange: String?
    let location: String
    let selectedText: String
    let note: String
    let style: String
    let color: String
    let metadata: [String: String]

    enum CodingKeys: String, CodingKey {
        case id, kind, location, note, style, color, metadata
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

private struct SiloOAuthCapabilities: Decodable {
    let native: Bool
}

private struct SiloAuthProvidersResponse: Decodable {
    let items: [SiloAuthProviderItem]
}

private struct SiloAuthProviderItem: Decodable {
    let mode: String
    let displayName: String
    let nativeStartPath: String?

    enum CodingKeys: String, CodingKey {
        case mode
        case displayName = "display_name"
        case nativeStartPath = "native_start_path"
    }
}

private struct SiloServerIdentity: Decodable {
    let serverID: String

    enum CodingKeys: String, CodingKey {
        case serverID = "server_id"
    }
}

private struct SiloUser: Decodable {
    let id: String
    let username: String
}

private struct SiloProfilesResponse: Decodable {
    let items: [SiloProfile]
}

struct SiloProfile: Decodable {
    let id: String
    let name: String
    let isPrimary: Bool
    let hasPIN: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name
        case isPrimary = "is_primary"
        case hasPIN = "has_pin"
    }
}

private struct SiloProfileProof: Decodable {
    let valid: Bool
    let profileToken: String?

    enum CodingKeys: String, CodingKey {
        case valid
        case profileToken = "profile_token"
    }
}

private struct SiloLibrariesResponse: Decodable {
    let items: [SiloLibrary]
}

private struct SiloLibrary: Decodable {
    let id: String
    let name: String
    let type: String
}

nonisolated private struct SiloPersonalCollectionsResponse: Decodable, Sendable {
    let items: [SiloPersonalCollection]
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
    let libraryID: String
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

private struct SiloCatalogItemPage: @MainActor SiloCursorPaged {
    let items: [SiloCatalogItem]
    let page: SiloPageInfo?

    var readableContentIDs: [String] {
        items.compactMap { item in
            let type = item.type.lowercased()
            return type == "audiobook" || type == "ebook" ? item.contentID : nil
        }
    }
}

private struct SiloCatalogResponse: Decodable {
    let total: Int
    let items: [SiloCatalogItem]
    let page: SiloPageInfo?
    let rejectedItems: [RejectedContentCandidate]

    enum CodingKeys: String, CodingKey {
        case total, items, page
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let items = try container.decode(LossyDecodableArray<SiloCatalogItem>.self, forKey: .items)
        self.items = items.values
        rejectedItems = items.rejectedItems
        total = try container.decode(Int.self, forKey: .total)
        page = try container.decodeIfPresent(SiloPageInfo.self, forKey: .page)
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
    let runtimeMinutes: Int?
    let genres: [String]?
    let posterURL: String?
    let seriesTitle: String?
    let userData: SiloProgressState?
    let versions: [SiloFileVersion]
    let playbackVariants: [SiloPlaybackVariant]?
    let audiobook: SiloAudiobookExtension?
    let ebook: SiloEbookExtension?

    var runtimeSeconds: Int? { runtimeMinutes.map { $0 * 60 } }

    enum CodingKeys: String, CodingKey {
        case type, title, year, overview, genres, versions, audiobook, ebook
        case contentID = "content_id"
        case runtimeMinutes = "runtime"
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
    let defaultFileID: String?
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

private struct SiloProgressPage: @MainActor SiloCursorPaged {
    let items: [SiloProgressEntry]
    let page: SiloPageInfo?
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
    let positionMs: Int64
    let durationMs: Int64
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case mediaItemID = "media_item_id"
        case positionMs = "position_ms"
        case durationMs = "duration_ms"
        case updatedAt = "updated_at"
    }
}

private struct SiloProgressSyncResponse: Decodable {
    let items: [SiloProgressSyncResult]
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
    let fileID: String
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

private struct SiloPlaybackCapabilities: Decodable {
    let state: String
    let allowed: Bool?
    let installationID: String?

    enum CodingKeys: String, CodingKey {
        case state, allowed
        case installationID = "installation_id"
    }
}

private struct SiloPlaybackStartResponse: Decodable {
    let protocolVersion: Int
    let outcome: String
    let sessionID: String?
    let playbackPlan: SiloPlaybackPlan?
    let terminal: SiloPlaybackTerminal?

    func audioPlan() throws -> (String, SiloPlaybackPlan) {
        guard protocolVersion == 3 else { throw ProviderError.serverError("Silo returned an unsupported playback protocol") }
        guard outcome == "playable" else {
            throw ProviderError.serverError("Silo cannot play this audio: \(terminal?.reason ?? "no compatible route")")
        }
        guard let sessionID, !sessionID.isEmpty, let playbackPlan else {
            throw ProviderError.serverError("Silo did not return a playback session")
        }
        guard playbackPlan.protocolVersion == 3,
            playbackPlan.delivery == "original_http",
            playbackPlan.stream.protocolName == "http_progressive",
            !playbackPlan.stream.url.isEmpty,
            playbackPlan.timeline.timelineOffsetSeconds == 0
        else {
            throw ProviderError.serverError("Silo returned an unsupported audio playback route")
        }
        return (sessionID, playbackPlan)
    }

    enum CodingKeys: String, CodingKey {
        case outcome, terminal
        case protocolVersion = "protocol_version"
        case sessionID = "session_id"
        case playbackPlan = "playback_plan"
    }
}

private struct SiloPlaybackPlan: Decodable {
    let protocolVersion: Int
    let delivery: String
    let stream: SiloPlaybackStream
    let timeline: SiloPlaybackTimeline
    let source: SiloPlaybackSource

    enum CodingKeys: String, CodingKey {
        case delivery, stream, timeline, source
        case protocolVersion = "protocol_version"
    }
}

private struct SiloPlaybackStream: Decodable {
    let url: String
    let protocolName: String

    enum CodingKeys: String, CodingKey {
        case url
        case protocolName = "protocol"
    }
}

private struct SiloPlaybackTimeline: Decodable {
    let sourceStartSeconds: Double
    let timelineOffsetSeconds: Double

    enum CodingKeys: String, CodingKey {
        case sourceStartSeconds = "source_start_seconds"
        case timelineOffsetSeconds = "timeline_offset_seconds"
    }
}

private struct SiloPlaybackSource: Decodable {
    let durationSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case durationSeconds = "duration_seconds"
    }
}

private struct SiloPlaybackTerminal: Decodable {
    let reason: String
}

private struct SiloEbookProgressEnvelope: Decodable {
    let progress: SiloEbookProgress?
}

private struct SiloEbookProgress: Decodable {
    let fileID: String
    let location: String
    let progress: Double
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case location, progress
        case fileID = "file_id"
        case updatedAt = "updated_at"
    }
}

private struct SiloPlaybackMutation: Decodable {
    struct Sample: Decodable { let sequence: Int64 }
    let outcome: String
    let accepted: Sample?
}
