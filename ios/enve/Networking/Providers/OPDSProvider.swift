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
    private let authentication: OPDSAuthenticationService

    init(
        connection: ServerConnection,
        progressionEndpointStore: OPDSProgressionEndpointStore = .shared,
        authenticationStore: OPDSAuthenticationStore = .shared,
        authentication: OPDSAuthenticationService = .shared
    ) {
        self.connection = connection
        self.progressionEndpointStore = progressionEndpointStore
        self.authenticationStore = authenticationStore
        self.authentication = authentication
    }

    func validateConnection() async throws -> Bool {
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
        if let cached = LocalEbookImporter.shared.cachedEbook(forBookId: book.id) {
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
                    preferredFilename: Self.filename(for: book, format: format),
                    bookIdentifier: book.id
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

        func cache(preferredFilename: String, bookIdentifier: String) throws -> URL {
            switch self {
            case .body(let data):
                try LocalEbookImporter.shared.cacheRemoteEbook(
                    data: data,
                    preferredFilename: preferredFilename,
                    bookIdentifier: bookIdentifier
                )
            case .file(let url):
                try LocalEbookImporter.shared.cacheRemoteEbook(
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
            sensitiveHeaderNames: sensitiveHeaderNames
        )
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
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

        RejectedContentStore.shared.update(
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
            credentialHeaderNames: sensitiveHeaderNames
        )
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
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


// MARK: - Traversal

struct OPDSCatalogContext {
    let providerId: UUID
    let libraryId: String
    /// Keys progression discovery to a configured connection; it does not restrict service hosts.
    var credentialOrigin: URL?

    var isConnected: Bool { credentialOrigin != nil }
}

struct OPDSFeedDocument {
    let url: URL
    let contentType: String
    let data: Data
}

// MARK: - Browsable catalog surface

/// An entry of a feed's `navigation` collection, or an OPDS 1 entry whose only link leads to a sub-feed.
struct OPDSNavigationEntry: Identifiable, Hashable {
    let title: String
    let summary: String?
    let url: URL
    let count: Int?

    var id: String { url.absoluteString }
}

struct OPDSWebCatalog: Identifiable, Hashable {
    let title: String
    let summary: String?
    let url: URL

    var id: String { url.absoluteString }
}

/// One alternative view of the collection being browsed — a language, a sort order, an availability.
struct OPDSFacet: Identifiable, Hashable {
    let title: String
    let url: URL
    let count: Int?
    let isActive: Bool

    var id: String { url.absoluteString }
}

struct OPDSFacetGroup: Identifiable {
    let title: String
    let facets: [OPDSFacet]

    var id: String { title + (facets.first?.id ?? "") }
}

/// A `catalogs` member: another catalog this one points at, which is navigation rather than a publication.
struct OPDSCatalogReference: Identifiable {
    let title: String
    let summary: String?
    let url: URL

    var id: String { url.absoluteString }
}

/// A `groups` member: a preview of a collection, alongside the link to the rest of it.
struct OPDSCatalogGroup: Identifiable {
    let title: String
    let url: URL?
    let navigation: [OPDSNavigationEntry]
    let webCatalogs: [OPDSWebCatalog]
    let publications: [OPDSPublicationEntry]

    var id: String { url?.absoluteString ?? title }
}

/// Pagination continues the current collection; navigation descends into another collection.
struct OPDSPagination: Equatable {
    var first: URL?
    var previous: URL?
    var next: URL?
    var last: URL?
    var currentPage: Int?
    var numberOfItems: Int?
    var itemsPerPage: Int?

    var hasPages: Bool { first != nil || previous != nil || next != nil || last != nil }
}

/// OPDS 2 supplies a URI template; OPDS 1 may require fetching an OpenSearch description.
struct OPDSSearchDescriptor: Equatable {
    enum Kind: Equatable {
        case template(String)
        case openSearchDescription(URL)
    }

    let kind: Kind
    let title: String?

    /// Returns nil for unresolved descriptions or unsafe expanded URLs.
    func url(forTerms terms: String) -> URL? {
        guard case .template(let template) = kind else { return nil }
        return OPDSURITemplate
            .expand(template, values: Self.values(forTerms: terms, in: template))
            .flatMap(URL.init(string:))
            .flatMap { OPDSURL.isRequestable($0) ? $0 : nil }
    }

    /// Accept common search-variable aliases and default pagination variables to the first page.
    static func values(forTerms terms: String, in template: String) -> [String: String] {
        var values: [String: String] = [:]
        for name in OPDSURITemplate.variableNames(in: template) {
            switch name.split(separator: ":").last.map(String.init)?.lowercased() ?? "" {
            case "searchterms", "query", "q", "keywords", "search", "term", "terms", "title":
                values[name] = terms
            case "startindex": values[name] = "1"
            case "startpage", "page": values[name] = "1"
            case "count", "pagesize", "itemsperpage": values[name] = "50"
            case "language": values[name] = Locale.preferredLanguages.first ?? "*"
            case "inputencoding", "outputencoding": values[name] = "UTF-8"
            default: break
            }
        }
        return values
    }
}

/// Includes publications with no supported acquisition so the browser can explain their availability.
struct OPDSPublicationEntry: Identifiable {
    /// Acquisition URLs may contain expiring tokens, so use them as identity only as a last resort.
    let identity: String
    /// Server-declared identifier used to match rejected content.
    let declaredIdentifier: String?
    let title: String
    let authors: [String]
    let narrators: [String]
    let summary: String?
    let seriesInfo: SeriesInfo?
    let languages: [String]
    let publishedYear: Int?
    let duration: TimeInterval?
    let modified: Date?
    let coverURL: URL?
    let thumbnailURL: URL?
    /// The publication's own document, when the feed named one.
    let detailURL: URL?
    /// Every acquisition the entry offers, most permissive first.
    let acquisitions: [OPDSAcquisition]
    let progression: OPDSProgressionEndpoint?
    /// The book Enve imports, and `nil` when nothing here delivers a file it can open.
    let book: Book?
    /// Why nothing here can be opened, for the rejected-content surface and for the row in the browser.
    let unavailableReason: String?

    var id: String { identity }

    var fulfillable: OPDSAcquisition? { acquisitions.first(where: OPDSAcquisitionSelector.isDownloadable) }

    /// An acquisition the reader completes somewhere else: a purchase, a loan, a subscription.
    var transactions: [OPDSAcquisition] {
        acquisitions.filter { $0.kind.isTransaction }
    }

    /// Samples require explicit selection and never replace the full publication during import.
    var sample: OPDSAcquisition? {
        preview.flatMap { OPDSAcquisitionSelector.undeliverableReason(for: $0) == nil ? $0 : nil }
    }

    var unavailableSampleReason: String? {
        preview.flatMap(OPDSAcquisitionSelector.undeliverableReason)
    }

    private var preview: OPDSAcquisition? { acquisitions.first { $0.kind == .preview } }

    var rejection: RejectedContentCandidate? {
        guard let unavailableReason else { return nil }
        return RejectedContentCandidate(
            itemIdentifier: declaredIdentifier,
            title: title,
            reason: unavailableReason,
            fallbackIdentifier: detailURL?.absoluteString ?? title
        )
    }

    var authorText: String? { authors.isEmpty ? nil : authors.joined(separator: ", ") }
}

struct OPDSCatalogPage {
    let url: URL
    var title: String?
    var summary: String?
    var navigation: [OPDSNavigationEntry] = []
    var groups: [OPDSCatalogGroup] = []
    var facetGroups: [OPDSFacetGroup] = []
    var catalogs: [OPDSCatalogReference] = []
    var webCatalogs: [OPDSWebCatalog] = []
    var publications: [OPDSPublicationEntry] = []
    var pagination = OPDSPagination()
    var search: OPDSSearchDescriptor?
    /// An OPDS Authentication Document the feed named, so a reader can sign in before provoking a `401`.
    var authenticationDocumentURL: URL?

    /// Include group members in import; some feeds list publications only inside groups.
    var allPublications: [OPDSPublicationEntry] { publications + groups.flatMap(\.publications) }
}

/// Retains both the browsable structure and the books used for reconciliation.
struct OPDSParsedFeed {
    var page: OPDSCatalogPage
    /// Child collections the import descends into.
    var navigationTargets: [URL] = []
    /// Items the source sent that could not be decoded at all, which is data loss rather than a refusal.
    var undecodable: [RejectedContentCandidate] = []
    /// False only when the page itself lost data. A deliberate, repeatable skip leaves this true.
    var isComplete = true

    init(page: OPDSCatalogPage) {
        self.page = page
    }

    var books: [Book] { page.allPublications.compactMap(\.book) }

    var nextPage: URL? { page.pagination.next }

    /// Entries the source returned that Enve could not turn into a book, for the rejected-content surface.
    var rejected: [RejectedContentCandidate] {
        undecodable + page.allPublications.compactMap(\.rejection)
    }

    /// Progression services the page advertised, keyed by the stable ID of the book that carries them.
    var progressionEndpoints: [String: OPDSProgressionEndpoint] {
        var endpoints: [String: OPDSProgressionEndpoint] = [:]
        for entry in page.allPublications {
            guard let book = entry.book, let progression = entry.progression else { continue }
            endpoints[book.stableId] = progression
        }
        return endpoints
    }
}

struct OPDSCatalogTraversal {
    /// Traversal limits mark snapshots incomplete rather than silently truncating the library.
    struct Limits {
        var navigationDepth = 10
        var navigationLinksPerFeed = 200
        var pagesPerFeed = 2000
        var feedRequests = 5000
    }

    struct Result {
        var books: [Book] = []
        var rejected: [RejectedContentCandidate] = []
        var progressionEndpoints: [String: OPDSProgressionEndpoint] = [:]
        var notices: [String] = []
        /// Reconciliation deletes books it no longer sees, so an incomplete snapshot must never be trusted.
        var isComplete = true
        var root: OPDSCatalogPage?

        mutating func markPartial(_ notice: String) {
            isComplete = false
            if !notices.contains(notice) { notices.append(notice) }
        }
    }

    let context: OPDSCatalogContext
    var limits = Limits()
    let load: @MainActor (URL) async throws -> OPDSFeedDocument

    func collect(from root: URL) async throws -> Result {
        var result = Result()
        var seen: Set<String> = [Self.identity(of: root)]
        var queue: [(url: URL, depth: Int)] = [(root, 0)]
        var requestsRemaining = limits.feedRequests
        var cursor = 0

        while cursor < queue.count {
            let entry = queue[cursor]
            cursor += 1

            var pageURL: URL? = entry.url
            var pagesRead = 0

            while let current = pageURL {
                guard requestsRemaining > 0 else {
                    result.markPartial("Stopped after \(limits.feedRequests) feed requests.")
                    return Self.deduplicatingBooks(in: result)
                }
                let isRootRequest = requestsRemaining == limits.feedRequests
                requestsRemaining -= 1

                let page: OPDSParsedFeed
                do {
                    let document = try await load(current)
                    page = try OPDSFeedParser.parse(document: document, context: context)
                } catch {
                    // Only root failures abort import; deeper failures mark it incomplete to prevent deletions.
                    guard !isRootRequest else { throw error }
                    result.markPartial(
                        pagesRead == 0
                            ? "A sub-feed at navigation depth \(entry.depth) could not be read."
                            : "A continuation page at navigation depth \(entry.depth) could not be read."
                    )
                    break
                }

                if isRootRequest { result.root = page.page }
                result.books.append(contentsOf: page.books)
                result.rejected.append(contentsOf: page.rejected)
                result.progressionEndpoints.merge(page.progressionEndpoints) { existing, _ in existing }
                if !page.isComplete {
                    result.markPartial("A feed page contained entries that could not be decoded.")
                }

                if entry.depth < limits.navigationDepth {
                    if page.navigationTargets.count > limits.navigationLinksPerFeed {
                        result.markPartial(
                            "A feed offered more than \(limits.navigationLinksPerFeed) navigation links; the remainder were not followed."
                        )
                    }
                    for target in page.navigationTargets.prefix(limits.navigationLinksPerFeed) {
                        if seen.insert(Self.identity(of: target)).inserted {
                            queue.append((target, entry.depth + 1))
                        }
                    }
                } else if !page.navigationTargets.isEmpty {
                    result.markPartial("Navigation depth \(limits.navigationDepth) reached; deeper sub-feeds were not visited.")
                }

                pagesRead += 1
                guard let next = page.nextPage else { break }
                guard pagesRead < limits.pagesPerFeed else {
                    result.markPartial("Stopped after \(limits.pagesPerFeed) pages within a single feed.")
                    break
                }
                guard seen.insert(Self.identity(of: next)).inserted else { break }
                pageURL = next
            }
        }

        return Self.deduplicatingBooks(in: result)
    }

    /// Fragments never change what a server returns, so they must not defeat cycle detection.
    static func identity(of url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return (components?.url ?? url).absoluteString
    }

    private static func deduplicatingBooks(in result: Result) -> Result {
        var deduplicated = result
        var seen = Set<String>()
        deduplicated.books = result.books.filter { seen.insert($0.uniqueId).inserted }
        return deduplicated
    }
}

// MARK: - Parsing

enum OPDSFeedParser {
    static func parse(document: OPDSFeedDocument, context: OPDSCatalogContext) throws -> OPDSParsedFeed {
        try requireFeedMediaType(document)
        if isJSONFeed(document) {
            return try parseOPDS2(document: document, context: context)
        }
        return try OPDSAtomParser(document: document, context: context).parse()
    }

    /// Reject non-feed responses before reconciliation can interpret them as an empty catalog.
    private static func requireFeedMediaType(_ document: OPDSFeedDocument) throws {
        let type =
            document.contentType.split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        // A server that declares nothing leaves the decision to the body, which both parsers validate.
        guard !type.isEmpty else { return }

        let structured =
            type == "application/json" || type == "application/xml" || type == "text/xml"
            || type.hasSuffix("+json") || type.hasSuffix("+xml") || type.contains("opds")
        guard structured, type != "application/xhtml+xml" else {
            throw ProviderError.serverError("The server answered with \(type) instead of an OPDS feed.")
        }
    }

    static func isJSONFeed(_ document: OPDSFeedDocument) -> Bool {
        for byte in document.data.prefix(64) {
            switch byte {
            case UInt8(ascii: "{"): return true
            case UInt8(ascii: "<"): return false
            case 0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF: continue
            default: return document.contentType.lowercased().contains("json")
            }
        }
        return document.contentType.lowercased().contains("json")
    }

    /// Navigation entries and group self-links are the only places a child collection may be announced.
    static func isNavigable(_ link: OPDSLink) -> Bool {
        !link.rels.contains { OPDSRel.isStructural($0) || OPDSAcquisitionKind(rel: $0) != nil }
    }

    private static func parseOPDS2(document: OPDSFeedDocument, context: OPDSCatalogContext) throws -> OPDSParsedFeed {
        let feed: OPDS2Feed
        do {
            feed = try JSONDecoder().decode(OPDS2Feed.self, from: document.data)
        } catch {
            throw ProviderError.decodingFailed
        }
        guard feed.isRecognizableDocument else {
            throw ProviderError.serverError("The server answered with JSON that is not an OPDS 2 feed.")
        }

        let base = document.url
        var page = OPDSCatalogPage(url: base)
        page.title = feed.metadata?.title
        page.summary = feed.metadata?.subtitle
        var parsed = OPDSParsedFeed(page: page)
        var targets: [URL] = []

        func entries(_ publications: [OPDS2Publication]) -> [OPDSPublicationEntry] {
            publications.map { entry(for: $0, baseURL: base, context: context) }
        }

        // A publication document contains one book; it must not reconcile as an empty catalog.
        if let single = feed.singlePublication {
            parsed.page.publications = entries([single])
        } else {
            parsed.page.publications = entries(feed.publications)
        }
        parsed.undecodable = feed.undecodableItems
        if !feed.undecodableItems.isEmpty { parsed.isComplete = false }

        parsed.page.navigation = navigationEntries(in: feed.navigation, baseURL: base)
        parsed.page.webCatalogs = webCatalogEntries(in: feed.navigation, baseURL: base)
        for catalog in feed.catalogs {
            if let reference = catalogReference(for: catalog, baseURL: base) {
                parsed.page.catalogs.append(reference)
            } else if let webCatalog = webCatalog(for: catalog, baseURL: base) {
                parsed.page.webCatalogs.append(webCatalog)
            }
        }
        parsed.page.facetGroups = facetGroups(in: feed.facets, baseURL: base)

        var groups: [OPDSCatalogGroup] = []
        for group in feed.groups {
            parsed.undecodable.append(contentsOf: group.undecodableItems)
            if !group.undecodableItems.isEmpty { parsed.isComplete = false }
            groups.append(
                OPDSCatalogGroup(
                    title: group.metadata?.title ?? "",
                    // A group only previews its collection; the self link is where the rest of it lives.
                    url: group.links
                        .first { $0.hasRel("self") && OPDSMediaType.isFeed($0.type) && !$0.templated }?
                        .href
                        .flatMap { OPDSURL.resolve($0, baseURL: base) },
                    navigation: navigationEntries(in: group.navigation, baseURL: base),
                    webCatalogs: webCatalogEntries(in: group.navigation, baseURL: base),
                    publications: entries(group.publications)
                )
            )
        }
        parsed.page.groups = groups

        targets.append(contentsOf: parsed.page.navigation.map(\.url))
        targets.append(contentsOf: parsed.page.catalogs.map(\.url))
        for group in parsed.page.groups {
            targets.append(contentsOf: group.navigation.map(\.url))
            if let url = group.url { targets.append(url) }
        }

        parsed.page.pagination = pagination(
            in: feed.links,
            baseURL: base,
            numberOfItems: feed.metadata?.numberOfItems,
            itemsPerPage: feed.metadata?.itemsPerPage,
            currentPage: feed.metadata?.currentPage
        )
        parsed.page.search = searchDescriptor(in: feed.links, baseURL: base)
        parsed.page.authenticationDocumentURL =
            authenticationDocumentURL(in: feed.links, baseURL: base)
            ?? authenticationDocumentURL(inPublications: parsed.page.allPublications, baseURL: base)

        var uniqueTargets = Set<String>()
        parsed.navigationTargets = targets.filter { uniqueTargets.insert($0.absoluteString).inserted }
        return parsed
    }

    // MARK: Shared link readers

    static func url(ofRel rel: String, in links: [OPDSLink], baseURL: URL) -> URL? {
        links
            .first { $0.hasRel(rel) && !$0.templated }?
            .href
            .flatMap { OPDSURL.resolve($0, baseURL: baseURL) }
    }

    static func pagination(
        in links: [OPDSLink],
        baseURL: URL,
        numberOfItems: Int? = nil,
        itemsPerPage: Int? = nil,
        currentPage: Int? = nil
    ) -> OPDSPagination {
        OPDSPagination(
            first: url(ofRel: "first", in: links, baseURL: baseURL),
            previous: url(ofRel: "previous", in: links, baseURL: baseURL)
                ?? url(ofRel: "prev", in: links, baseURL: baseURL),
            next: url(ofRel: "next", in: links, baseURL: baseURL),
            last: url(ofRel: "last", in: links, baseURL: baseURL),
            currentPage: currentPage,
            numberOfItems: numberOfItems,
            itemsPerPage: itemsPerPage
        )
    }

    /// Templated links contain the query; other search links point to an OpenSearch description.
    static func searchDescriptor(in links: [OPDSLink], baseURL: URL) -> OPDSSearchDescriptor? {
        for link in links where link.hasRel("search") {
            guard let href = link.href else { continue }
            if link.templated || OPDSURITemplate.isTemplated(href) {
                // A template is resolved against the feed before expansion, so a relative one still works.
                guard let absolute = OPDSURL.resolveTemplate(href, baseURL: baseURL) else { continue }
                return OPDSSearchDescriptor(kind: .template(absolute), title: link.title)
            }
            guard let url = OPDSURL.resolve(href, baseURL: baseURL) else { continue }
            return OPDSSearchDescriptor(kind: .openSearchDescription(url), title: link.title)
        }
        return nil
    }

    /// A delegated service's authentication document does not describe the catalog connection.
    static func authenticationDocumentURL(
        inPublications publications: [OPDSPublicationEntry],
        baseURL: URL
    ) -> URL? {
        for entry in publications {
            guard let endpoint = entry.progression,
                let hint = endpoint.authenticateURL,
                OPDSURL.sameOrigin(endpoint.url, as: baseURL)
            else { continue }
            return hint
        }
        return nil
    }

    /// Discover sign-in from a direct link or properties.authenticate without requiring a 401.
    static func authenticationDocumentURL(in links: [OPDSLink], baseURL: URL) -> URL? {
        for link in links {
            if let hinted = link.properties?.authenticate?.href,
                let url = OPDSURL.resolve(hinted, baseURL: baseURL)
            {
                return url
            }
            guard !link.templated,
                link.hasRel("http://opds-spec.org/auth/document")
                    || OPDSAuthenticationDocument.isAuthenticationMediaType(link.type),
                let href = link.href,
                let url = OPDSURL.resolve(href, baseURL: baseURL)
            else { continue }
            return url
        }
        return nil
    }

    private static func navigationEntries(in links: [OPDSLink], baseURL: URL) -> [OPDSNavigationEntry] {
        links.compactMap { link in
            guard !link.templated, let href = link.href, isNavigable(link) else { return nil }
            // Navigation entries often omit the type; anything naming a non-feed type is not a collection.
            guard link.type == nil || OPDSMediaType.isFeed(link.type) else { return nil }
            guard let url = OPDSURL.resolve(href, baseURL: baseURL) else { return nil }
            return OPDSNavigationEntry(
                title: link.title ?? url.lastPathComponent,
                summary: nil,
                url: url,
                count: link.properties?.numberOfItems
            )
        }
    }

    private static func webCatalogEntries(in links: [OPDSLink], baseURL: URL) -> [OPDSWebCatalog] {
        links.compactMap { link in
            guard !link.templated,
                let href = link.href,
                isNavigable(link),
                OPDSMediaType.isWebPage(link.type),
                let url = OPDSURL.resolve(href, baseURL: baseURL)
            else { return nil }
            return OPDSWebCatalog(title: link.title ?? url.host ?? url.absoluteString, summary: nil, url: url)
        }
    }

    private static func catalogReference(for entry: OPDS2CatalogEntry, baseURL: URL) -> OPDSCatalogReference? {
        let link = entry.links.first {
            !$0.templated && !OPDSMediaType.isWebPage($0.type)
                && ($0.hasRel("http://opds-spec.org/catalog") || OPDSMediaType.isFeed($0.type))
        }
        guard let url = link?.href.flatMap({ OPDSURL.resolve($0, baseURL: baseURL) }) else { return nil }
        return OPDSCatalogReference(
            title: entry.metadata?.title ?? link?.title ?? url.lastPathComponent,
            summary: entry.metadata?.subtitle,
            url: url
        )
    }

    private static func webCatalog(for entry: OPDS2CatalogEntry, baseURL: URL) -> OPDSWebCatalog? {
        guard let link = webCatalogEntries(in: entry.links, baseURL: baseURL).first else { return nil }
        return OPDSWebCatalog(
            title: entry.metadata?.title ?? link.title,
            summary: entry.metadata?.subtitle,
            url: link.url
        )
    }

    private static func facetGroups(in facets: [OPDS2FacetGroup], baseURL: URL) -> [OPDSFacetGroup] {
        facets.compactMap { group in
            let entries = group.links.compactMap { link -> OPDSFacet? in
                guard !link.templated,
                    let href = link.href,
                    let url = OPDSURL.resolve(href, baseURL: baseURL)
                else { return nil }
                return OPDSFacet(
                    title: link.title ?? url.lastPathComponent,
                    url: url,
                    count: link.properties?.numberOfItems,
                    isActive: false
                )
            }
            guard !entries.isEmpty else { return nil }
            return OPDSFacetGroup(title: group.metadata?.title ?? "", facets: entries)
        }
    }

    // MARK: Publications

    private static func entry(
        for publication: OPDS2Publication,
        baseURL: URL,
        context: OPDSCatalogContext
    ) -> OPDSPublicationEntry {
        let metadata = publication.metadata
        let detailURL =
            publication.links
            .first { $0.hasRel("self") }?
            .href
            .flatMap { OPDSURL.resolve($0, baseURL: baseURL) }

        let acquisitions = OPDSAcquisitionSelector.candidates(in: publication.links, baseURL: baseURL)
        let selection = OPDSAcquisitionSelector.selection(among: acquisitions)

        var seriesInfo: SeriesInfo?
        if let series = metadata.belongsTo?.series.first {
            seriesInfo = SeriesInfo(name: series.name, sequence: series.position.map(OPDSText.position))
        } else if let collection = metadata.belongsTo?.collection.first {
            seriesInfo = SeriesInfo(name: collection.name, sequence: collection.position.map(OPDSText.position))
        }

        let images = publication.images + publication.links.filter { $0.hasAnyRel(OPDSRel.image) }
        let coverURL = OPDSImageLinks.cover(in: images, baseURL: baseURL)
        let authors = metadata.authors.isEmpty ? metadata.translators : metadata.authors
        let publishedYear = metadata.published.flatMap(OPDSText.year)
        // Acquisition URLs routinely carry an expiring token, so they are the last resort for identity.
        let identity =
            metadata.identifier ?? detailURL?.absoluteString
            ?? acquisitions.first?.url.absoluteString ?? metadata.title

        var book: Book?
        var unavailableReason: String?
        switch selection {
        case .downloadable(let acquisition):
            book = Book(
                id: identity,
                title: metadata.title,
                author: authors.isEmpty ? nil : authors.joined(separator: ", "),
                narrator: metadata.narrators.isEmpty ? nil : metadata.narrators.joined(separator: ", "),
                seriesInfo: seriesInfo,
                duration: metadata.duration,
                coverURL: coverURL,
                partKey: acquisition.url.absoluteString,
                mediaType: acquisition.format.mediaType,
                ebookFormat: acquisition.format.ebookFormat?.rawValue,
                description: metadata.description,
                genres: metadata.subjects.isEmpty ? nil : metadata.subjects,
                chapters: [],
                publisher: metadata.publisher,
                progress: 0,
                currentTime: 0,
                isFinished: false,
                lastUpdate: metadata.modified ?? .distantPast,
                libraryId: context.libraryId,
                providerId: context.providerId,
                source: .opds,
                publishedYear: publishedYear,
                language: metadata.languages.first
            )
        case .rejected(let reason), .notAPublication(let reason):
            unavailableReason = reason
        }

        return OPDSPublicationEntry(
            identity: identity,
            declaredIdentifier: metadata.identifier,
            title: metadata.title,
            authors: authors,
            narrators: metadata.narrators,
            summary: metadata.description,
            seriesInfo: seriesInfo,
            languages: metadata.languages,
            publishedYear: publishedYear,
            duration: metadata.duration,
            modified: metadata.modified,
            coverURL: coverURL,
            thumbnailURL: OPDSImageLinks.thumbnail(in: images, baseURL: baseURL),
            detailURL: detailURL,
            acquisitions: acquisitions,
            progression: context.isConnected
                ? OPDSProgressionTransport.endpoint(in: publication.links, baseURL: baseURL)
                : nil,
            book: book,
            unavailableReason: unavailableReason
        )
    }
}

/// Use thumbnails for browser rows and full-size covers for stored books.
enum OPDSImageLinks {
    static func cover(in links: [OPDSLink], baseURL: URL) -> URL? {
        let usable = candidates(in: links)
        let preferred = usable.first { !$0.hasAnyRel(OPDSRel.thumbnail) } ?? usable.first
        return preferred?.href.flatMap { OPDSURL.resolve($0, baseURL: baseURL) }
    }

    static func thumbnail(in links: [OPDSLink], baseURL: URL) -> URL? {
        let usable = candidates(in: links)
        let preferred =
            usable.first { $0.hasAnyRel(OPDSRel.thumbnail) }
            ?? usable.filter { $0.pixelArea != nil }.min { ($0.pixelArea ?? 0) < ($1.pixelArea ?? 0) }
        return preferred?.href.flatMap { OPDSURL.resolve($0, baseURL: baseURL) }
    }

    private static func candidates(in links: [OPDSLink]) -> [OPDSLink] {
        links.filter { !$0.templated && $0.href != nil && !OPDSMediaType.isFeed($0.type) }
    }
}

/// Extract feed query templates from an OPDS 1 OpenSearch description.
enum OPDSOpenSearchDescription {
    static func searchDescriptor(in data: Data, baseURL: URL, title: String?) -> OPDSSearchDescriptor? {
        let parser = Parser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else { return nil }

        let ranked = parser.templates.sorted { lhs, rhs in
            rank(of: lhs.type) < rank(of: rhs.type)
        }
        for candidate in ranked {
            guard OPDSURITemplate.isTemplated(candidate.template),
                let absolute = OPDSURL.resolveTemplate(candidate.template, baseURL: baseURL)
            else { continue }
            return OPDSSearchDescriptor(kind: .template(absolute), title: parser.shortName ?? title)
        }
        return nil
    }

    private static func rank(of type: String?) -> Int {
        guard let type = type?.lowercased() else { return 3 }
        if type.contains("opds+json") { return 0 }
        if type.contains("atom+xml") { return 1 }
        return 2
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var templates: [(template: String, type: String?)] = []
        var shortName: String?
        private var currentElement = ""
        private var text = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            currentElement = elementName.contains(":")
                ? String(elementName[elementName.index(after: elementName.lastIndex(of: ":")!)...])
                : elementName
            text = ""
            guard currentElement == "Url", let template = attributes["template"] else { return }
            templates.append((template, attributes["type"]))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            guard currentElement == "ShortName", shortName == nil else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { shortName = trimmed }
        }
    }
}

/// Indirect acquisitions return OPDS entry or publication documents pointing to the next hop.
enum OPDSAcquisitionFulfillment {
    static let hopLimit = 2

    static func isCatalogDocument(_ response: HTTPURLResponse) -> Bool {
        guard let declared = response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        else { return false }
        return declared == "application/atom+xml" || declared == "application/opds+json"
            || declared == "application/opds-publication+json"
            || declared == "application/atom+xml;type=entry"
    }

    /// The next URL in the chain, and `nil` when the document names no acquisition Enve can use.
    static func next(
        from data: Data,
        response: HTTPURLResponse,
        requestedURL: URL,
        context: OPDSCatalogContext
    ) -> URL? {
        let document = OPDSFeedDocument(
            url: response.url ?? requestedURL,
            contentType: response.value(forHTTPHeaderField: "Content-Type") ?? "",
            data: data
        )
        guard let parsed = try? OPDSFeedParser.parse(document: document, context: context) else { return nil }
        let candidate = parsed.page.allPublications.compactMap(\.fulfillable).first
        guard let next = candidate?.url, next != requestedURL else { return nil }
        return next
    }
}

// MARK: - Acquisition selection

enum OPDSAcquisitionKind {
    case openAccess
    case direct
    case preview
    case borrow
    case buy
    case subscribe

    /// OPDS 2.0 allows the short form of every acquisition relation alongside the OPDS 1 URI form.
    init?(rel: String) {
        switch rel.lowercased() {
        case "http://opds-spec.org/acquisition/open-access", "open-access":
            self = .openAccess
        case "http://opds-spec.org/acquisition", "acquisition":
            self = .direct
        case "http://opds-spec.org/acquisition/sample", "sample", "preview":
            self = .preview
        case "http://opds-spec.org/acquisition/borrow", "borrow":
            self = .borrow
        case "http://opds-spec.org/acquisition/buy", "buy":
            self = .buy
        case "http://opds-spec.org/acquisition/subscribe", "subscribe":
            self = .subscribe
        default:
            return nil
        }
    }

    /// Only these two hand back the file itself; the rest need a transaction Enve does not perform.
    var deliversTheFile: Bool { self == .openAccess || self == .direct }

    /// An acquisition the reader completes on the catalog's own site.
    var isTransaction: Bool { self == .borrow || self == .buy || self == .subscribe }

    /// Lower is more permissive. Both selection and the rejection message depend on this order.
    var preferenceRank: Int {
        switch self {
        case .openAccess: 0
        case .direct: 1
        case .preview: 2
        case .borrow: 3
        case .buy: 4
        case .subscribe: 5
        }
    }

    var actionName: String {
        switch self {
        case .openAccess, .direct: "Download"
        case .preview: "Download sample"
        case .borrow: "Borrow"
        case .buy: "Buy"
        case .subscribe: "Subscribe"
        }
    }
}

struct OPDSAcquisition {
    let url: URL
    let kind: OPDSAcquisitionKind
    let format: OPDSPublicationFormat
    let properties: OPDSLinkProperties?
    let title: String?

    init(
        url: URL,
        kind: OPDSAcquisitionKind,
        format: OPDSPublicationFormat,
        properties: OPDSLinkProperties? = nil,
        title: String? = nil
    ) {
        self.url = url
        self.kind = kind
        self.format = format
        self.properties = properties
        self.title = title
    }

    var price: OPDSPrice? { properties?.price }
    var availability: OPDSAvailability? { properties?.availability }
    var copies: OPDSCopies? { properties?.copies }
    var holds: OPDSHolds? { properties?.holds }
}

enum OPDSAcquisitionSelection {
    case downloadable(OPDSAcquisition)
    case rejected(reason: String)
    /// No acquisition link at all: in an Atom feed this is how a navigation entry looks.
    case notAPublication(reason: String)
}

enum OPDSAcquisitionSelector {
    static func select(links: [OPDSLink], baseURL: URL) -> OPDSAcquisitionSelection {
        selection(among: candidates(in: links, baseURL: baseURL))
    }

    static func selection(among ordered: [OPDSAcquisition]) -> OPDSAcquisitionSelection {
        guard let best = ordered.first else {
            return .notAPublication(reason: "The entry offers no acquisition link.")
        }
        if let usable = ordered.first(where: isDownloadable) {
            return .downloadable(usable)
        }
        return .rejected(reason: reason(for: best))
    }

    /// Ordered most to least preferred so selection and the rejection message are deterministic.
    static func candidates(in links: [OPDSLink], baseURL: URL) -> [OPDSAcquisition] {
        var ranked: [(rank: (Int, Int, Int), acquisition: OPDSAcquisition)] = []
        for (index, link) in links.enumerated() {
            guard !link.templated,
                let href = link.href,
                let url = OPDSURL.resolve(href, baseURL: baseURL),
                !link.hasAnyRel(OPDSRel.image)
            else { continue }

            let format = OPDSPublicationFormat.resolve(link: link, url: url)
            guard let kind = kind(for: link, format: format) else { continue }
            ranked.append(
                (
                    (kind.preferenceRank, format.preferenceRank, index),
                    OPDSAcquisition(
                        url: url,
                        kind: kind,
                        format: format,
                        properties: link.properties,
                        title: link.title
                    )
                )
            )
        }
        return ranked.sorted { $0.rank < $1.rank }.map(\.acquisition)
    }

    static func isDownloadable(_ acquisition: OPDSAcquisition) -> Bool {
        acquisition.kind.deliversTheFile
            && acquisition.format.isSupported
            && acquisition.properties?.availability?.allowsImmediateAccess != false
    }

    /// Loose audio acquisitions cannot be imported without a library publication to own playback.
    static func undeliverableReason(for acquisition: OPDSAcquisition) -> String? {
        switch acquisition.format {
        case .ebook: nil
        case .audio: "Enve plays an audio publication from the library, not from a catalogue link."
        case .protected(let scheme): "\(scheme) protected content is not supported."
        case .unsupported(let name): "\(name) is not a format Enve can open."
        case .unrecognized: "The acquisition link does not advertise a readable publication format."
        }
    }

    static func reason(for acquisition: OPDSAcquisition) -> String {
        switch acquisition.format {
        case .protected(let scheme):
            return "\(scheme) protected content is not supported."
        case .unsupported(let name):
            return "\(name) is not a format Enve can open."
        case .unrecognized:
            return "The acquisition link does not advertise a readable publication format."
        case .ebook, .audio:
            break
        }

        switch acquisition.kind {
        case .preview:
            return "Only a preview is offered for this publication."
        case .buy:
            return "Only offered for purchase\(priceText(acquisition.properties?.price))."
        case .borrow:
            return "Only offered to borrow\(loanText(acquisition.properties))."
        case .subscribe:
            return "Only offered through a subscription."
        case .openAccess, .direct:
            return "The server reports this publication as \(availabilityText(acquisition.properties))."
        }
    }

    /// A one-line summary of an acquisition's terms, for the row that offers it.
    static func termsText(for acquisition: OPDSAcquisition) -> String? {
        var parts: [String] = []
        if let price = acquisition.price {
            parts.append("\(String(format: "%.2f", price.value)) \(price.currency)")
        }
        parts.append(contentsOf: copiesText(acquisition.properties))
        if let availability = acquisition.availability, !availability.allowsImmediateAccess {
            // The state alone: the loan window follows it, and `availabilityText` would repeat it here.
            var state = availability.state
            if let detail = availability.detail, !detail.isEmpty { state += " — \(detail)" }
            parts.append(state)
        }
        parts.append(contentsOf: loanWindow(acquisition.availability))
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func kind(for link: OPDSLink, format: OPDSPublicationFormat) -> OPDSAcquisitionKind? {
        let declared = link.rels.compactMap(OPDSAcquisitionKind.init(rel:))
        if let mostRestrictive = declared.max(by: { $0.preferenceRank < $1.preferenceRank }) {
            return mostRestrictive
        }
        // Some catalogs omit the acquisition relation and rely on the media type alone.
        guard format.isPublication, !link.rels.contains(where: OPDSRel.isStructural) else { return nil }
        return .direct
    }

    private static func priceText(_ price: OPDSPrice?) -> String {
        guard let price else { return "" }
        return " for \(String(format: "%.2f", price.value)) \(price.currency)"
    }

    private static func copiesText(_ properties: OPDSLinkProperties?) -> [String] {
        var parts: [String] = []
        // Zero is meaningful here: every copy is out, which is not the same as the server omitting the field.
        switch (properties?.copies?.available, properties?.copies?.total) {
        case let (available?, total?): parts.append("\(available) of \(total) copies available")
        case let (available?, nil): parts.append("\(available) copies available")
        case let (nil, total?): parts.append("\(total) copies")
        case (nil, nil): break
        }
        if let total = properties?.holds?.total { parts.append("\(total) holds") }
        if let position = properties?.holds?.position { parts.append("position \(position) in the queue") }
        return parts
    }

    private static func loanText(_ properties: OPDSLinkProperties?) -> String {
        var parts = copiesText(properties)
        parts.append(contentsOf: loanWindow(properties?.availability))
        return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
    }

    private static func availabilityText(_ properties: OPDSLinkProperties?) -> String {
        guard let availability = properties?.availability else { return "unavailable" }
        var text = availability.state
        if let detail = availability.detail, !detail.isEmpty { text += " — \(detail)" }
        let window = loanWindow(availability)
        return window.isEmpty ? text : "\(text) (\(window.joined(separator: ", ")))"
    }

    private static func loanWindow(_ availability: OPDSAvailability?) -> [String] {
        var parts: [String] = []
        if let since = availability?.since, !since.isEmpty { parts.append("since \(since)") }
        if let until = availability?.until, !until.isEmpty { parts.append("until \(until)") }
        return parts
    }
}

// MARK: - Formats

enum OPDSPublicationFormat: Equatable {
    case ebook(EbookFormat)
    case audio
    /// Recognized publication packaging that Enve has no reader for.
    case unsupported(String)
    case protected(String)
    case unrecognized

    static func resolve(link: OPDSLink, url: URL) -> OPDSPublicationFormat {
        var chain: [String] = []
        if let type = link.type { chain.append(type) }
        chain.append(contentsOf: link.indirectAcquisitionTypes)

        if let scheme = chain.compactMap(drmScheme(for:)).first { return .protected(scheme) }
        // The deepest node of an indirect acquisition chain is the file actually delivered.
        if let format = chain.reversed().compactMap(supportedEbookFormat(for:)).first { return .ebook(format) }
        if chain.contains(where: isAudio) { return .audio }
        if let name = chain.compactMap(unsupportedPackaging(for:)).first { return .unsupported(name) }

        guard chain.isEmpty || chain.contains(where: isOpaqueBinary) else { return .unrecognized }
        return resolveFromPath(url)
    }

    static func drmScheme(for mime: String) -> String? {
        switch normalized(mime) {
        case "application/vnd.readium.lcp.license.v1.0+json",
            "application/vnd.readium.lcp.license-1.0+json",
            "application/epub+lcp",
            "application/audiobook+lcp",
            "application/divina+lcp",
            "application/pdf+lcp":
            return "Readium LCP"
        case "application/vnd.adobe.adept+xml", "application/vnd.adobe.drm+xml":
            return "Adobe DRM"
        case "audio/vnd.audible.aax", "audio/vnd.audible.aaxc", "audio/x-pn-audibleaudio":
            return "Audible DRM"
        default:
            return nil
        }
    }

    var isPublication: Bool { self != .unrecognized }

    var isSupported: Bool {
        switch self {
        case .ebook, .audio: true
        case .unsupported, .protected, .unrecognized: false
        }
    }

    var mediaType: AppMediaType {
        switch self {
        case .audio: .audiobook
        case .ebook, .unsupported, .protected, .unrecognized: .ebook
        }
    }

    var ebookFormat: EbookFormat? {
        guard case .ebook(let format) = self else { return nil }
        return format
    }

    /// Preference between several usable acquisitions for the same publication.
    var preferenceRank: Int {
        switch self {
        case .ebook(let format): Self.rank(of: format)
        case .audio: 9
        case .unsupported: 10
        case .protected: 11
        case .unrecognized: 12
        }
    }

    private static func rank(of format: EbookFormat) -> Int {
        switch format {
        case .epub: 0
        case .pdf: 1
        case .cbz: 2
        case .cbr: 3
        case .fb2: 4
        case .azw3: 5
        case .azw: 6
        case .mobi: 7
        case .imagefolder: 8
        }
    }

    /// Directly playable audio formats; DRM-protected Audible aax/aa are rejected.
    private static let audioMIMETypesByExtension: [String: String] = [
        "mp3": "audio/mpeg",
        "m4a": "audio/mp4",
        "m4b": "audio/mp4",
        "aac": "audio/aac",
        "flac": "audio/flac",
        "wav": "audio/wav",
        "ogg": "audio/ogg",
        "oga": "audio/ogg",
        "opus": "audio/opus",
    ]

    static func audioMIMEType(forPathOf url: URL) -> String? {
        audioMIMETypesByExtension[url.pathExtension.lowercased()]
    }

    private static func normalized(_ mime: String) -> String {
        mime.split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    }

    private static func supportedEbookFormat(for mime: String) -> EbookFormat? {
        switch normalized(mime) {
        case "application/epub+zip", "application/epub": .epub
        case "application/pdf": .pdf
        case "application/vnd.comicbook+zip", "application/x-cbz", "application/comicbook+zip": .cbz
        case "application/vnd.comicbook-rar", "application/x-cbr", "application/comicbook-rar",
            "application/vnd.rar", "application/x-rar-compressed":
            .cbr
        case "application/x-mobipocket-ebook": .mobi
        case "application/x-mobi8-ebook", "application/vnd.amazon.ebook": .azw3
        case "application/x-fictionbook+xml", "application/fb2+xml", "text/fb2+xml": .fb2
        default: nil
        }
    }

    private static func isAudio(_ mime: String) -> Bool {
        normalized(mime).hasPrefix("audio/")
    }

    private static func unsupportedPackaging(for mime: String) -> String? {
        switch normalized(mime) {
        case "application/audiobook+zip": "A Readium audiobook package"
        case "application/audiobook+json": "A Readium audiobook manifest"
        case "application/webpub+zip": "A Readium Web Publication package"
        case "application/webpub+json": "A Readium Web Publication manifest"
        case "application/divina+zip": "A DiViNa package"
        case "application/divina+json": "A DiViNa manifest"
        default: nil
        }
    }

    /// Unlike a known book download, a bare archive MIME type does not identify a publication.
    private static func isOpaqueBinary(_ mime: String) -> Bool {
        ["application/octet-stream", "binary/octet-stream", "application/zip", "application/x-zip-compressed"]
            .contains(normalized(mime))
    }

    private static func resolveFromPath(_ url: URL) -> OPDSPublicationFormat {
        let ext = url.pathExtension.lowercased()
        if let format = EbookFormat.from(fileExtension: ext), format != .imagefolder { return .ebook(format) }
        if ext == "aax" || ext == "aa" { return .protected("Audible DRM") }
        if audioMIMETypesByExtension[ext] != nil { return .audio }
        return .unrecognized
    }
}

// MARK: - Shared link model

struct OPDSLink: Decodable {
    let href: String?
    let type: String?
    /// OPDS 2 allows `rel` to be a string or an array of strings; both forms are preserved as written.
    let rels: [String]
    let title: String?
    let templated: Bool
    let properties: OPDSLinkProperties?
    let width: Int?
    let height: Int?
    /// OPDS 1 carries indirect acquisition as child elements rather than as link properties.
    let inlineIndirectTypes: [String]

    init(
        href: String?,
        type: String? = nil,
        rels: [String] = [],
        title: String? = nil,
        templated: Bool = false,
        properties: OPDSLinkProperties? = nil,
        width: Int? = nil,
        height: Int? = nil,
        inlineIndirectTypes: [String] = []
    ) {
        self.href = href
        self.type = type
        self.rels = rels
        self.title = title
        self.templated = templated
        self.properties = properties
        self.width = width
        self.height = height
        self.inlineIndirectTypes = inlineIndirectTypes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        href = try container.decodeIfPresent(String.self, forKey: .href)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        templated = (try? container.decode(Bool.self, forKey: .templated)) ?? false
        properties = try? container.decode(OPDSLinkProperties.self, forKey: .properties)
        width = try? container.decode(Int.self, forKey: .width)
        height = try? container.decode(Int.self, forKey: .height)
        inlineIndirectTypes = []

        if let many = try? container.decode([String].self, forKey: .rel) {
            rels = many
        } else if let single = try? container.decode(String.self, forKey: .rel) {
            rels = [single]
        } else {
            rels = []
        }
    }

    private enum CodingKeys: String, CodingKey {
        case href, type, rel, title, templated, properties, width, height
    }

    /// Only for choosing between images the feed offers, so a link that states no size never wins.
    var pixelArea: Int? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return width * height
    }

    func hasRel(_ value: String) -> Bool {
        rels.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
    }

    func hasAnyRel(_ values: Set<String>) -> Bool {
        rels.contains { values.contains($0.lowercased()) }
    }

    var indirectAcquisitionTypes: [String] {
        (properties?.indirectAcquisition ?? []).flatMap(\.flattenedTypes) + inlineIndirectTypes
    }
}

struct OPDSLinkProperties: Decodable {
    let price: OPDSPrice?
    let indirectAcquisition: [OPDSAcquisitionObject]
    let holds: OPDSHolds?
    let copies: OPDSCopies?
    let availability: OPDSAvailability?
    /// The OPDS Authentication Document a service points at so a client can sign in without a 401 round-trip.
    let authenticate: OPDSAuthenticationHint?
    /// How many publications a navigation entry or facet leads to.
    let numberOfItems: Int?

    init(
        price: OPDSPrice? = nil,
        indirectAcquisition: [OPDSAcquisitionObject] = [],
        holds: OPDSHolds? = nil,
        copies: OPDSCopies? = nil,
        availability: OPDSAvailability? = nil,
        authenticate: OPDSAuthenticationHint? = nil,
        numberOfItems: Int? = nil
    ) {
        self.price = price
        self.indirectAcquisition = indirectAcquisition
        self.holds = holds
        self.copies = copies
        self.availability = availability
        self.authenticate = authenticate
        self.numberOfItems = numberOfItems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        price = try? container.decode(OPDSPrice.self, forKey: .price)
        indirectAcquisition = (try? container.decode([OPDSAcquisitionObject].self, forKey: .indirectAcquisition)) ?? []
        holds = try? container.decode(OPDSHolds.self, forKey: .holds)
        copies = try? container.decode(OPDSCopies.self, forKey: .copies)
        availability = try? container.decode(OPDSAvailability.self, forKey: .availability)
        authenticate = try? container.decode(OPDSAuthenticationHint.self, forKey: .authenticate)
        numberOfItems = try? container.decode(Int.self, forKey: .numberOfItems)
    }

    private enum CodingKeys: String, CodingKey {
        case price, indirectAcquisition, holds, copies, availability, authenticate, numberOfItems
    }
}

struct OPDSAuthenticationHint: Decodable {
    let href: String?
    let type: String?

    init(href: String?, type: String? = nil) {
        self.href = href
        self.type = type
    }
}

struct OPDSAcquisitionObject: Decodable {
    let type: String
    let children: [OPDSAcquisitionObject]

    init(type: String, children: [OPDSAcquisitionObject] = []) {
        self.type = type
        self.children = children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        children = (try? container.decode([OPDSAcquisitionObject].self, forKey: .child)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case type, child }

    /// Depth first, so the last entry of a single chain is the file the reader finally receives.
    var flattenedTypes: [String] { [type] + children.flatMap(\.flattenedTypes) }
}

struct OPDSPrice: Decodable {
    let currency: String
    let value: Double

    init(currency: String, value: Double) {
        self.currency = currency
        self.value = value
    }
}

struct OPDSCopies: Decodable {
    let total: Int?
    let available: Int?

    init(total: Int? = nil, available: Int? = nil) {
        self.total = total
        self.available = available
    }
}

struct OPDSHolds: Decodable {
    let total: Int?
    let position: Int?

    init(total: Int? = nil, position: Int? = nil) {
        self.total = total
        self.position = position
    }
}

struct OPDSAvailability: Decodable {
    let state: String
    let detail: String?
    /// OPDS 1.2 loan window, kept verbatim: the feed's own formatting is what the rejection message shows.
    let since: String?
    let until: String?

    init(state: String, detail: String? = nil, since: String? = nil, until: String? = nil) {
        self.state = state
        self.detail = detail
        self.since = since
        self.until = until
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? "unknown"
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        since = try container.decodeIfPresent(String.self, forKey: .since)
        until = try container.decodeIfPresent(String.self, forKey: .until)
    }

    private enum CodingKeys: String, CodingKey { case state, detail, since, until }

    /// Only an explicit refusal blocks the download; an unfamiliar state must not hide an open publication.
    var allowsImmediateAccess: Bool {
        switch state.lowercased() {
        case "unavailable", "reserved": false
        default: true
        }
    }
}

// MARK: - Relations, media types and URLs

nonisolated enum OPDSRel {
    static let image: Set<String> = [
        "http://opds-spec.org/image",
        "http://opds-spec.org/image/thumbnail",
        "http://opds-spec.org/cover",
        "http://opds-spec.org/thumbnail",
        "x-stanza-cover-image",
        "x-stanza-cover-image-thumbnail",
        "thumbnail",
    ]

    static let thumbnail: Set<String> = [
        "http://opds-spec.org/image/thumbnail",
        "http://opds-spec.org/thumbnail",
        "x-stanza-cover-image-thumbnail",
        "thumbnail",
    ]

    /// Relations that describe this feed or another view of it. Following them duplicates work or loops.
    private static let structural: Set<String> = [
        "self", "alternate", "related", "search", "up", "start", "via", "current",
        "first", "last", "next", "previous", "prev",
        "http://opds-spec.org/facet",
        "http://opds-spec.org/shelf",
        "http://opds-spec.org/subscriptions",
        "http://opds-spec.org/crawlable",
    ]

    static func isStructural(_ rel: String) -> Bool {
        let value = rel.lowercased()
        return structural.contains(value) || value.hasPrefix("http://opds-spec.org/sort")
    }
}

nonisolated enum OPDSMediaType {
    static func isFeed(_ type: String?) -> Bool {
        guard let type = type?.lowercased() else { return false }
        guard !type.contains("opds-publication+json") else { return false }
        return type.contains("application/opds+json") || type.contains("application/atom+xml")
    }

    static func isWebPage(_ type: String?) -> Bool {
        guard let type = type?.lowercased() else { return false }
        return type.contains("text/html") || type.contains("application/xhtml+xml")
    }
}

nonisolated enum OPDSURL {
    private static let allowedSchemes: Set<String> = ["http", "https"]

    static func resolve(_ href: String, baseURL: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let absolute = URL(string: trimmed)
        let resolved =
            absolute?.scheme == nil
            ? URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
            : absolute
        guard let url = resolved, isRequestable(url) else { return nil }
        return url
    }

    /// Resolve the prefix separately because URL rejects URI-template braces.
    static func resolveTemplate(_ template: String, baseURL: URL) -> String? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let split = trimmed.firstIndex(of: "{") ?? trimmed.endIndex
        let prefix = String(trimmed[trimmed.startIndex..<split])
        let suffix = String(trimmed[split...])

        // A template whose first expression opens the query has nothing before it but the feed's own URL.
        guard !prefix.isEmpty else { return baseURL.absoluteString + suffix }
        guard let resolved = resolve(prefix, baseURL: baseURL) else { return nil }
        return resolved.absoluteString + suffix
    }

    static func sameOrigin(_ url: URL, as origin: URL) -> Bool {
        HTTPOrigin(url: origin).matches(url)
    }

    /// All feed URLs must use HTTP(S), have a host, and contain no embedded credentials.
    static func isRequestable(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            allowedSchemes.contains(scheme),
            components.user == nil,
            components.password == nil,
            let host = components.host,
            !host.isEmpty
        else { return false }
        return true
    }
}

nonisolated enum OPDSText {
    static func position(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(value)
    }

    /// The year of an OPDS publication date, which may be a full timestamp, a date, or a bare year.
    static func year(_ value: String) -> Int? {
        guard let first = value.split(separator: "-").first, first.count == 4 else { return nil }
        return Int(first)
    }
}

// MARK: - OPDS 2 wire model

private struct OPDS2Feed: Decodable {
    let metadata: OPDS2FeedMetadata?
    let publications: [OPDS2Publication]
    let navigation: [OPDSLink]
    let groups: [OPDS2Group]
    let links: [OPDSLink]
    let catalogs: [OPDS2CatalogEntry]
    let facets: [OPDS2FacetGroup]
    let undecodableItems: [RejectedContentCandidate]
    /// Single-publication documents must import one book rather than reconcile as an empty feed.
    let singlePublication: OPDS2Publication?
    /// Optional fields also decode arbitrary JSON; require metadata and a collection or link.
    let isRecognizableDocument: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try? container.decode(OPDS2FeedMetadata.self, forKey: .metadata)
        let publications = try container.decodeIfPresent(LossyDecodableArray<OPDS2Publication>.self, forKey: .publications)
        self.publications = publications?.values ?? []
        undecodableItems = publications?.rejectedItems ?? []
        navigation = (try? container.decode([OPDSLink].self, forKey: .navigation)) ?? []
        groups = (try? container.decode([OPDS2Group].self, forKey: .groups)) ?? []
        links = (try? container.decode([OPDSLink].self, forKey: .links)) ?? []
        catalogs = (try? container.decode([OPDS2CatalogEntry].self, forKey: .catalogs)) ?? []
        facets = (try? container.decode([OPDS2FacetGroup].self, forKey: .facets)) ?? []

        let collectionKeys: [CodingKeys] = [.publications, .navigation, .groups, .catalogs, .facets]
        let carriesCollection = collectionKeys.contains { container.contains($0) }
        isRecognizableDocument =
            container.contains(.metadata) && (carriesCollection || container.contains(.links))

        // Metadata and links alone can describe an empty collection; require a publication link.
        let declaresPublication = links.contains { link in
            link.rels.contains { OPDSAcquisitionKind(rel: $0) != nil }
                || (link.hasRel("self") && link.type?.lowercased().contains("opds-publication+json") == true)
        }
        singlePublication =
            !carriesCollection && declaresPublication ? try? OPDS2Publication(from: decoder) : nil
    }

    private enum CodingKeys: String, CodingKey {
        case publications, navigation, groups, links, catalogs, metadata, facets
    }
}

private struct OPDS2FeedMetadata: Decodable {
    let title: String?
    let subtitle: String?
    let modified: Date?
    let numberOfItems: Int?
    let itemsPerPage: Int?
    let currentPage: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try? OPDS2NamedValue.localizedString(in: container, forKey: .title)
        subtitle = try? OPDS2NamedValue.localizedString(in: container, forKey: .subtitle)
        modified = ISO8601Timestamp.parse(try? container.decode(String.self, forKey: .modified))
        numberOfItems = try? container.decode(Int.self, forKey: .numberOfItems)
        itemsPerPage = try? container.decode(Int.self, forKey: .itemsPerPage)
        currentPage = try? container.decode(Int.self, forKey: .currentPage)
    }

    private enum CodingKeys: String, CodingKey {
        case title, subtitle, modified, numberOfItems, itemsPerPage, currentPage
    }
}

private struct OPDS2Group: Decodable {
    let metadata: OPDS2FeedMetadata?
    let publications: [OPDS2Publication]
    let navigation: [OPDSLink]
    let links: [OPDSLink]
    let undecodableItems: [RejectedContentCandidate]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try? container.decode(OPDS2FeedMetadata.self, forKey: .metadata)
        let publications = try container.decodeIfPresent(LossyDecodableArray<OPDS2Publication>.self, forKey: .publications)
        self.publications = publications?.values ?? []
        undecodableItems = publications?.rejectedItems ?? []
        navigation = (try? container.decode([OPDSLink].self, forKey: .navigation)) ?? []
        links = (try? container.decode([OPDSLink].self, forKey: .links)) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case metadata, publications, navigation, links
    }
}

