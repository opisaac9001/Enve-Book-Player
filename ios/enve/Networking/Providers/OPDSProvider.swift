import Foundation
import Logging

class OPDSProvider: WholeSnapshotCatalogProvider, EbookDownloadProvider, PlaybackSessionProvider,
    EbookProgressProvider, AudiobookProgressProvider, @unchecked Sendable
{
    static let rootLibraryId = "opds-root"

    var connection: ServerConnection

    /// Progress sync requires a per-publication endpoint; see docs/architecture/opds-progression.md.
    var capabilities: ProviderCapabilities {
        [
            .fullImport, .downloads, .backgroundOperation,
            .audiobookProgressPull, .audiobookProgressPush,
            .ebookProgressPull, .ebookProgressPush,
        ]
    }

    private let progressionEndpointStore: OPDSProgressionEndpointStore
    private let authenticationStore: OPDSAuthenticationStore
    private let certificateTransport: InsecureURLSession
    private let isolatesCredentials: Bool
    private let authentication: OPDSAuthenticationService
    private let ebookImporter: LocalEbookImporter
    private let rejectedContent: RejectedContentStore

    init(
        connection: ServerConnection,
        progressionEndpointStore: OPDSProgressionEndpointStore = .shared,
        authenticationStore: OPDSAuthenticationStore = .shared,
        authentication: OPDSAuthenticationService = .shared,
        profileSession: ProfileSession? = nil
    ) {
        self.connection = connection
        self.progressionEndpointStore = profileSession?.opdsProgressionEndpoints ?? progressionEndpointStore
        self.authenticationStore = profileSession?.opdsAuthentication ?? authenticationStore
        certificateTransport = profileSession?.transport ?? .delegateInstance
        isolatesCredentials = profileSession?.isOwner == false
        self.authentication = profileSession?.opdsLogin ?? authentication
        ebookImporter = profileSession?.ebooks ?? .shared
        rejectedContent = profileSession?.rejectedContent ?? .shared
    }

    func retire() async { await authentication.retire() }

    func validateConnection() async throws -> Bool {
        try EnveProvenance.checkServerAddress(connection.url)
        let url = feedURL()
        AppLogger.network.info("[OPDS] validateConnection at \(url.redacted)")
        let (data, response) = try await send(makeRequest(url: url))
        let status = response.statusCode
        AppLogger.network.info("[OPDS] validateConnection status=\(status)")

        if status == 401 || status == 403 {
            throw ProviderError.unauthorized
        }
        guard status == 200 else {
            let preview =
                String(data: data.prefix(300), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message =
                !preview.isEmpty && !preview.hasPrefix("<")
                ? preview
                : "Server returned HTTP \(status)"
            AppLogger.network.error("[OPDS] validateConnection failed: \(message)")
            throw ProviderError.serverError(message)
        }

        // Validate the body before import: treating a login or error page as an empty catalog would delete books.
        do {
            _ = try OPDSFeedParser.parse(
                document: OPDSFeedDocument(
                    url: response.url ?? url,
                    contentType: response.value(forHTTPHeaderField: "Content-Type") ?? "",
                    data: data
                ),
                context: catalogContext
            )
        } catch {
            let detail: String
            if case .serverError(let message)? = error as? ProviderError {
                detail = message
            } else {
                detail = "The URL responded but is not an OPDS feed."
            }
            AppLogger.network.error("[OPDS] validateConnection: 200 but not an OPDS feed")
            throw ProviderError.serverError("\(detail) Point the URL directly at the OPDS endpoint.")
        }
        return true
    }

    func fetchLibraries() async throws -> [Library] {
        [Library(id: Self.rootLibraryId, name: connection.name, type: "book", providerId: connection.id)]
    }

    func fetchBooks(libraryId: String) async throws -> [Book] {
        try await fetchCatalog().books
    }

    func makeCatalogBatchSource(
        libraryId: String,
        resumeAfter: String?,
        expectedSnapshotIdentifier: String?
    ) async throws -> LibraryCatalogBatchSource {
        let catalog = try await fetchCatalog()
        return LibraryCatalogBatchSource.snapshot(
            books: catalog.books,
            isComplete: catalog.isComplete,
            resumeAfter: resumeAfter,
            expectedSnapshotIdentifier: expectedSnapshotIdentifier
        )
    }

    func fetchRecentBooks(libraryId: String, limit: Int) async throws -> [Book] {
        Array(try await fetchBooks(libraryId: libraryId).prefix(limit))
    }

    func fetchCollections(libraryId: String?) async throws -> [Collection] { [] }
    func fetchSeries(libraryId: String) async throws -> [Series] { [] }
    func fetchUserMediaProgress(libraryId: String) async throws -> [UserMediaProgress] { [] }

    func fetchFullBookDetails(bookId: String, libraryId: String) async throws -> Book {
        guard let book = try await fetchBooks(libraryId: libraryId).first(where: { $0.id == bookId }) else {
            throw ProviderError.serverError("Book not found in catalog")
        }
        return book
    }

    /// Only direct audio files on the feed origin are streamable; cross-origin credentials are withheld.
    func getAudioURL(for book: Book) -> URL? {
        guard book.mediaType == .audiobook,
            let partKey = book.partKey,
            let url = URL(string: partKey),
            OPDSURL.sameOrigin(url, as: feedURL())
        else { return nil }
        return url
    }

    func getStreamingHeaders() -> [String: String] {
        credentialHeaders(for: feedURL())
    }

    /// Callers supply their own Accept header; the feed media type can cause a 406 for audio or images.
    func credentialHeaders(for url: URL) -> [String: String] {
        guard OPDSURL.sameOrigin(url, as: feedURL()) else { return [:] }
        var headers = connection.customHeaders ?? [:]
        if let value = authorizationHeaderValue { headers["Authorization"] = value }
        return headers
    }

    func startPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo {
        guard let url = getAudioURL(for: book) else { throw ProviderError.notImplemented }
        return PlaybackSessionInfo(
            sessionId: "opds-\(book.stableId)",
            audioTracks: [
                AudioTrackInfo(
                    index: 0,
                    startOffset: 0,
                    duration: book.duration ?? 0,
                    contentUrl: url.absoluteString,
                    mimeType: OPDSPublicationFormat.audioMIMEType(forPathOf: url) ?? "audio/mpeg",
                    title: book.title
                )
            ],
            chapters: []
        )
    }

    // MARK: OPDS Progression 1.0 (draft)

    /// Returns nil when the publication has no progression service.
    func progressionEndpoint(for book: Book) -> OPDSProgressionEndpoint? {
        progressionEndpointStore.endpoint(forBookStableId: book.stableId)
    }

    /// Allows sync to skip connections with no progression endpoints before querying their books.
    var hasProgressionEndpoints: Bool {
        progressionEndpointStore.hasEndpoints(forConnectionId: connection.id)
    }

    func fetchProgression(for book: Book) async throws -> OPDSProgressionDocument? {
        guard let endpoint = progressionEndpoint(for: book) else { return nil }
        let (data, response) = try await send(progressionRequest("GET", endpoint: endpoint))
        switch try OPDSProgressionTransport.readFetch(
            status: response.statusCode,
            contentType: response.value(forHTTPHeaderField: "Content-Type"),
            data: data,
            endpoint: endpoint
        ) {
        case .progression(let document):
            retainUnresolvedReferences(of: document, for: book)
            return document
        case .notRecorded:
            retainUnresolvedReferences(of: nil, for: book)
            return nil
        }
    }

    /// The document the service settled on, which the draft requires it to return from a `PUT`.
    @discardableResult
    func submitProgression(_ document: OPDSProgressionDocument, for book: Book) async throws -> OPDSProgressionDocument? {
        guard let endpoint = progressionEndpoint(for: book) else { return nil }
        var request = progressionRequest("PUT", endpoint: endpoint)
        request.setValue(OPDSProgressionTransport.mediaType, forHTTPHeaderField: "Content-Type")
        request.httpBody = try OPDSProgressionTransport.encode(document)
        let (data, response) = try await send(request)
        let settled = try OPDSProgressionTransport.readSubmit(
            status: response.statusCode,
            contentType: response.value(forHTTPHeaderField: "Content-Type"),
            data: data,
            endpoint: endpoint
        )
        retainUnresolvedReferences(of: settled, for: book)
        return settled
    }

    /// Preserve unresolved references from the latest service document when composing a push.
    func progressionDocument(
        for book: Book,
        title: String?,
        point: OPDSProgressionPoint,
        progression: Double
    ) -> OPDSProgressionDocument {
        var merged = point
        merged.additional = progressionEndpointStore.retainedReferences(forBookStableId: book.stableId)
        return OPDSProgressionDocument(
            title: title,
            modified: book.lastUpdate,
            device: OPDSProgressionDeviceIdentity.current,
            progression: progression,
            references: merged.references
        )
    }

    /// Replace retained references with those from the latest fetch or PUT response.
    private func retainUnresolvedReferences(of document: OPDSProgressionDocument?, for book: Book) {
        progressionEndpointStore.retainReferences(
            document?.point.additional ?? [],
            forBookStableId: book.stableId
        )
    }

    func fetchAudiobookProgress(
        for book: Book
    ) async throws -> (positionSeconds: TimeInterval, percentage: Double, trackIndex: Int?, updatedAt: Date?, isFinished: Bool)? {
        guard let state = try await fetchAudiobookProgressState(for: book) else { return nil }
        return (state.positionSeconds, state.percentage, state.trackIndex, state.updatedAt, state.readState.isFinished)
    }

    func fetchAudiobookProgressState(for book: Book) async throws -> ProviderAudiobookProgress? {
        guard let document = try await fetchProgression(for: book) else { return nil }
        guard let seconds = OPDSProgressionMapping.audioSeconds(
            in: document.point,
            progression: document.progression,
            duration: book.duration
        ) else { return nil }
        return ProviderAudiobookProgress(
            positionSeconds: seconds,
            percentage: document.progression,
            trackIndex: nil,
            updatedAt: document.modified,
            readState: Self.readState(for: document)
        )
    }

    func updatePlaybackProgress(
        book: Book,
        sessionId: String?,
        currentTime: TimeInterval,
        isFinished: Bool,
        timeListened: TimeInterval
    ) async throws {
        try await pushPlaybackProgression(for: book, currentTime: currentTime, isFinished: isFinished)
    }

    /// Returns false when duration is unknown and no position was sent; skipped pushes must not be recorded.
    @discardableResult
    func pushPlaybackProgression(
        for book: Book,
        currentTime: TimeInterval,
        isFinished: Bool
    ) async throws -> Bool {
        guard progressionEndpoint(for: book) != nil else { return false }
        let progression =
            isFinished
            ? 1
            : OPDSProgressionMapping.audioProgression(seconds: currentTime, duration: book.duration)
        guard let progression else {
            AppLogger.sync.debug(
                "[OPDS] Skipping progression push for bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)): no duration to express a progression with"
            )
            return false
        }

        // The draft represents completion as progression 1, without a refining reference.
        try await submitProgression(
            progressionDocument(
                for: book,
                title: nil,
                point: isFinished ? OPDSProgressionPoint() : OPDSProgressionPoint(audioSeconds: currentTime),
                progression: progression
            ),
            for: book
        )
        return true
    }

    func downloadEbook(for book: Book, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        if let cached = ebookImporter.cachedEbook(for: book) {
            onProgress?(1)
            return cached
        }
        guard let downloadLink = book.partKey, let downloadURL = URL(string: downloadLink) else {
            throw ProviderError.serverError("No download link available for this book")
        }
        return try await downloadPublication(from: downloadURL, for: book, onProgress: onProgress)
    }

    /// Follow indirect acquisition documents until they deliver a publication or exhaust the hop limit.
    private func downloadPublication(
        from start: URL,
        for book: Book,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        var url = start

        for _ in 0...OPDSAcquisitionFulfillment.hopLimit {
            let (payload, response) = try await fetchAcquisition(at: url, onProgress: onProgress)
            do {
                try Self.requireDownloadSuccess(response)

                if OPDSAcquisitionFulfillment.isCatalogDocument(response) {
                    let next = try nextFulfillmentHop(
                        from: payload.documentBody(),
                        response: response,
                        requestedURL: url
                    )
                    payload.discard()
                    url = next
                    continue
                }

                let format = try resolveDownloadedFormat(
                    prefix: payload.prefix,
                    response: response,
                    requestedURL: url,
                    book: book
                )
                return try payload.cache(
                    ebookImporter: ebookImporter,
                    preferredFilename: Self.filename(for: book, format: format),
                    bookIdentifier: book.ebookStorageID
                )
            } catch {
                payload.discard()
                throw error
            }
        }

        throw ProviderError.serverError(
            "The acquisition link kept answering with another catalog document instead of the publication."
        )
    }

    /// Progress-reporting downloads use temporary files; other responses stay in memory.
    private enum AcquisitionPayload {
        case body(Data)
        case file(URL)

        var prefix: Data {
            switch self {
            case .body(let data): data.prefix(OPDSProvider.payloadPrefixLength)
            case .file(let url): OPDSProvider.filePrefix(at: url)
            }
        }

        func documentBody() -> Data {
            switch self {
            case .body(let data): data
            case .file(let url): (try? Data(contentsOf: url)) ?? Data()
            }
        }

        func cache(ebookImporter: LocalEbookImporter, preferredFilename: String, bookIdentifier: String) throws -> URL {
            switch self {
            case .body(let data):
                try ebookImporter.cacheRemoteEbook(
                    data: data,
                    preferredFilename: preferredFilename,
                    bookIdentifier: bookIdentifier
                )
            case .file(let url):
                try ebookImporter.cacheRemoteEbook(
                    tempURL: url,
                    preferredFilename: preferredFilename,
                    bookIdentifier: bookIdentifier
                )
            }
        }

        func discard() {
            guard case .file(let url) = self else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func fetchAcquisition(
        at url: URL,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> (AcquisitionPayload, HTTPURLResponse) {
        guard let onProgress else {
            let (data, response) = try await send(makeRequest(url: url))
            return (.body(data), response)
        }

        let delegate = URLSessionDownloadProgressDelegate(
            progressHandler: onProgress,
            credential: basicCredential(for: url),
            allowedOrigin: feedURL(),
            sensitiveHeaderNames: sensitiveHeaderNames,
            certificateTransport: certificateTransport
        )
        let session = URLSession(configuration: isolatesCredentials ? .ephemeral : .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (tempURL, response) = try await delegate.awaitResult {
            session.downloadTask(with: makeRequest(url: url))
        }
        return (.file(tempURL), response)
    }

    private func nextFulfillmentHop(
        from data: Data,
        response: HTTPURLResponse,
        requestedURL: URL
    ) throws -> URL {
        guard let next = OPDSAcquisitionFulfillment.next(
            from: data,
            response: response,
            requestedURL: requestedURL,
            context: catalogContext
        ) else {
            throw ProviderError.serverError(
                "The acquisition answered with a catalog entry that offers nothing Enve can open."
            )
        }
        return next
    }

    private static func requireDownloadSuccess(_ response: HTTPURLResponse) throws {
        guard response.statusCode != 401, response.statusCode != 403 else {
            throw ProviderError.unauthorized
        }
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to download the publication (HTTP \(response.statusCode))")
        }
    }

    func fetchEbookProgress(
        for book: Book
    ) async throws -> (progress: Double, locator: String?, updatedAt: Date?, isFinished: Bool)? {
        guard let state = try await fetchEbookProgressState(for: book) else { return nil }
        return (state.progress, state.locator, state.updatedAt, state.readState.isFinished)
    }

    func fetchEbookProgressState(for book: Book) async throws -> ProviderEbookProgress? {
        guard let document = try await fetchProgression(for: book) else { return nil }
        return ProviderEbookProgress(
            progress: document.progression,
            locator: OPDSProgressionMapping.ebookLocator(
                for: book,
                point: document.point,
                progression: document.progression
            ),
            updatedAt: document.modified,
            readState: Self.readState(for: document)
        )
    }

    func updateEbookProgress(for book: Book, progress: Double, epubLocator: String?) async throws {
        guard progressionEndpoint(for: book) != nil else { return }
        try await submitProgression(
            progressionDocument(
                for: book,
                title: OPDSProgressionMapping.chapterTitle(inEbookLocator: epubLocator),
                point: OPDSProgressionMapping.point(forEbookLocator: epubLocator),
                progression: progress
            ),
            for: book
        )
    }

    /// The draft has no read state: only a progression that has run out says a publication is finished.
    private static func readState(for document: OPDSProgressionDocument) -> ProviderReadState {
        document.progression >= Book.finishedProgressThreshold ? .finished : .reading
    }

    func fetchCoverImage(url: URL) async throws -> Data {
        let request = makeRequest(url: url)
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Cover fetch failed HTTP \(response.statusCode)")
        }
        return data
    }

    private func fetchCatalog() async throws -> OPDSCatalogTraversal.Result {
        let traversal = OPDSCatalogTraversal(
            context: OPDSCatalogContext(
                providerId: connection.id,
                libraryId: Self.rootLibraryId,
                credentialOrigin: feedURL()
            ),
            load: { [self] url in try await loadFeedDocument(url: url) }
        )
        let result = try await traversal.collect(from: feedURL())

        for notice in result.notices {
            AppLogger.library.error("[OPDS] Catalog snapshot is partial: \(notice)")
        }

        rejectedContent.update(
            connection: connection,
            libraryId: Self.rootLibraryId,
            acceptedItemIdentifiers: Set(result.books.map(\.id)),
            rejectedItems: result.rejected,
            fallbackScope: "opds"
        )
        progressionEndpointStore.apply(
            result.progressionEndpoints,
            connectionId: connection.id,
            snapshotIsComplete: result.isComplete
        )
        rememberAuthenticationDocument(result.root?.authenticationDocumentURL)
        AppLogger.sync.debug(
            "[OPDS] \(result.progressionEndpoints.count) of \(result.books.count) publications advertise a progression service"
        )
        return result
    }

    // MARK: Browsing

    /// Browsing and import share the feed parser.
    func fetchCatalogPage(at url: URL? = nil) async throws -> OPDSCatalogPage {
        let target = url ?? feedURL()
        guard OPDSURL.isRequestable(target) else { throw ProviderError.invalidURL }
        let page = try OPDSFeedParser.parse(
            document: try await loadFeedDocument(url: target),
            context: catalogContext
        ).page
        rememberAuthenticationDocument(page.authenticationDocumentURL)
        return page
    }

    /// Resolves OpenSearch descriptions; returns nil when no usable query template is available.
    func resolveSearch(_ descriptor: OPDSSearchDescriptor) async -> OPDSSearchDescriptor? {
        switch descriptor.kind {
        case .template:
            return descriptor
        case .openSearchDescription(let url):
            guard let (data, response) = try? await send(makeRequest(url: url)),
                response.statusCode == 200
            else { return nil }
            return OPDSOpenSearchDescription.searchDescriptor(
                in: data,
                baseURL: response.url ?? url,
                title: descriptor.title
            )
        }
    }

    /// Only the feed origin may supply this connection's sign-in document, including for later HTML 401 responses.
    private func rememberAuthenticationDocument(_ url: URL?) {
        guard let url, OPDSURL.sameOrigin(url, as: feedURL()) else { return }
        var session =
            authenticationStore.session(for: connection.id)
            ?? OPDSAuthenticationStore.Session(flowType: "")
        guard session.documentURL != url else { return }
        session.documentURL = url
        authenticationStore.setSession(session, for: connection.id)
    }

    func loadFeedDocument(url: URL) async throws -> OPDSFeedDocument {
        let (data, response) = try await send(makeRequest(url: url))
        if response.statusCode == 401 || response.statusCode == 403 {
            throw ProviderError.unauthorized
        }
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("OPDS feed returned HTTP \(response.statusCode)")
        }
        return OPDSFeedDocument(
            url: response.url ?? url,
            contentType: response.value(forHTTPHeaderField: "Content-Type") ?? "",
            data: data
        )
    }

    func feedURL() -> URL { Self.feedURL(for: connection) }

    /// The sign-in sheet needs the credential origin before a provider exists.
    static func feedURL(for connection: ServerConnection) -> URL {
        var str = connection.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !str.hasPrefix("http") { str = "http://\(str)" }
        return URL(string: str) ?? URL(string: "http://invalid")!
    }

    func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "application/opds+json, application/atom+xml;profile=opds-catalog, application/atom+xml;q=0.9, application/json;q=0.8, */*;q=0.1",
            forHTTPHeaderField: "Accept"
        )
        applyCredentials(to: &request)
        return request
    }

    /// Progression services on other origins receive no connection credentials.
    func progressionRequest(_ method: String, endpoint: OPDSProgressionEndpoint) -> URLRequest {
        var request = OPDSProgressionTransport.request(method, endpoint: endpoint)
        applyCredentials(to: &request)
        return request
    }

    /// A feed can advertise acquisition and cover URLs on any host, so credentials stop at the configured origin.
    private func applyCredentials(to request: inout URLRequest) {
        guard let url = request.url, OPDSURL.sameOrigin(url, as: feedURL()) else { return }

        if let value = authorizationHeaderValue {
            request.setValue(value, forHTTPHeaderField: "Authorization")
        }
        for (name, value) in connection.customHeaders ?? [:] {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    /// Prefer an explicit token, then OAuth, then Basic; media and background requests require a prebuilt header.
    var authorizationHeaderValue: String? {
        if let token = connection.token, !token.isEmpty,
            connection.username == nil || connection.username?.isEmpty == true
        {
            return "Bearer \(token)"
        }
        if let value = authenticationStore.authorizationHeaderValue(for: connection.id) {
            return value
        }
        guard let user = connection.username, !user.isEmpty,
            let password = connection.password, !password.isEmpty,
            let encoded = "\(user):\(password)".data(using: .utf8)?.base64EncodedString()
        else { return nil }
        return "Basic \(encoded)"
    }

    private func basicCredential(for url: URL) -> URLCredential? {
        guard OPDSURL.sameOrigin(url, as: feedURL()),
            let user = connection.username, !user.isEmpty,
            let password = connection.password
        else { return nil }
        return URLCredential(user: user, password: password, persistence: .forSession)
    }

    /// Every header `applyCredentials` can attach, so a cross-origin redirect sheds all of them at once.
    private var sensitiveHeaderNames: Set<String> {
        Set((connection.customHeaders ?? [:]).keys)
            .union(HTTPRedirectPolicy.alwaysSensitiveHeaderNames)
    }

    var catalogContext: OPDSCatalogContext {
        OPDSCatalogContext(
            providerId: connection.id,
            libraryId: Self.rootLibraryId,
            credentialOrigin: feedURL()
        )
    }

    /// A 401 discovers sign-in requirements and permits one bearer-token refresh before reauthentication.
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await sendWithAuth(request)
        guard response.statusCode == 401 else { return (data, response) }

        if let url = request.url, OPDSURL.sameOrigin(url, as: feedURL()),
            await authentication.validToken(for: connection.id, feedURL: feedURL()) != nil,
            let refreshed = authorizationHeaderValue,
            refreshed != request.value(forHTTPHeaderField: "Authorization")
        {
            var retry = request
            retry.setValue(refreshed, forHTTPHeaderField: "Authorization")
            let (retryData, retryResponse) = try await sendWithAuth(retry)
            guard retryResponse.statusCode == 401 else { return (retryData, retryResponse) }
            await recordAuthenticationChallenge(data: retryData, response: retryResponse, requestURL: url)
            return (retryData, retryResponse)
        }

        await recordAuthenticationChallenge(data: data, response: response, requestURL: request.url)
        return (data, response)
    }

    /// Only feed-origin challenges may describe this connection's sign-in; delegated hosts authenticate separately.
    private func recordAuthenticationChallenge(
        data: Data,
        response: HTTPURLResponse,
        requestURL: URL?
    ) async {
        let base = response.url ?? requestURL ?? feedURL()
        guard OPDSURL.sameOrigin(base, as: feedURL()) else { return }

        if OPDSAuthenticationDocument.isAuthenticationMediaType(response.value(forHTTPHeaderField: "Content-Type")),
            let document = OPDSAuthenticationDocument.decode(data, baseURL: base)
        {
            authenticationStore.recordChallenge(document, for: connection.id)
            return
        }

        let named =
            OPDSAuthenticationDocument.documentURL(
                inChallenge: response.value(forHTTPHeaderField: "WWW-Authenticate"),
                baseURL: base
            ) ?? authenticationStore.session(for: connection.id)?.documentURL
        guard let named else { return }
        if let document = await fetchAuthenticationDocument(at: named) {
            authenticationStore.recordChallenge(document, for: connection.id)
        }
    }

    /// Rejects authentication documents outside the feed origin.
    func fetchAuthenticationDocument(at url: URL) async -> OPDSAuthenticationDocument? {
        guard OPDSURL.sameOrigin(url, as: feedURL()) else { return nil }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "\(OPDSAuthenticationDocument.mediaType), \(OPDSAuthenticationDocument.legacyMediaType)",
            forHTTPHeaderField: "Accept"
        )
        applyCredentials(to: &request)
        guard let (data, response) = try? await sendWithAuth(request), response.statusCode == 200 else {
            return nil
        }
        let source = response.url ?? url
        return OPDSAuthenticationDocument.decode(data, baseURL: source)?.resolvingDocumentURL(source)
    }

    private func sendWithAuth(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let delegate = OPDSSessionDelegate(
            origin: feedURL(),
            username: connection.username,
            password: connection.password,
            credentialHeaderNames: sensitiveHeaderNames,
            certificateTransport: certificateTransport
        )
        let session = URLSession(configuration: isolatesCredentials ? .ephemeral : .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        return (data, http)
    }

    /// Validate the downloaded format before importing a login page or DRM licence as a book.
    private func resolveDownloadedFormat(
        prefix: Data,
        response: HTTPURLResponse,
        requestedURL: URL,
        book: Book
    ) throws -> EbookFormat {
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        if let scheme = OPDSPublicationFormat.drmScheme(for: contentType) {
            throw ProviderError.serverError("\(scheme) protected publications cannot be opened in Enve.")
        }
        if contentType.lowercased().contains("text/html") {
            throw ProviderError.serverError(
                "The server returned a web page instead of the publication. The acquisition link may have expired or need a sign-in."
            )
        }

        let pathExtension = (response.url ?? requestedURL).pathExtension
        let detected =
            EbookFormat.detectedExtension(inDownloadResponse: response)
            ?? (pathExtension.isEmpty ? nil : pathExtension)
            ?? book.ebookFormat
        guard let format = detected.flatMap(EbookFormat.from(fileExtension:)), format != .imagefolder else {
            throw ProviderError.serverError(
                HTTPResponseInspector.looksLikeHTML(data: prefix, response: response)
                    ? "The server returned a web page instead of the publication."
                    : "The server did not identify the download as a publication Enve can open."
            )
        }
        guard Self.payload(prefix, matches: format) else {
            throw ProviderError.serverError("The download was not a valid \(format.displayName) file.")
        }
        return format
    }

    fileprivate static let payloadPrefixLength = 64

    static func payload(_ prefix: Data, matches format: EbookFormat) -> Bool {
        let bytes = Array(prefix.prefix(4))
        switch format {
        case .epub, .cbz:
            return bytes.starts(with: [0x50, 0x4B])
        case .pdf:
            return bytes.starts(with: Array("%PDF".utf8))
        case .cbr:
            return bytes.starts(with: Array("Rar!".utf8))
        case .fb2, .mobi, .azw3, .azw, .imagefolder:
            return true
        }
    }

    fileprivate static func filePrefix(at url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: payloadPrefixLength)) ?? Data()
    }

    private static func filename(for book: Book, format: EbookFormat) -> String {
        "\(book.title.replacingOccurrences(of: "/", with: "-")).\(format.rawValue)"
    }
}