private struct OPDS2FacetGroup: Decodable {
    let metadata: OPDS2FeedMetadata?
    let links: [OPDSLink]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try? container.decode(OPDS2FeedMetadata.self, forKey: .metadata)
        links = (try? container.decode([OPDSLink].self, forKey: .links)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case metadata, links }
}

private struct OPDS2CatalogEntry: Decodable {
    let metadata: OPDS2FeedMetadata?
    let links: [OPDSLink]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try? container.decode(OPDS2FeedMetadata.self, forKey: .metadata)
        links = (try? container.decode([OPDSLink].self, forKey: .links)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case metadata, links }
}

private struct OPDS2Publication: Decodable {
    let metadata: OPDS2Metadata
    let links: [OPDSLink]
    let images: [OPDSLink]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try container.decode(OPDS2Metadata.self, forKey: .metadata)
        links = (try? container.decode([OPDSLink].self, forKey: .links)) ?? []
        images = (try? container.decode([OPDSLink].self, forKey: .images)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case metadata, links, images }
}

private struct OPDS2Metadata: Decodable {
    let identifier: String?
    let title: String
    let authors: [String]
    let translators: [String]
    let narrators: [String]
    let subjects: [String]
    let publisher: String?
    let description: String?
    let belongsTo: OPDS2BelongsTo?
    let languages: [String]
    let published: String?
    let duration: TimeInterval?
    /// Use the catalog modification date so refreshes do not appear newer than reading progress.
    let modified: Date?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
        title = try OPDS2NamedValue.localizedString(in: container, forKey: .title)
        authors = OPDS2NamedValue.names(in: container, forKey: .author)
        translators = OPDS2NamedValue.names(in: container, forKey: .translator)
        narrators = OPDS2NamedValue.names(in: container, forKey: .narrator)
        subjects = OPDS2NamedValue.names(in: container, forKey: .subject)
        publisher = OPDS2NamedValue.names(in: container, forKey: .publisher).first
        description = try container.decodeIfPresent(String.self, forKey: .description)
        belongsTo = try? container.decode(OPDS2BelongsTo.self, forKey: .belongsTo)
        published = try container.decodeIfPresent(String.self, forKey: .published)
        duration = try? container.decode(TimeInterval.self, forKey: .duration)
        modified = ISO8601Timestamp.parse(try? container.decode(String.self, forKey: .modified))

        if let many = try? container.decode([String].self, forKey: .language) {
            languages = many
        } else if let single = try? container.decode(String.self, forKey: .language) {
            languages = [single]
        } else {
            languages = []
        }
    }

    private enum CodingKeys: String, CodingKey {
        case identifier, title, author, translator, narrator, subject, publisher
        case description, belongsTo, language, published, duration, modified
    }
}

private struct OPDS2BelongsTo: Decodable {
    let series: [OPDS2Collection]
    let collection: [OPDS2Collection]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        series = OPDS2Collection.decodeFlexibly(container, forKey: .series)
        collection = OPDS2Collection.decodeFlexibly(container, forKey: .collection)
    }

    private enum CodingKeys: String, CodingKey { case series, collection }
}

private struct OPDS2Collection: Decodable {
    let name: String
    let position: Double?

    init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            name = text
            position = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try OPDS2NamedValue.localizedString(in: container, forKey: .name)
        position = try container.decodeIfPresent(Double.self, forKey: .position)
    }

    private enum CodingKeys: String, CodingKey { case name, position }

    static func decodeFlexibly<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) -> [OPDS2Collection] {
        if let many = try? container.decode([OPDS2Collection].self, forKey: key) { return many }
        if let single = try? container.decode(OPDS2Collection.self, forKey: key) { return [single] }
        return []
    }
}

/// Readium names accept strings, name objects, arrays, or language maps.
private enum OPDS2NamedValue {
    static func names<Key: CodingKey>(
        in container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) -> [String] {
        if let many = try? container.decode([Entry].self, forKey: key) { return many.map(\.name) }
        if let single = try? container.decode(Entry.self, forKey: key) { return [single.name] }
        return []
    }

    static func localizedString<Key: CodingKey>(
        in container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws -> String {
        if let text = try? container.decode(String.self, forKey: key) { return text }
        let translations = try container.decode([String: String].self, forKey: key)
        guard let selected = OPDSLanguagePreference.select(from: translations) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Localized string had no translations"
            )
        }
        return selected
    }

    private struct Entry: Decodable {
        let name: String

        init(from decoder: Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                name = text
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try OPDS2NamedValue.localizedString(in: container, forKey: .name)
        }

        private enum CodingKeys: String, CodingKey { case name }
    }
}

// MARK: - OPDS 1 (Atom)

private final class OPDSAtomParser: NSObject, XMLParserDelegate {
    private struct PendingLink {
        var href: String
        var type: String?
        var rels: [String]
        var title: String?
        var indirectTypes: [String] = []
        var count: Int?
        var isActiveFacet = false
        var facetGroup: String?
        /// OPDS 1.2 carries price, availability, copies and holds as child elements of the link.
        var priceCurrency: String?
        var priceValue: Double?
        var availability: OPDSAvailability?
        var copies: OPDSCopies?
        var holds: OPDSHolds?

        var properties: OPDSLinkProperties? {
            var price: OPDSPrice?
            if let priceCurrency, let priceValue {
                price = OPDSPrice(currency: priceCurrency, value: priceValue)
            }
            guard price != nil || availability != nil || copies != nil || holds != nil || count != nil else {
                return nil
            }
            return OPDSLinkProperties(
                price: price,
                holds: holds,
                copies: copies,
                availability: availability,
                numberOfItems: count
            )
        }
    }

    private struct AtomEntry {
        var id: String?
        var title: String?
        var authors: [String] = []
        var summary: String?
        var links: [OPDSLink] = []
        var seriesName: String?
        var seriesPosition: Double?
        var language: String?
        var publisher: String?
        var issued: String?
        var categories: [String] = []
        var updated: Date?
    }

    private let document: OPDSFeedDocument
    private let context: OPDSCatalogContext

    private var page: OPDSCatalogPage
    private var parsed: OPDSParsedFeed
    private var entry: AtomEntry?
    private var pendingLink: PendingLink?
    private var currentText = ""
    private var insideEntry = false
    private var insideAuthor = false
    private var feedLinks: [OPDSLink] = []
    private var facetLinks: [(group: String, facet: OPDSFacet)] = []
    private var navigationEntries: [OPDSNavigationEntry] = []
    private var rootElement: String?

    init(document: OPDSFeedDocument, context: OPDSCatalogContext) {
        self.document = document
        self.context = context
        page = OPDSCatalogPage(url: document.url)
        parsed = OPDSParsedFeed(page: page)
    }

    /// Malformed or non-OPDS XML must fail before reconciliation can delete books.
    func parse() throws -> OPDSParsedFeed {
        let parser = XMLParser(data: document.data)
        parser.delegate = self
        guard parser.parse() else {
            throw ProviderError.serverError("The server answered with a document that is not well-formed XML.")
        }
        guard let rootElement, rootElement == "feed" || rootElement == "entry" else {
            throw ProviderError.serverError(
                "The XML document is not an OPDS feed; its root element is <\(rootElement ?? "")>."
            )
        }

        page.navigation = navigationEntries
        page.facetGroups = Self.grouped(facetLinks)
        page.pagination = OPDSFeedParser.pagination(in: feedLinks, baseURL: document.url)
        page.search = OPDSFeedParser.searchDescriptor(in: feedLinks, baseURL: document.url)
        page.authenticationDocumentURL =
            OPDSFeedParser.authenticationDocumentURL(in: feedLinks, baseURL: document.url)
            ?? OPDSFeedParser.authenticationDocumentURL(
                inPublications: page.publications,
                baseURL: document.url
            )

        parsed.page = page

        var unique = Set<String>()
        parsed.navigationTargets = navigationEntries
            .map(\.url)
            .filter { unique.insert($0.absoluteString).inserted }
        return parsed
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        let name = localName(elementName)
        currentText = ""

        switch name {
        case "entry":
            insideEntry = true
            entry = AtomEntry()
        case "author" where insideEntry:
            insideAuthor = true
        case "indirectAcquisition":
            if let type = attributes["type"] { pendingLink?.indirectTypes.append(type) }
        case "link":
            guard let href = attributes["href"] else { break }
            pendingLink = PendingLink(
                href: href,
                type: attributes["type"],
                rels: (attributes["rel"] ?? "").split(separator: " ").map(String.init),
                title: attributes["title"],
                count: (attributes["thr:count"] ?? attributes["count"]).flatMap { Int($0) },
                isActiveFacet: (attributes["opds:activeFacet"] ?? attributes["activeFacet"]) == "true",
                facetGroup: attributes["opds:facetGroup"] ?? attributes["facetGroup"]
            )
        case "price":
            pendingLink?.priceCurrency = attributes["currencycode"] ?? attributes["currency"]
        case "availability":
            pendingLink?.availability = OPDSAvailability(
                state: attributes["status"] ?? attributes["state"] ?? "unknown",
                since: attributes["since"],
                until: attributes["until"]
            )
        case "copies":
            // Zero is meaningful: every copy is out, which is not the same as an absent attribute.
            pendingLink?.copies = OPDSCopies(
                total: attributes["total"].flatMap { Int($0) },
                available: attributes["available"].flatMap { Int($0) }
            )
        case "holds":
            pendingLink?.holds = OPDSHolds(
                total: attributes["total"].flatMap { Int($0) },
                position: attributes["position"].flatMap { Int($0) }
            )
        case "category" where insideEntry:
            let label = (attributes["label"] ?? attributes["term"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let label, !label.isEmpty { entry?.categories.append(label) }
        case "Series" where insideEntry && isSchemaNamespace(namespaceURI):
            entry?.seriesName = (attributes["schema:name"] ?? attributes["name"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            entry?.seriesPosition = (attributes["schema:position"] ?? attributes["position"]).flatMap { Double($0) }
        default:
            break
        }

        if rootElement == nil { rootElement = name }
    }

    /// With namespace processing disabled, schema:Series is matched by its raw qualified name.
    private func isSchemaNamespace(_ namespaceURI: String?) -> Bool {
        guard let namespaceURI, !namespaceURI.isEmpty else { return true }
        return namespaceURI.contains("schema.org")
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let name = localName(elementName)
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch name {
        case "price":
            pendingLink?.priceValue = Double(trimmed)

        case "link":
            guard let pending = pendingLink else { break }
            pendingLink = nil
            let link = OPDSLink(
                href: pending.href,
                type: pending.type,
                rels: pending.rels,
                title: pending.title,
                properties: pending.properties,
                inlineIndirectTypes: pending.indirectTypes
            )
            if insideEntry {
                entry?.links.append(link)
            } else {
                feedLinks.append(link)
                collectFacet(pending)
            }

        case "entry":
            if let entry { finish(entry) }
            self.entry = nil
            insideEntry = false

        case "author":
            insideAuthor = false

        case "title" where !insideEntry:
            if page.title == nil, !trimmed.isEmpty { page.title = trimmed }

        case "subtitle" where !insideEntry:
            if page.summary == nil, !trimmed.isEmpty { page.summary = trimmed }

        default:
            guard insideEntry else { break }
            switch name {
            case "id": entry?.id = trimmed
            case "title": entry?.title = trimmed
            case "updated": entry?.updated = ISO8601Timestamp.parse(trimmed)
            case "language": entry?.language = trimmed.isEmpty ? nil : trimmed
            case "publisher": entry?.publisher = trimmed.isEmpty ? nil : trimmed
            case "issued":
                if entry?.issued == nil, !trimmed.isEmpty { entry?.issued = trimmed }
            case "name" where insideAuthor:
                if !trimmed.isEmpty { entry?.authors.append(trimmed) }
            case "summary", "content":
                if entry?.summary == nil { entry?.summary = trimmed }
            default: break
            }
        }
    }

    private func collectFacet(_ pending: PendingLink) {
        guard pending.rels.contains(where: { $0.lowercased() == "http://opds-spec.org/facet" }),
            let url = OPDSURL.resolve(pending.href, baseURL: document.url)
        else { return }
        facetLinks.append(
            (
                pending.facetGroup ?? "Filter",
                OPDSFacet(
                    title: pending.title ?? url.lastPathComponent,
                    url: url,
                    count: pending.count,
                    isActive: pending.isActiveFacet
                )
            )
        )
    }

    private func finish(_ atomEntry: AtomEntry) {
        let acquisitions = OPDSAcquisitionSelector.candidates(in: atomEntry.links, baseURL: document.url)
        let selection = OPDSAcquisitionSelector.selection(among: acquisitions)

        // An entry with no acquisition at all is how OPDS 1 writes a navigation entry.
        if case .notAPublication = selection, let target = navigationTarget(in: atomEntry.links) {
            navigationEntries.append(
                OPDSNavigationEntry(
                    title: atomEntry.title ?? target.lastPathComponent,
                    summary: atomEntry.summary,
                    url: target,
                    count: nil
                )
            )
            return
        }

        page.publications.append(entry(from: atomEntry, acquisitions: acquisitions, selection: selection))
    }

    private func entry(
        from atomEntry: AtomEntry,
        acquisitions: [OPDSAcquisition],
        selection: OPDSAcquisitionSelection
    ) -> OPDSPublicationEntry {
        let seriesInfo: SeriesInfo? = {
            guard let name = atomEntry.seriesName, !name.isEmpty else { return nil }
            return SeriesInfo(name: name, sequence: atomEntry.seriesPosition.map(OPDSText.position))
        }()

        let images = atomEntry.links.filter { $0.hasAnyRel(OPDSRel.image) }
        let coverURL = OPDSImageLinks.cover(in: images, baseURL: document.url)
        let title = atomEntry.title ?? "Unknown"
        let identity = atomEntry.id ?? acquisitions.first?.url.absoluteString ?? title
        let publishedYear = atomEntry.issued.flatMap(OPDSText.year)

        var book: Book?
        var unavailableReason: String?
        switch selection {
        case .downloadable(let acquisition):
            book = Book(
                id: identity,
                title: title,
                author: atomEntry.authors.isEmpty ? nil : atomEntry.authors.joined(separator: ", "),
                narrator: nil,
                seriesInfo: seriesInfo,
                coverURL: coverURL,
                partKey: acquisition.url.absoluteString,
                mediaType: acquisition.format.mediaType,
                ebookFormat: acquisition.format.ebookFormat?.rawValue,
                description: atomEntry.summary,
                genres: atomEntry.categories.isEmpty ? nil : atomEntry.categories,
                chapters: [],
                publisher: atomEntry.publisher,
                progress: 0,
                currentTime: 0,
                isFinished: false,
                lastUpdate: atomEntry.updated ?? .distantPast,
                libraryId: context.libraryId,
                providerId: context.providerId,
                source: .opds,
                publishedYear: publishedYear,
                language: atomEntry.language
            )
        case .rejected(let reason), .notAPublication(let reason):
            unavailableReason = reason
        }

        return OPDSPublicationEntry(
            identity: identity,
            declaredIdentifier: atomEntry.id,
            title: title,
            authors: atomEntry.authors,
            narrators: [],
            summary: atomEntry.summary,
            seriesInfo: seriesInfo,
            languages: atomEntry.language.map { [$0] } ?? [],
            publishedYear: publishedYear,
            duration: nil,
            modified: atomEntry.updated,
            coverURL: coverURL,
            thumbnailURL: OPDSImageLinks.thumbnail(in: images, baseURL: document.url),
            detailURL: OPDSFeedParser.url(ofRel: "self", in: atomEntry.links, baseURL: document.url),
            acquisitions: acquisitions,
            progression: context.isConnected
                ? OPDSProgressionTransport.endpoint(in: atomEntry.links, baseURL: document.url)
                : nil,
            book: book,
            unavailableReason: unavailableReason
        )
    }

    private func navigationTarget(in links: [OPDSLink]) -> URL? {
        for link in links {
            guard let href = link.href,
                OPDSMediaType.isFeed(link.type),
                OPDSFeedParser.isNavigable(link),
                let url = OPDSURL.resolve(href, baseURL: document.url)
            else { continue }
            return url
        }
        return nil
    }

    private static func grouped(_ facets: [(group: String, facet: OPDSFacet)]) -> [OPDSFacetGroup] {
        var order: [String] = []
        var byGroup: [String: [OPDSFacet]] = [:]
        for (group, facet) in facets {
            if byGroup[group] == nil { order.append(group) }
            byGroup[group, default: []].append(facet)
        }
        return order.map { OPDSFacetGroup(title: $0, facets: byGroup[$0] ?? []) }
    }

    private func localName(_ element: String) -> String {
        guard let index = element.lastIndex(of: ":") else { return element }
        return String(element[element.index(after: index)...])
    }
}

// MARK: - Transport

final class OPDSSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let origin: HTTPOrigin
    private let username: String?
    private let password: String?
    private let credentialHeaderNames: Set<String>

    init(origin: URL, username: String?, password: String?, credentialHeaderNames: Set<String>) {
        self.origin = HTTPOrigin(url: origin)
        self.username = username
        self.password = password
        self.credentialHeaderNames = credentialHeaderNames
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod

        if method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest,
            let user = username, !user.isEmpty, let password,
            origin.matches(challenge.protectionSpace)
        {
            completionHandler(
                .useCredential,
                URLCredential(user: user, password: password, persistence: .forSession)
            )
            return
        }

        if method == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust,
            NetworkHostUtils.isLocalNetworkHost(challenge.protectionSpace.host)
        {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        completionHandler(.performDefaultHandling, nil)
    }

    /// Reject unsupported schemes, embedded credentials, and HTTPS downgrades before following redirects.
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url, HTTPRedirectPolicy.isFollowable(url, from: response.url) else {
            completionHandler(nil)
            return
        }
        completionHandler(
            HTTPRedirectPolicy.sanitized(
                request,
                keepingCredentialsFor: origin,
                alsoStripping: credentialHeaderNames
            )
        )
    }
}
