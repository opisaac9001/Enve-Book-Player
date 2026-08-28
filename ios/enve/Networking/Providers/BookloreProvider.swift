import AVFoundation
import Combine
import CryptoKit
import Foundation
import Logging
import os.lock

enum GrimmoryRemoteSort: String, Sendable {
    case addedOn
    case lastReadTime
    case title
}

struct GrimmoryRemotePage: Sendable {
    let books: [Book]
    let totalCount: Int
}

struct GrimmoryCatalogImportBatch {
    let pages: [Int]
    let books: [Book]
    let loadedSoFar: Int
    let totalCount: Int
}

final class GrimmoryCatalogImportSession {
    let libraryId: String
    let totalPages: Int
    let totalElements: Int
    fileprivate var checkpoint: GrimmoryCatalogCheckpoint
    fileprivate var seenIdentities: [String: String] = [:]

    var reconciliation: ReconciliationStart? {
        guard let generation = checkpoint.reconciliationGeneration,
            let existingCount = checkpoint.existingCountBefore
        else { return nil }
        return ReconciliationStart(generation: generation, existingCount: existingCount)
    }

    fileprivate init(libraryId: String, checkpoint: GrimmoryCatalogCheckpoint) {
        self.libraryId = libraryId
        totalPages = checkpoint.totalPages
        totalElements = checkpoint.totalElements
        self.checkpoint = checkpoint
    }
}

struct BookloreTierPreference {
    enum Tier: String {
        // Older builds persisted this tier after probing `/api/v1/app/libraries`.
        case komga
        case legacy
    }

    private let defaults: UserDefaults
    private let tierKey: String
    private let probeKey: String

    init(connectionId: UUID, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tierKey = "BookloreTier-\(connectionId.uuidString)"
        probeKey = "BookloreTierProbeDate-\(connectionId.uuidString)"
    }

    var restored: Tier? {
        defaults.string(forKey: tierKey).flatMap(Tier.init(rawValue:))
    }

    func store(_ tier: Tier) {
        defaults.set(tier.rawValue, forKey: tierKey)
    }

    func clear() {
        defaults.removeObject(forKey: tierKey)
        defaults.removeObject(forKey: probeKey)
    }

    func consumeUpgradeProbe(now: Date = Date(), interval: TimeInterval = 86_400) -> Bool {
        let lastProbe = defaults.object(forKey: probeKey) as? Date ?? .distantPast
        guard now.timeIntervalSince(lastProbe) > interval else { return false }
        defaults.set(now, forKey: probeKey)
        return true
    }
}

class BookloreProvider: LibraryProvider, PlaybackSessionProvider, AudiobookProgressProvider,
    EbookProgressProvider, EngineAwareEbookProgressProvider, EbookDownloadProvider, PersonalRatingProvider, ObservableObject,
    @unchecked Sendable
{
    @Published var connection: ServerConnection

    var capabilities: ProviderCapabilities {
        [
            .fullImport, .pagedImport,
            .recentBooks, .series, .collections,
            .audiobookProgressPull, .audiobookProgressPush,
            .ebookProgressPull, .ebookProgressPush,
            .downloads, .coverAuthHeader, .coverAuthQuery, .backgroundOperation,
        ]
    }

    var supportsPersonalRating: Bool {
        !useLegacyRestAPI && !useKomgaFallback
    }

    private let transport: BookloreTransport
    private lazy var progressClient = BookloreProgressClient(
        makeRequest: { [unowned self] path in
            try self.makeRequest(path: path)
        },
        performAuthorizedRequest: { [unowned self] request in
            try await self.performAuthorizedRequest(request)
        },
        validateResponse: { [unowned self] data, response, endpoint in
            try self.guardJSON(data, response: response, endpoint: endpoint)
        }
    )
    private lazy var readingSessionClient = BookloreReadingSessionClient(
        makeRequest: { [unowned self] path in
            try self.makeRequest(path: path)
        },
        performAuthorizedRequest: { [unowned self] request in
            try await self.performAuthorizedRequest(request)
        }
    )
    private lazy var playbackClient = BooklorePlaybackClient(
        makeRequest: { [unowned self] path in
            try self.makeRequest(path: path)
        },
        performAuthorizedRequest: { [unowned self] request in
            try await self.performAuthorizedRequest(request)
        }
    )
    private let pageSize = 500
    private let remoteBrowsePageSize = 50
    private let pageConcurrency = 8
    private let tierPreference: BookloreTierPreference
    private var useKomgaFallback = false
    private var useLegacyRestAPI = false
    private var useLegacyCatalogFallback = false
    private var refreshToken: String?

    private var refreshTokenKeychainKey: String {
        "booklore_refresh_\(connection.id.uuidString)"
    }

    private func saveRefreshToken(_ token: String?) {
        guard let token, !token.isEmpty else { return }
        refreshToken = token
        KeychainHelper.shared.set(token, key: refreshTokenKeychainKey)
    }

    private func loadRefreshTokenFromKeychain() -> String? {
        KeychainHelper.shared.get(refreshTokenKeychainKey)
    }

    var onTokenUpdated: ((ServerConnection) -> Void)?

    private var unfairLock = os_unfair_lock()
    private var activeLoginTask: Task<Void, Error>?
    private var activeRefreshTask: Task<String?, Error>?
    private var credentialLoginBlockedUntil: Date?
    private var cachedEbookResources: [String: GrimmoryEbookResource] = [:]
    private func lockLoginTask() { os_unfair_lock_lock(&unfairLock) }
    private func unlockLoginTask() { os_unfair_lock_unlock(&unfairLock) }

    private let coverFetchLimiter = ConcurrencyLimiter(maxConcurrent: 2)

    static let missingCoverByteCount = 19071
    static func isMissingCoverPlaceholder(_ data: Data) -> Bool {
        guard data.count == missingCoverByteCount else { return false }
        let digest = Insecure.MD5.hash(data: data).map { String(format: "%02hhx", $0) }.joined()
        return digest == "0951a9fe4dd9ae81c5725c2a79c8bfaa"
    }

    private let coverFailureCache = CoverFailureCache()

    private let coverCircuitBreaker = CoverCircuitBreaker()

    static var pendingCatalogSyncConnectionIds: Set<UUID> {
        GrimmoryCatalogCheckpointStore.pendingConnectionIds()
    }

    func completeCatalogSync(libraryId: String) {
        GrimmoryCatalogCheckpointStore.clear(connectionId: connection.id, libraryId: libraryId)
    }

    var supportsTransactionalCatalogImport: Bool {
        !useLegacyRestAPI && !useLegacyCatalogFallback && !useKomgaFallback
    }

    func openCatalogImport(libraryId: String) async throws -> GrimmoryCatalogImportSession {
        guard supportsTransactionalCatalogImport else {
            throw ProviderError.notImplemented
        }

        let firstPageData = try await fetchAppBooksPageData(libraryId: libraryId, page: 0)
        let firstPage = try JSONDecoder().decode(BooklorePage<BookloreBookSummary>.self, from: firstPageData)
        guard !firstPage.content.isEmpty else { throw ProviderError.invalidResponse }

        let prepared = try GrimmoryCatalogCheckpointStore.prepare(
            connectionId: connection.id,
            libraryId: libraryId,
            serverIdentity: connection.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased(),
            totalPages: firstPage.totalPages,
            totalElements: firstPage.totalElements,
            pageSize: firstPage.size,
            firstPageFingerprint: catalogFingerprint(for: firstPage),
            firstPageData: firstPageData
        )
        if prepared.resumed {
            AppLogger.network.info(
                "[Booklore] Resuming committed catalog import for library \(libraryId): \(prepared.checkpoint.committedPages?.count ?? 0)/\(firstPage.totalPages) pages"
            )
        }
        return GrimmoryCatalogImportSession(libraryId: libraryId, checkpoint: prepared.checkpoint)
    }

    func bindCatalogImport(
        _ session: GrimmoryCatalogImportSession,
        to reconciliation: ReconciliationStart
    ) throws {
        try GrimmoryCatalogCheckpointStore.bindReconciliation(reconciliation, checkpoint: &session.checkpoint)
    }

    func nextCatalogImportBatch(_ session: GrimmoryCatalogImportSession) async throws -> GrimmoryCatalogImportBatch? {
        let committedPages = session.checkpoint.committedPages ?? []
        let pendingPages = (0..<session.totalPages).filter { !committedPages.contains($0) }
        guard !pendingPages.isEmpty else { return nil }
        let requestedPages = Array(pendingPages.prefix(pageConcurrency))

        var dataByPage: [Int: Data] = [:]
        var pagesToFetch: [Int] = []
        for page in requestedPages {
            if session.checkpoint.completedPages.contains(page),
                let data = try? GrimmoryCatalogCheckpointStore.pageData(
                    connectionId: connection.id,
                    libraryId: session.libraryId,
                    page: page
                )
            {
                dataByPage[page] = data
            } else {
                pagesToFetch.append(page)
            }
        }

        if !pagesToFetch.isEmpty {
            let fetched = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for page in pagesToFetch {
                    group.addTask {
                        (page, try await self.fetchAppBooksPageData(libraryId: session.libraryId, page: page))
                    }
                }
                var result: [(Int, Data)] = []
                for try await page in group { result.append(page) }
                return result
            }
            for (page, data) in fetched {
                try GrimmoryCatalogCheckpointStore.recordPage(data, page: page, checkpoint: &session.checkpoint)
                dataByPage[page] = data
            }
        }

        var books: [Book] = []
        let context = catalogMapperContext(libraryId: session.libraryId)
        for pageNumber in requestedPages {
            guard let data = dataByPage[pageNumber] else { throw ProviderError.invalidResponse }
            let page = try JSONDecoder().decode(BooklorePage<BookloreBookSummary>.self, from: data)
            guard page.page == pageNumber,
                page.totalPages == session.totalPages,
                page.totalElements == session.totalElements
            else { throw ProviderError.invalidResponse }
            books.append(contentsOf: page.content.map { BookloreCatalogMapper.book(from: $0, context: context) })
        }

        let companions = makeCompanionAudiobooks(forEbooks: &books)
        books.append(contentsOf: companions)
        books = try validateCatalogIdentities(books, session: session)

        let loadedSoFar = (session.checkpoint.committedBookCount ?? 0) + books.count
        return GrimmoryCatalogImportBatch(
            pages: requestedPages,
            books: books,
            loadedSoFar: loadedSoFar,
            totalCount: max(session.totalElements, loadedSoFar)
        )
    }

    func markCatalogImportBatchCommitted(
        _ batch: GrimmoryCatalogImportBatch,
        session: GrimmoryCatalogImportSession
    ) throws {
        try GrimmoryCatalogCheckpointStore.markCommitted(
            pages: batch.pages,
            bookCount: batch.books.count,
            checkpoint: &session.checkpoint
        )
    }

    private func validateCatalogIdentities(
        _ books: [Book],
        session: GrimmoryCatalogImportSession
    ) throws -> [Book] {
        var result: [Book] = []
        result.reserveCapacity(books.count)
        for book in books {
            guard book.providerId == connection.id else { throw ProviderError.invalidResponse }
            let normalizedTitle = book.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normalizedAuthor = (book.author ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let signature = "\(book.mediaType.rawValue)|\(normalizedTitle)|\(normalizedAuthor)"
            if let prior = session.seenIdentities[book.uniqueId] {
                guard prior == signature else {
                    throw ProviderError.serverError("Grimmory returned conflicting books for identity \(book.uniqueId)")
                }
                continue
            }
            session.seenIdentities[book.uniqueId] = signature
            result.append(book)
        }
        return result
    }

    init(connection: ServerConnection = ServerConnection(name: "Grimmory", url: "", type: .booklore)) {
        self.connection = connection

        let tierPreference = BookloreTierPreference(connectionId: connection.id)
        self.tierPreference = tierPreference
        let restoredTier = tierPreference.restored
        switch restoredTier {
        case .komga:
            useKomgaFallback = true
            AppLogger.network.info("Restored cached tier: Komga")
        case .legacy:
            useLegacyRestAPI = true
            AppLogger.network.info("Restored cached tier: Legacy REST")
        case nil:
            break
        }

        if let customHeaders = connection.customHeaders, !customHeaders.isEmpty {
            let keys = customHeaders.keys.sorted().joined(separator: ", ")
            AppLogger.network.info("Session custom headers: \(keys)")
        }
        transport = BookloreTransport(connection: connection)
        transport.setCustomHeadersProvider { [weak self] in self?.connection.customHeaders }

        self.refreshToken = loadRefreshTokenFromKeychain()
        if refreshToken != nil {
            AppLogger.network.info("Restored refresh token from Keychain")
        }

        if restoredTier != nil, tierPreference.consumeUpgradeProbe() {
            Task { [weak self] in await self?.attemptTierUpgrade() }
        }
    }

    private func addAuthHeaders(_ request: inout URLRequest) {
        transport.addAuthHeaders(to: &request, connection: connection)
    }

    func makeRequest(
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil,
        includeAuth: Bool = true
    ) throws -> URLRequest {
        try transport.makeRequest(
            connection: connection,
            path: path,
            method: method,
            queryItems: queryItems,
            body: body,
            contentType: contentType,
            includeAuth: includeAuth
        )
    }

    private func send(_ request: URLRequest, allowCloudflareRefresh: Bool = true) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await transport.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }

        adoptCookiesIfPresent(from: httpResponse)

        if let location = CloudflareAccessHeaders.accessRedirectLocation(in: httpResponse) {
            if allowCloudflareRefresh, await refreshCloudflareCookieIfPossible() {
                var retry = request
                if let cookie = connection.customHeaders?[CloudflareAccessHeaders.cookieHeader] {
                    retry.setValue(cookie, forHTTPHeaderField: CloudflareAccessHeaders.cookieHeader)
                }
                return try await send(retry, allowCloudflareRefresh: false)
            }
            let endpoint = request.url?.path ?? "request"
            throw ProviderError.serverError(
                CloudflareAccessHeaders.accessRejectionMessage(location: location, endpoint: endpoint)
            )
        }

        return (data, httpResponse)
    }

    private var usesBrowserCloudflareCookie: Bool {
        connection.customHeaders?["Cookie"]?.contains("CF_Authorization=") == true
    }

    private func refreshCloudflareCookieIfPossible() async -> Bool {
        #if os(tvOS)
        return false
        #else
        guard usesBrowserCloudflareCookie,
            let serverURL = URL(string: normalize(connection.url))
        else { return false }
        guard let newCookieHeader = await CloudflareSilentRefreshService.shared.refreshedCookieHeader(for: serverURL),
            connection.customHeaders?["Cookie"] != newCookieHeader
        else {
            return false
        }
        var headers = connection.customHeaders ?? [:]
        headers["Cookie"] = newCookieHeader
        connection.customHeaders = headers
        notifyTokenUpdated()
        AppLogger.network.info("[Booklore] Refreshed Cloudflare Access cookie silently")
        return true
        #endif
    }

    func ensureCloudflareSessionValid() async throws {
        guard usesBrowserCloudflareCookie else { return }
        _ = try await validateConnection()
    }

    private func adoptCookiesIfPresent(from response: HTTPURLResponse) {
        let cookieHeaderName = CloudflareAccessHeaders.cookieHeader
        guard let cookieHeader = HTTPResponseInspector.mergedCookieHeader(
            existing: connection.customHeaders?[cookieHeaderName],
            response: response
        ),
            connection.customHeaders?[cookieHeaderName] != cookieHeader
        else { return }

        var updatedHeaders = connection.customHeaders ?? [:]
        updatedHeaders[cookieHeaderName] = cookieHeader
        connection.customHeaders = updatedHeaders
        notifyTokenUpdated()
        AppLogger.network.info("Updated Booklore Cookie header from server response")
    }

    func performAuthorizedRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let token = connection.token,
            let jwt = BookloreJWT(token),
            jwt.isExpiring(buffer: 60),
            shouldAttemptTokenRefresh()
        {
            do {
                if let refreshed = try await refreshCoalesced() {
                    connection.token = refreshed
                    notifyTokenUpdated()
                    AppLogger.network.info("Proactive token refresh before request")
                }
            } catch let ProviderError.rateLimited(message) {
                throw ProviderError.rateLimited(message)
            } catch {
                AppLogger.network.warning("Proactive token refresh failed: \(error.localizedDescription)")
            }
        }

        var authedRequest = request
        addAuthHeaders(&authedRequest)
        let (data, response) = try await send(authedRequest)
        if response.statusCode != 401 {
            return (data, response)
        }

        if shouldAttemptTokenRefresh() {
            if let refreshed = try await refreshCoalesced() {
                connection.token = refreshed
                AppLogger.network.info("Token silently refreshed after 401")
                notifyTokenUpdated()
                var retry = request
                addAuthHeaders(&retry)
                return try await send(retry)
            }
        }

        guard let username = connection.username,
            let password = connection.password,
            !username.isEmpty
        else {
            return (data, response)
        }

        AppLogger.network.info("Received 401, refreshing JWT via full re-login")
        try await loginCoalesced(username: username, password: password)

        var retry = request
        addAuthHeaders(&retry)
        return try await send(retry)
    }

    private func performAuthorizedDownload(
        _ request: URLRequest,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> (URL, HTTPURLResponse) {
        if let token = connection.token,
            let jwt = BookloreJWT(token),
            jwt.isExpiring(buffer: 60),
            shouldAttemptTokenRefresh()
        {
            do {
                if let refreshed = try await refreshCoalesced() {
                    connection.token = refreshed
                    notifyTokenUpdated()
                    AppLogger.network.info("Proactive token refresh before ebook download")
                }
            } catch let ProviderError.rateLimited(message) {
                throw ProviderError.rateLimited(message)
            } catch {
                AppLogger.network.warning("Proactive streaming token refresh failed: \(error.localizedDescription)")
            }
        }

        func execute(_ req: URLRequest, onProgress: (@Sendable (Double) -> Void)?) async throws -> (URL, HTTPURLResponse) {

            let progressCallback: @Sendable (Double) -> Void = onProgress ?? { _ in }
            let delegate = URLSessionDownloadProgressDelegate(
                progressHandler: progressCallback,
                credential: transport.credential
            )
            let bgConfig = URLSessionConfiguration.background(withIdentifier: "com.enve.ebookdownload.\(UUID().uuidString)")
            bgConfig.waitsForConnectivity = true
            bgConfig.allowsExpensiveNetworkAccess = true
            bgConfig.allowsConstrainedNetworkAccess = true
            bgConfig.timeoutIntervalForRequest = 300
            bgConfig.timeoutIntervalForResource = 3600

            bgConfig.httpAdditionalHeaders = transport.sessionHeaders
            let downloadSession = URLSession(configuration: bgConfig, delegate: delegate, delegateQueue: nil)
            defer { downloadSession.finishTasksAndInvalidate() }

            let (localURL, http) = try await delegate.awaitResult {
                downloadSession.downloadTask(with: req)
            }
            return (localURL, http)
        }

        var authedRequest = request
        addAuthHeaders(&authedRequest)
        let first = try await execute(authedRequest, onProgress: onProgress)
        if first.1.statusCode != 401 {
            return first
        }

        if shouldAttemptTokenRefresh() {
            if let refreshed = try await refreshCoalesced() {
                connection.token = refreshed
                notifyTokenUpdated()
                AppLogger.network.info("Token silently refreshed after 401 during ebook download")
                var retry = request
                addAuthHeaders(&retry)
                return try await execute(retry, onProgress: onProgress)
            }
        }

        guard let username = connection.username,
            let password = connection.password,
            !username.isEmpty
        else {
            return first
        }

        AppLogger.network.info("Received 401 during ebook download, refreshing JWT via full re-login")
        try await loginCoalesced(username: username, password: password)

        var retry = request
        addAuthHeaders(&retry)
        return try await execute(retry, onProgress: onProgress)
    }

    private func shouldAttemptTokenRefresh() -> Bool {
        guard let rt = refreshToken, !rt.isEmpty else { return false }
        return true
    }

    func refreshStreamingTokenIfNeeded(force: Bool = false) async -> Bool {
        if !force,
            let token = connection.token,
            let jwt = BookloreJWT(token),
            !jwt.isExpiring(buffer: 60)
        {
            return true
        }
        guard shouldAttemptTokenRefresh() else { return false }
        do {

            guard let refreshed = try await refreshCoalesced() else {
                AppLogger.network.warning("Streaming token refresh returned no token")
                return false
            }
            connection.token = refreshed
            notifyTokenUpdated()
            AppLogger.network.info("Refreshed JWT for streaming download (force=\(force))")
            return true
        } catch {
            AppLogger.network.warning("Streaming token refresh failed: \(error.localizedDescription)")
            return false
        }
    }

    private func attemptTokenRefresh() async throws -> String? {
        guard shouldAttemptTokenRefresh(), let rt = refreshToken, !rt.isEmpty else { return nil }

        struct RefreshRequest: Encodable { let refreshToken: String }
        let body = try JSONEncoder().encode(RefreshRequest(refreshToken: rt))
        let request = try makeRequest(
            path: "/api/v1/auth/refresh",
            method: "POST",
            body: body,
            contentType: "application/json",
            includeAuth: false
        )

        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            if response.statusCode == 429 {
                throw ProviderError.rateLimited(
                    serverErrorMessage(from: data) ?? "Too many authentication attempts. Please try again in 15 minutes."
                )
            }
            if response.statusCode != 401 && response.statusCode != 403 {
                throw ProviderError.serverError(serverErrorMessage(from: data) ?? "Token refresh failed (HTTP \(response.statusCode))")
            }
            AppLogger.network.error("Token refresh rejected (HTTP \(response.statusCode)), will re-login")
            refreshToken = nil
            KeychainHelper.shared.delete(refreshTokenKeychainKey)
            return nil
        }

        let login = try JSONDecoder().decode(BookloreLoginResponse.self, from: data)
        saveRefreshToken(login.refreshToken)
        return login.accessToken
    }

    private func refreshCoalesced() async throws -> String? {
        lockLoginTask()
        if let existing = activeRefreshTask {
            unlockLoginTask()
            return try await existing.value
        }
        let task: Task<String?, Error> = Task { [weak self] in
            guard let self else { return nil }
            return try await self.attemptTokenRefresh()
        }
        activeRefreshTask = task
        unlockLoginTask()
        defer {
            lockLoginTask()
            activeRefreshTask = nil
            unlockLoginTask()
        }
        return try await task.value
    }

    private func notifyTokenUpdated() {
        let conn = connection
        let callback = onTokenUpdated
        DispatchQueue.main.async { callback?(conn) }
    }

    private func attemptTierUpgrade() async {
        guard useLegacyRestAPI || useKomgaFallback else { return }

        guard let req = try? makeRequest(path: "/api/v1/app/users/me") else { return }
        guard let (_, response) = try? await send(req), response.statusCode == 200 else { return }
        useLegacyRestAPI = false
        useKomgaFallback = false
        tierPreference.clear()
        AppLogger.network.info("[Booklore] Upgraded back to app-tier API")
    }

    private func demoteKomgaToLegacyREST() {
        useKomgaFallback = false
        useLegacyRestAPI = true
        tierPreference.store(.legacy)
    }

    private func loginCoalesced(username: String, password: String) async throws {
        if let blockedUntil = credentialLoginBlockedUntil, blockedUntil > Date() {
            throw ProviderError.rateLimited("Automatic sign-in is paused after a failed attempt. Please try again in 15 minutes.")
        }
        lockLoginTask()
        if let existing = activeLoginTask {
            unlockLoginTask()
            try await existing.value
            return
        }
        let task: Task<Void, Error> = Task { [weak self] in
            guard let self else { return }
            _ = try await self.loginWithCredentials(username: username, password: password)
        }
        activeLoginTask = task
        unlockLoginTask()
        defer {
            lockLoginTask()
            activeLoginTask = nil
            unlockLoginTask()
        }
        do {
            try await task.value
            credentialLoginBlockedUntil = nil
        } catch {
            if case ProviderError.unauthorized = error {
                credentialLoginBlockedUntil = Date().addingTimeInterval(15 * 60)
            } else if case ProviderError.rateLimited = error {
                credentialLoginBlockedUntil = Date().addingTimeInterval(15 * 60)
            }
            throw error
        }
    }

    private func fallbackCoverPath(for bookId: String, mediaType: AppMediaType) -> String {
        switch mediaType {
        case .audiobook:
            return "/api/v1/media/book/\(bookId)/audiobook-thumbnail"
        default:
            return "/api/v1/media/book/\(bookId)/cover"
        }
    }

    private func absoluteURL(from value: String?, mediaType: AppMediaType? = nil) -> URL? {
        BookloreBookMapper.absoluteURL(from: value, serverURL: connection.url, mediaType: mediaType)
    }

    private func catalogMapperContext(libraryId: String) -> BookloreCatalogMapper.Context {
        BookloreCatalogMapper.Context(
            providerId: connection.id,
            libraryId: libraryId,
            source: .booklore,
            serverURL: connection.url
        )
    }

    private func parseDate(_ value: String?) -> Date? {
        FlexibleDate.parse(value)
    }

    private func parseDate(_ value: FlexibleDate?) -> Date? {
        return value?.date
    }

    private func resolvedFileType(file: BookloreBookFile?) -> String? {
        BookloreBookMapper.resolvedFileType([
            file?.fileType,
            file?.fileExtension,
            file?.bookType,
            BookloreBookMapper.fileExtension(from: file?.fileName),
            BookloreBookMapper.fileExtension(from: file?.filePath),
        ])
    }

    private func normalize(_ urlString: String) -> String {
        BookloreBookMapper.normalizedBaseURL(urlString)
    }

    private func makeKomgaBasicRequest(path: String, queryItems: [URLQueryItem] = []) throws -> URLRequest {
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
        if let customHeaders = connection.customHeaders {
            for (key, value) in customHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        if let username = connection.username,
            let password = connection.password,
            !username.isEmpty,
            let data = "\(username):\(password)".data(using: .utf8)
        {
            request.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func guardJSON(_ data: Data, response: HTTPURLResponse, endpoint: String) throws {
        if let location = CloudflareAccessHeaders.accessRedirectLocation(in: response) {
            AppLogger.network.info("[Booklore] Cloudflare Access rejected the request for \(endpoint)")
            throw ProviderError.serverError(
                CloudflareAccessHeaders.accessRejectionMessage(location: location, endpoint: endpoint)
            )
        }

        guard HTTPResponseInspector.looksLikeHTML(data: data, response: response) else { return }

        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        AppLogger.network.info("[Booklore] Server returned HTML instead of JSON for \(endpoint). Content-Type: \(contentType)")

        if CloudflareAccessHeaders.htmlBodyIndicatesAccessBlock(data) {
            throw ProviderError.serverError(
                "Cloudflare Access is blocking the request to \(endpoint). "
                    + "Your service token may be invalid, expired, or not associated with the correct Access policy. "
                    + "Try using 'Login with Browser' instead, or verify your Cloudflare service token in the Zero Trust dashboard."
            )
        }

        throw ProviderError.serverError(
            "Server returned an HTML page instead of JSON for \(endpoint). "
                + "This usually means your BookLore server version does not yet support the mobile app API (requires a recent version with /api/v1/app/ endpoints). "
                + "Please update BookLore to the latest version."
        )
    }

    private func serverErrorMessage(from data: Data) -> String? {
        struct ErrorResponse: Decodable { let message: String }
        return (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.message
    }

    func refreshCoverImageSession() async throws {
        if let token = connection.token,
            let jwt = BookloreJWT(token),
            !jwt.isExpiring(buffer: 60)
        {
            return
        }

        if shouldAttemptTokenRefresh(), let refreshed = try await refreshCoalesced() {
            connection.token = refreshed
            notifyTokenUpdated()
            AppLogger.network.info("Session refreshed via refresh token")
            return
        }

        throw ProviderError.unauthorized
    }

    func fetchImageData(url: URL) async throws -> (Data, Int) {
        let requestedURL = BookloreBookMapper.rewriteCoverURL(url)

        if await coverCircuitBreaker.isOpen() {
            return (Data(), 503)
        }

        if await coverFailureCache.shouldSkip(requestedURL) {
            return (Data(), 503)
        }

        if requestedURL.path.contains("/audiobook-thumbnail") || requestedURL.path.contains("/audiobook-cover")
            || requestedURL.path.contains("/api/v1/audiobooks/")
        {
            AppLogger.network.info("[Booklore] Audiobook cover fetch original=\(url.redacted) rewritten=\(requestedURL.redacted)")
        }

        if connection.token == nil || connection.token?.isEmpty == true {
            if let username = connection.username,
                let password = connection.password,
                !username.isEmpty
            {
                try await loginCoalesced(username: username, password: password)
            } else if let refreshed = try? await refreshCoalesced() {
                connection.token = refreshed
                notifyTokenUpdated()
            }
        }

        guard let token = connection.token, !token.isEmpty else {
            throw ProviderError.unauthorized
        }

        func makeTokenURL(_ baseURL: URL, token: String) -> URL? {
            guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
            var queryItems = components.queryItems ?? []
            queryItems.removeAll { $0.name == "token" }
            queryItems.append(URLQueryItem(name: "token", value: token))
            components.queryItems = queryItems
            return components.url
        }

        func makeImageRequest(_ targetURL: URL, token: String) -> URLRequest {
            var request = URLRequest(url: targetURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 20
            request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let customHeaders = connection.customHeaders {
                for (key, value) in customHeaders {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
            return request
        }

        func isMissingCoverResponse(_ data: Data, response: HTTPURLResponse, requestedURL: URL) -> Bool {
            let path = requestedURL.path
            guard path.contains("/api/v1/media/book/") else { return false }

            if response.statusCode == 404 { return true }
            guard response.statusCode == 200 else { return false }
            return Self.isMissingCoverPlaceholder(data)
        }

        func alternateCoverURLs(for url: URL) -> [URL] {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [] }
            let path = components.path
            let candidates: [String]
            if path.hasSuffix("/cover") {
                candidates = [
                    String(path.dropLast("/cover".count)) + "/audiobook-cover",
                    String(path.dropLast("/cover".count)) + "/thumbnail",
                ]
            } else if path.hasSuffix("/thumbnail") {
                candidates = [
                    String(path.dropLast("/thumbnail".count)) + "/audiobook-thumbnail",
                    String(path.dropLast("/thumbnail".count)) + "/cover",
                ]
            } else if path.hasSuffix("/audiobook-cover") {
                candidates = [
                    String(path.dropLast("/audiobook-cover".count)) + "/cover",
                    String(path.dropLast("/audiobook-cover".count)) + "/audiobook-thumbnail",
                ]
            } else if path.hasSuffix("/audiobook-thumbnail") {
                candidates = [
                    String(path.dropLast("/audiobook-thumbnail".count)) + "/thumbnail",
                    String(path.dropLast("/audiobook-thumbnail".count)) + "/audiobook-cover",
                ]
            } else {
                candidates = []
            }

            return candidates.compactMap { candidatePath in
                components.path = candidatePath
                return components.url
            }
        }

        guard let authenticatedURL = makeTokenURL(requestedURL, token: token) else {
            throw ProviderError.invalidURL
        }

        let request = makeImageRequest(authenticatedURL, token: token)

        await coverFetchLimiter.acquire()
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await send(request)
        } catch {
            Task { await coverFetchLimiter.release() }
            throw error
        }
        Task { await coverFetchLimiter.release() }
        let status = response.statusCode

        if status == 502 || status == 503 || status == 504 {
            await coverFailureCache.recordFailure(requestedURL)
            await coverCircuitBreaker.recordFailure()
        } else if status == 200 {
            await coverCircuitBreaker.recordSuccess()
        }

        if isMissingCoverResponse(data, response: response, requestedURL: requestedURL) {
            for alternateURL in alternateCoverURLs(for: requestedURL) {
                guard let alternateAuthedURL = makeTokenURL(alternateURL, token: token) else { continue }
                let alternateRequest = makeImageRequest(alternateAuthedURL, token: token)
                if let (altData, altResponse) = try? await send(alternateRequest),
                    altResponse.statusCode == 200,
                    !isMissingCoverResponse(altData, response: altResponse, requestedURL: alternateURL)
                {
                    AppLogger.network.info("[Booklore] Replaced missing cover using fallback endpoint \(alternateURL.path)")
                    return (altData, altResponse.statusCode)
                }
            }
            return (Data(), 404)
        }

        if status == 401 || status == 403 {
            if let username = connection.username,
                let password = connection.password,
                !username.isEmpty
            {
                try await loginCoalesced(username: username, password: password)
            } else if let refreshed = try? await refreshCoalesced() {
                connection.token = refreshed
                notifyTokenUpdated()
            }

            guard let freshToken = connection.token, !freshToken.isEmpty else {
                return (data, status)
            }

            if let retryURL = makeTokenURL(requestedURL, token: freshToken) {
                let retryRequest = makeImageRequest(retryURL, token: freshToken)
                await coverFetchLimiter.acquire()
                let (retryData, retryResponse): (Data, HTTPURLResponse)
                do {
                    (retryData, retryResponse) = try await send(retryRequest)
                } catch {
                    Task { await coverFetchLimiter.release() }
                    throw error
                }
                Task { await coverFetchLimiter.release() }

                if isMissingCoverResponse(retryData, response: retryResponse, requestedURL: requestedURL) {
                    for alternateURL in alternateCoverURLs(for: requestedURL) {
                        guard let alternateAuthedURL = makeTokenURL(alternateURL, token: freshToken) else { continue }
                        let alternateRequest = makeImageRequest(alternateAuthedURL, token: freshToken)
                        if let (altData, altResponse) = try? await send(alternateRequest),
                            altResponse.statusCode == 200,
                            !isMissingCoverResponse(altData, response: altResponse, requestedURL: alternateURL)
                        {
                            AppLogger.network.info("[Booklore] Replaced missing cover using fallback endpoint \(alternateURL.path)")
                            return (altData, altResponse.statusCode)
                        }
                    }
                    return (Data(), 404)
                }

                if retryResponse.statusCode >= 300 {
                    AppLogger.network.warning(
                        "[Booklore] Cover fetch retry failed HTTP \(retryResponse.statusCode) path=\(requestedURL.path)"
                    )
                }

                return (retryData, retryResponse.statusCode)
            }
        }

        if status >= 300 {
            AppLogger.network.warning("[Booklore] Cover fetch failed HTTP \(status) path=\(requestedURL.path)")
        }

        return (data, status)
    }

    func validateConnection() async throws -> Bool {
        if let token = connection.token, !token.isEmpty {
            do {
                try await validateJWTSession()
                return true
            } catch ProviderError.unauthorized {
                AppLogger.network.error("Existing token validation failed: unauthorized")
            } catch {
                throw error
            }
        }

        if shouldAttemptTokenRefresh(), let refreshed = try await refreshCoalesced() {
            connection.token = refreshed
            notifyTokenUpdated()
            AppLogger.network.info("Token refreshed during validateConnection")
            try await validateJWTSession()
            return true
        }

        guard let username = connection.username,
            let password = connection.password,
            !username.isEmpty
        else {
            throw ProviderError.unauthorized
        }

        try await loginCoalesced(username: username, password: password)
        try await validateJWTSession()
        return true
    }

    private func loginWithCredentials(username: String, password: String) async throws -> BookloreLoginResponse {
        let payload = BookloreLoginRequest(username: username, password: password)
        let body = try JSONEncoder().encode(payload)
        let request = try makeRequest(
            path: "/api/v1/auth/login",
            method: "POST",
            body: body,
            contentType: "application/json",
            includeAuth: false
        )

        if let headers = connection.customHeaders, !headers.isEmpty {
            AppLogger.network.info("Sending custom headers with login: \(headers.keys.sorted().joined(separator: ", "))")
        }
        AppLogger.network.info("Logging in via /api/v1/auth/login")
        let (data, response) = try await send(request)
        AppLogger.network.info("/api/v1/auth/login -> HTTP \(response.statusCode)")

        try guardJSON(data, response: response, endpoint: "/api/v1/auth/login")

        guard response.statusCode == 200 else {
            AppLogger.network.info("Login rejected with HTTP \(response.statusCode)")
            if response.statusCode == 429 {
                throw ProviderError.rateLimited(
                    serverErrorMessage(from: data) ?? "Too many failed login attempts. Please try again in 15 minutes."
                )
            }
            if response.statusCode == 401 || response.statusCode == 403 {
                throw ProviderError.unauthorized
            }
            throw ProviderError.serverError(serverErrorMessage(from: data) ?? "Login failed (HTTP \(response.statusCode))")
        }

        let login = try JSONDecoder().decode(BookloreLoginResponse.self, from: data)
        connection.token = login.accessToken
        saveRefreshToken(login.refreshToken)
        AppLogger.network.info("JWT login succeeded (refreshToken: \(login.refreshToken != nil ? "present" : "absent"))")
        notifyTokenUpdated()
        return login
    }

    private func validateJWTSession() async throws {
        let request = try makeRequest(path: "/api/v1/users/me")
        AppLogger.network.info("Validating JWT via /api/v1/users/me")
        let (data, response) = try await performAuthorizedRequest(request)
        AppLogger.network.info("/api/v1/users/me -> HTTP \(response.statusCode)")

        try guardJSON(data, response: response, endpoint: "/api/v1/users/me")

        guard response.statusCode == 200 else {
            AppLogger.network.error("JWT validation failed with HTTP \(response.statusCode)")
            if response.statusCode == 401 || response.statusCode == 403 {
                throw ProviderError.unauthorized
            }
            throw ProviderError.serverError("Validation failed (HTTP \(response.statusCode))")
        }
    }

    private struct KomgaLibrary: Decodable {
        let id: String
        let name: String

        enum CodingKeys: String, CodingKey {
            case id, name
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)

            if let stringId = try? container.decode(String.self, forKey: .id) {
                id = stringId
            } else if let intId = try? container.decode(Int.self, forKey: .id) {
                id = String(intId)
            } else {
                throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "ID must be a String or Int")
            }
        }
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
        let created: FlexibleDate?
        let summary: String?
        let size: String?
        let media: KomgaMedia?
        let metadata: KomgaMetadata?

        enum CodingKeys: String, CodingKey {
            case id, seriesId, seriesTitle, libraryId, name, created, summary, size, media, metadata
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)

            if let s = try? container.decode(String.self, forKey: .id) {
                id = s
            } else if let i = try? container.decode(Int.self, forKey: .id) {
                id = String(i)
            } else {
                id = "unknown"
            }

            if let s = try? container.decode(String.self, forKey: .seriesId) {
                seriesId = s
            } else if let i = try? container.decode(Int.self, forKey: .seriesId) {
                seriesId = String(i)
            } else {
                seriesId = ""
            }

            if let s = try? container.decode(String.self, forKey: .libraryId) {
                libraryId = s
            } else if let i = try? container.decode(Int.self, forKey: .libraryId) {
                libraryId = String(i)
            } else {
                libraryId = nil
            }

            seriesTitle = try container.decodeIfPresent(String.self, forKey: .seriesTitle)
            created = try container.decodeIfPresent(FlexibleDate.self, forKey: .created)
            summary = try container.decodeIfPresent(String.self, forKey: .summary)
            size = try? container.decodeIfPresent(String.self, forKey: .size)
            media = try? container.decodeIfPresent(KomgaMedia.self, forKey: .media)
            metadata = try? container.decodeIfPresent(KomgaMetadata.self, forKey: .metadata)
        }
    }

    private struct KomgaMedia: Decodable {
        let pagesCount: Int?
        let mediaType: String?
    }

    private struct KomgaMetadata: Decodable {
        let title: String?
        let summary: String?
        let number: String?
        let authors: [KomgaAuthor]?
    }

    private struct KomgaAuthor: Decodable {
        let name: String
        let role: String
    }

    private struct BookloreLoginRequest: Encodable {
        let username: String
        let password: String
    }

    private struct BookloreLoginResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
    }

    private struct BookloreAudiobookProgress: Decodable {
        let positionMs: Double?
        let trackIndex: Int?
        let percentage: Double?
        let updatedAt: String?
    }

    private struct BooklorePdfProgress: Decodable {
        let page: Int?
        let percentage: Double?
        let updatedAt: String?
    }

    private struct BookloreCbxProgress: Decodable {
        let page: Int?
        let percentage: Double?
        let updatedAt: String?
    }

    private struct BookloreSyncBookDetail: Decodable {
        let readProgress: Double?
        let readStatus: String?
        let lastReadTime: String?
        let epubProgress: BookloreEpubProgress?
        let pdfProgress: BooklorePdfProgress?
        let cbxProgress: BookloreCbxProgress?
        let audiobookProgress: BookloreAudiobookProgress?
        let duration: Double?
        let durationSeconds: Int?
        let primaryFileType: String?
        let dateFinished: String?
        let files: [BookloreBookFile]?

        enum CodingKeys: String, CodingKey {
            case readProgress
            case readStatus
            case lastReadTime
            case epubProgress
            case pdfProgress
            case cbxProgress
            case audiobookProgress
            case duration
            case durationMs
            case durationSeconds
            case primaryFileType
            case fileType
            case type
            case format
            case dateFinished
            case files
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            readProgress = try container.decodeIfPresent(Double.self, forKey: .readProgress)
            readStatus = try container.decodeIfPresent(String.self, forKey: .readStatus)
            lastReadTime = try container.decodeIfPresent(String.self, forKey: .lastReadTime)
            epubProgress = try container.decodeIfPresent(BookloreEpubProgress.self, forKey: .epubProgress)
            pdfProgress = try container.decodeIfPresent(BooklorePdfProgress.self, forKey: .pdfProgress)
            cbxProgress = try container.decodeIfPresent(BookloreCbxProgress.self, forKey: .cbxProgress)
            audiobookProgress = try container.decodeIfPresent(BookloreAudiobookProgress.self, forKey: .audiobookProgress)
            let durationMs = try container.decodeIfPresent(Double.self, forKey: .durationMs)
            let durationPlain = try container.decodeIfPresent(Double.self, forKey: .duration)
            duration = durationMs.map { $0 / 1000 } ?? durationPlain.map { $0 > 10_000 ? $0 / 1000 : $0 }
            durationSeconds = try container.decodeIfPresent(Int.self, forKey: .durationSeconds)
            primaryFileType =
                try container.decodeIfPresent(String.self, forKey: .primaryFileType)
                ?? container.decodeIfPresent(String.self, forKey: .fileType)
                ?? container.decodeIfPresent(String.self, forKey: .type)
                ?? container.decodeIfPresent(String.self, forKey: .format)
            dateFinished = try container.decodeIfPresent(String.self, forKey: .dateFinished)
            files = try container.decodeIfPresent([BookloreBookFile].self, forKey: .files)
        }
    }

    struct AppNotebookEntry: Decodable, Sendable {
        enum EntryType: String, Decodable, Sendable {
            case bookmark = "BOOKMARK"
            case highlight = "HIGHLIGHT"
            case note = "NOTE"
        }

        let id: Int
        let type: EntryType
        let bookId: Int
        let text: String?
        let note: String?
        let color: String?
        let style: String?
        let createdAt: String?
        let updatedAt: String?
    }

    private struct NotebookEntriesPage: Decodable {
        let content: [AppNotebookEntry]
        let hasNext: Bool?
    }

    struct RemoteBookmarkRecord: Decodable, Sendable {
        let id: Int
        let bookId: Int
        let cfi: String?
        let positionMs: Double?
        let trackIndex: Int?
        let title: String?
        let notes: String?
        let color: String?
        let priority: Int?
        let createdAt: String?
        let updatedAt: String?
    }

    struct RemoteAnnotationRecord: Decodable, Sendable {
        let id: Int
        let bookId: Int
        let cfi: String?
        let text: String?
        let color: String?
        let style: String?
        let note: String?
        let chapterTitle: String?
        let createdAt: String?
        let updatedAt: String?
    }

    struct RemoteBookNoteRecord: Decodable, Sendable {
        let id: Int
        let bookId: Int
        let cfi: String?
        let selectedText: String?
        let noteContent: String?
        let color: String?
        let chapterTitle: String?
        let createdAt: String?
        let updatedAt: String?
    }

    private struct BookloreBookDetail: Decodable {
        let id: FlexibleID
        let title: String
        let authors: [String]?
        let thumbnailUrl: String?
        let duration: Double?
        let seriesName: String?
        let seriesNumber: Double?
        let libraryId: FlexibleID?
        let addedOn: FlexibleDate?
        let description: String?
        let publisher: String?
        let publishedDate: String?
        let personalRating: Double?
        let goodreadsRating: Double?
        let isbn13: String?
        let language: String?
        let libraryName: String?
        let readProgress: Double?
        let readStatus: String?
        let primaryFileType: String?
        let pageCount: Int?
        let files: [BookloreBookFile]?
        let audiobookProgress: BookloreAudiobookProgress?
        let epubProgress: BookloreEpubProgress?
        let pdfProgress: BooklorePdfProgress?
        let lastReadTime: String?
        let dateFinished: String?
        let durationSeconds: Int?
        let chapters: [GrimmoryChapter]?
        let categories: Set<String>?
        let primaryFile: BooklorePrimaryFile?

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case authors
            case thumbnailUrl
            case duration
            case durationMs
            case seriesName
            case seriesNumber
            case libraryId
            case addedOn
            case description
            case publisher
            case publishedDate
            case personalRating
            case goodreadsRating
            case isbn13
            case language
            case libraryName
            case readProgress
            case readStatus
            case primaryFileType
            case fileType
            case type
            case format
            case pageCount
            case files
            case audiobookProgress
            case epubProgress
            case pdfProgress
            case lastReadTime
            case dateFinished
            case durationSeconds
            case chapters
            case categories
            case primaryFile
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(FlexibleID.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            authors = try container.decodeIfPresent([String].self, forKey: .authors)
            thumbnailUrl = try container.decodeIfPresent(String.self, forKey: .thumbnailUrl)
            let durationMs = try container.decodeIfPresent(Double.self, forKey: .durationMs)
            let durationPlain = try container.decodeIfPresent(Double.self, forKey: .duration)
            duration = durationMs.map { $0 / 1000 } ?? durationPlain.map { $0 > 10_000 ? $0 / 1000 : $0 }
            seriesName = try container.decodeIfPresent(String.self, forKey: .seriesName)
            seriesNumber = try container.decodeIfPresent(Double.self, forKey: .seriesNumber)
            libraryId = try container.decodeIfPresent(FlexibleID.self, forKey: .libraryId)
            addedOn = try container.decodeIfPresent(FlexibleDate.self, forKey: .addedOn)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            publisher = try container.decodeIfPresent(String.self, forKey: .publisher)
            publishedDate = try container.decodeIfPresent(String.self, forKey: .publishedDate)
            personalRating = try container.decodeIfPresent(Double.self, forKey: .personalRating)
            goodreadsRating = try container.decodeIfPresent(Double.self, forKey: .goodreadsRating)
            isbn13 = try container.decodeIfPresent(String.self, forKey: .isbn13)
            language = try container.decodeIfPresent(String.self, forKey: .language)
            libraryName = try container.decodeIfPresent(String.self, forKey: .libraryName)
            readProgress = try container.decodeIfPresent(Double.self, forKey: .readProgress)
            readStatus = try container.decodeIfPresent(String.self, forKey: .readStatus)
            primaryFileType =
                try container.decodeIfPresent(String.self, forKey: .primaryFileType)
                ?? container.decodeIfPresent(String.self, forKey: .fileType)
                ?? container.decodeIfPresent(String.self, forKey: .type)
                ?? container.decodeIfPresent(String.self, forKey: .format)
            pageCount = try container.decodeIfPresent(Int.self, forKey: .pageCount)
            files = try container.decodeIfPresent([BookloreBookFile].self, forKey: .files)
            audiobookProgress = try container.decodeIfPresent(BookloreAudiobookProgress.self, forKey: .audiobookProgress)
            epubProgress = try container.decodeIfPresent(BookloreEpubProgress.self, forKey: .epubProgress)
            pdfProgress = try container.decodeIfPresent(BooklorePdfProgress.self, forKey: .pdfProgress)
            lastReadTime = try container.decodeIfPresent(String.self, forKey: .lastReadTime)
            dateFinished = try container.decodeIfPresent(String.self, forKey: .dateFinished)
            durationSeconds = try container.decodeIfPresent(Int.self, forKey: .durationSeconds)
            chapters = try container.decodeIfPresent([GrimmoryChapter].self, forKey: .chapters)
            categories = try container.decodeIfPresent(Set<String>.self, forKey: .categories)
            primaryFile = try container.decodeIfPresent(BooklorePrimaryFile.self, forKey: .primaryFile)
        }
    }

    private struct BookloreBookFile: Decodable {
        let id: FlexibleID?
        let fileName: String?
        let filePath: String?
        let bookType: String?
        let fileType: String?
        let fileExtension: String?
        let isPrimary: Bool?
        let folderBased: Bool?

        enum CodingKeys: String, CodingKey {
            case id
            case fileName
            case filePath
            case bookType
            case fileType
            case type
            case format
            case fileExtension
            case extensionValue = "extension"
            case isPrimary
            case primary
            case folderBased
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(FlexibleID.self, forKey: .id)
            fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
            filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
            bookType = try container.decodeIfPresent(String.self, forKey: .bookType)
            fileType =
                try container.decodeIfPresent(String.self, forKey: .fileType)
                ?? container.decodeIfPresent(String.self, forKey: .type)
                ?? container.decodeIfPresent(String.self, forKey: .format)
            fileExtension =
                try container.decodeIfPresent(String.self, forKey: .fileExtension)
                ?? container.decodeIfPresent(String.self, forKey: .extensionValue)
            isPrimary =
                try container.decodeIfPresent(Bool.self, forKey: .isPrimary)
                ?? container.decodeIfPresent(Bool.self, forKey: .primary)
            folderBased = try container.decodeIfPresent(Bool.self, forKey: .folderBased)
        }
    }

    private struct GrimmoryEbookResource {
        let bookId: Int
        let fileId: Int
        let isPrimary: Bool
        let fileName: String?
    }

    private func fetchLibrariesViaKomga() async throws -> [Library] {
        let request = try makeKomgaBasicRequest(path: "/komga/api/v1/libraries")
        AppLogger.network.info("[Booklore/Komga] GET \(request.url?.redacted.absoluteString ?? "<nil>")")
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await send(request)
        } catch {
            if shouldFallbackFromKomga(error) {
                AppLogger.network.error("[Booklore/Komga] Request failed (\(error.localizedDescription)) - switching to legacy REST API")
                demoteKomgaToLegacyREST()
                return try await fetchLibrariesViaLegacyAPI()
            }
            throw error
        }
        if response.statusCode == 401 {
            AppLogger.network.info("[Booklore/Komga] 401 - no OPDS credentials, switching to legacy REST API")
            demoteKomgaToLegacyREST()
            return try await fetchLibrariesViaLegacyAPI()
        }
        guard response.statusCode == 200 else {
            AppLogger.network.info("[Booklore/Komga] HTTP \(response.statusCode) - switching to legacy REST API")
            demoteKomgaToLegacyREST()
            return try await fetchLibrariesViaLegacyAPI()
        }
        let libraries = try JSONDecoder().decode([KomgaLibrary].self, from: data)
        AppLogger.network.info("[Booklore/Komga] Found \(libraries.count) libraries")
        return libraries.map {
            Library(id: $0.id, name: $0.name, type: "book", providerId: connection.id)
        }
    }

    private func fetchBooksViaKomga(libraryId: String) async throws -> [Book] {
        var page = 0
        var allBooks: [Book] = []
        while true {
            let request = try makeKomgaBasicRequest(
                path: "/komga/api/v1/books",
                queryItems: [
                    URLQueryItem(name: "library_id", value: libraryId),
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "size", value: String(pageSize)),
                ]
            )
            if page == 0 { AppLogger.network.info("[Booklore/Komga] GET \(request.url?.redacted.absoluteString ?? "<nil>")") }
            let (data, response): (Data, HTTPURLResponse)
            do {
                (data, response) = try await send(request)
            } catch {
                if shouldFallbackFromKomga(error) {
                    AppLogger.network.error(
                        "[Booklore/Komga] Books request failed (\(error.localizedDescription)) - switching to legacy REST API"
                    )
                    demoteKomgaToLegacyREST()
                    return try await fetchBooksViaLegacyAPI(libraryId: libraryId)
                }
                throw error
            }
            if response.statusCode == 401 {
                AppLogger.network.info("[Booklore/Komga] Books request returned 401 - switching to legacy REST API")
                demoteKomgaToLegacyREST()
                return try await fetchBooksViaLegacyAPI(libraryId: libraryId)
            }
            guard response.statusCode == 200 else {
                AppLogger.network.info("[Booklore/Komga] Books request returned HTTP \(response.statusCode) - switching to legacy REST API")
                demoteKomgaToLegacyREST()
                return try await fetchBooksViaLegacyAPI(libraryId: libraryId)
            }
            let result: KomgaPage<KomgaBook>
            do {
                result = try JSONDecoder().decode(KomgaPage<KomgaBook>.self, from: data)
            } catch {
                AppLogger.network.error("[Booklore/Komga] Books decode failed (page \(page)): \(String(describing: error))")
                throw error
            }
            allBooks.append(contentsOf: result.content.map { mapKomgaBookToBook($0, libraryId: libraryId) })
            let isLast = result.last ?? (page >= result.totalPages - 1)
            if isLast || result.content.isEmpty { break }
            page += 1
        }
        return allBooks
    }

    private func fetchRecentBooksViaKomga(libraryId: String, limit: Int) async throws -> [Book] {
        let request = try makeKomgaBasicRequest(
            path: "/komga/api/v1/books",
            queryItems: [
                URLQueryItem(name: "library_id", value: libraryId),
                URLQueryItem(name: "page", value: "0"),
                URLQueryItem(name: "size", value: String(min(limit, pageSize))),
            ]
        )
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await send(request)
        } catch {
            if shouldFallbackFromKomga(error) {
                AppLogger.network.error(
                    "[Booklore/Komga] Recent books request failed (\(error.localizedDescription)) - switching to legacy REST API"
                )
                demoteKomgaToLegacyREST()
                let all = (try? await fetchBooksViaLegacyAPI(libraryId: libraryId)) ?? []
                return Array(all.prefix(limit))
            }
            throw error
        }
        guard response.statusCode == 200 else {
            if response.statusCode == 401 {
                AppLogger.network.info("[Booklore/Komga] Recent books returned 401 - switching to legacy REST API")
            } else {
                AppLogger.network.info("[Booklore/Komga] Recent books returned HTTP \(response.statusCode) - switching to legacy REST API")
            }
            demoteKomgaToLegacyREST()
            let all = (try? await fetchBooksViaLegacyAPI(libraryId: libraryId)) ?? []
            return Array(all.prefix(limit))
        }
        let result = try JSONDecoder().decode(KomgaPage<KomgaBook>.self, from: data)
        return result.content.map { mapKomgaBookToBook($0, libraryId: libraryId) }
    }

    private func shouldFallbackFromKomga(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return nsError.code == NSURLErrorCancelled || nsError.code == NSURLErrorUserCancelledAuthentication
                || nsError.code == NSURLErrorUserAuthenticationRequired
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled, .userCancelledAuthentication, .userAuthenticationRequired:
                return true
            default:
                break
            }
        }

        return false
    }

    private func switchToLegacyBooksAPI(reason: String, libraryId: String) async throws -> [Book] {
        AppLogger.network.info(
            "[Booklore] \(reason) - using legacy catalog endpoint for library \(libraryId) while preserving app feature endpoints"
        )
        useKomgaFallback = false
        useLegacyCatalogFallback = true
        return try await fetchBooksViaLegacyAPI(libraryId: libraryId)
    }

    private func mapKomgaBookToBook(_ book: KomgaBook, libraryId: String) -> Book {
        let title = book.metadata?.title ?? book.name
        let author = BookloreBookMapper.displayAuthor(from: book.metadata?.authors?.map { $0.name })
        let komgaAuthors: [String]? = book.metadata?.authors?.compactMap { $0.name.isEmpty ? nil : $0.name }
        let seriesInfo: SeriesInfo? = {
            guard let seriesTitle = book.seriesTitle, !seriesTitle.isEmpty else { return nil }
            return SeriesInfo(name: seriesTitle, sequence: book.metadata?.number)
        }()
        let coverURL = absoluteURL(from: "/komga/api/v1/books/\(book.id)/thumbnail")
        let detectedMediaType: AppMediaType
        if let mimeType = book.media?.mediaType?.lowercased(),
            mimeType.hasPrefix("audio/")
        {
            detectedMediaType = .audiobook
        } else {
            detectedMediaType = .ebook
        }
        return Book(
            id: book.id,
            title: title,
            author: author,
            authors: komgaAuthors,
            narrator: nil,
            seriesInfo: seriesInfo,
            duration: 0,
            coverURL: coverURL,
            mediaType: detectedMediaType,
            description: book.metadata?.summary ?? book.summary,
            genres: [],
            chapters: [],
            publisher: nil,
            progress: 0,
            currentTime: 0,
            isFinished: false,
            lastUpdate: book.created?.date ?? Date(),
            libraryId: book.libraryId ?? libraryId,
            providerId: connection.id,
            source: .booklore,
            rawMetadata: nil
        )
    }

    private func fetchLibrariesViaLegacyAPI() async throws -> [Library] {
        let request = try makeRequest(path: "/api/v1/libraries")
        AppLogger.network.info("[Booklore/Legacy] GET \(request.url?.redacted.absoluteString ?? "<nil>")")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Legacy API: failed to fetch libraries (HTTP \(response.statusCode))")
        }
        let libraries = try JSONDecoder().decode([BookloreLegacyLibrary].self, from: data)
        AppLogger.network.info("[Booklore/Legacy] Found \(libraries.count) libraries")
        return
            libraries
            .filter { lib in
                guard let formats = lib.allowedFormats, !formats.isEmpty else { return true }
                return formats.contains {
                    ["EPUB", "PDF", "CBX", "CBR", "CBZ", "FB2", "MOBI", "AZW3", "AUDIOBOOK"].contains($0.uppercased())
                }
            }
            .map {
                Library(
                    id: $0.id.stringValue,
                    name: $0.name,
                    type: BookloreBookMapper.libraryType(from: $0.allowedFormats),
                    providerId: connection.id
                )
            }
    }

    private func fetchBooksViaLegacyAPI(libraryId: String) async throws -> [Book] {
        let request = try makeRequest(path: "/api/v1/libraries/\(libraryId)/book")
        AppLogger.network.info("[Booklore/Legacy] GET \(request.url?.redacted.absoluteString ?? "<nil>")")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Legacy API: failed to fetch books (HTTP \(response.statusCode))")
        }
        let books: [BookloreLegacyBook]
        do {
            books = try JSONDecoder().decode([BookloreLegacyBook].self, from: data)
        } catch {
            AppLogger.network.error("[Booklore/Legacy] Books decode failed: \(String(describing: error))")
            throw error
        }
        AppLogger.network.info("[Booklore/Legacy] Fetched \(books.count) books for library \(libraryId)")
        let context = catalogMapperContext(libraryId: libraryId)
        return books.map { BookloreCatalogMapper.book(from: $0, context: context) }
    }

    func fetchLibraries() async throws -> [Library] {
        if connection.token == nil || connection.token?.isEmpty == true,
            let username = connection.username,
            let password = connection.password,
            !username.isEmpty
        {
            try await loginCoalesced(username: username, password: password)
            AppLogger.network.info("[Booklore] Pre-fetched JWT so cover thumbnails will be authenticated")
        }

        if useLegacyRestAPI || useLegacyCatalogFallback {
            return try await fetchLibrariesViaLegacyAPI()
        }

        if useKomgaFallback {
            return try await fetchLibrariesViaKomga()
        }

        return try await fetchLibrariesViaLegacyAPI()
    }

    func fetchBooks(libraryId: String) async throws -> [Book] {
        return try await fetchBooks(libraryId: libraryId, onBatch: nil)
    }

    func fetchBooks(libraryId: String, onBatch: ((_ batch: LibraryFetchBatchResult) -> Void)?) async throws -> [Book] {
        if useLegacyRestAPI {
            return try await fetchBooksViaLegacyAPI(libraryId: libraryId)
        }
        if useLegacyCatalogFallback {

            var legacyBooks = try await fetchBooksViaLegacyAPI(libraryId: libraryId)
            var companions = makeCompanionAudiobooks(forEbooks: &legacyBooks)
            if !companions.isEmpty {
                await withTaskGroup(of: (Int, Book).self) { group in
                    for idx in companions.indices {
                        let book = companions[idx]
                        group.addTask { (idx, await self.enrichListedAudiobook(book)) }
                    }
                    for await (idx, enriched) in group {
                        companions[idx] = enriched
                    }
                }
                legacyBooks.append(contentsOf: companions)
                AppLogger.network.info("[Booklore] Emitted \(companions.count) companion audiobook entries (legacy-catalog tier)")
            }
            return legacyBooks
        }
        if useKomgaFallback {
            return try await fetchBooksViaKomga(libraryId: libraryId)
        }

        let firstPage: BooklorePage<BookloreBookSummary>
        let firstPageData: Data
        do {
            let data = try await fetchAppBooksPageData(libraryId: libraryId, page: 0)
            firstPageData = data
            firstPage = try JSONDecoder().decode(BooklorePage<BookloreBookSummary>.self, from: data)
        } catch {
            return try await switchToLegacyBooksAPI(
                reason: "Mobile app books request failed (\(error.localizedDescription))",
                libraryId: libraryId
            )
        }

        if firstPage.content.isEmpty {
            return try await switchToLegacyBooksAPI(reason: "Mobile app books returned an empty first page", libraryId: libraryId)
        }

        var checkpoint: GrimmoryCatalogCheckpoint?
        do {
            let prepared = try GrimmoryCatalogCheckpointStore.prepare(
                connectionId: connection.id,
                libraryId: libraryId,
                serverIdentity: connection.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased(),
                totalPages: firstPage.totalPages,
                totalElements: firstPage.totalElements,
                pageSize: firstPage.size,
                firstPageFingerprint: catalogFingerprint(for: firstPage),
                firstPageData: firstPageData
            )
            checkpoint = prepared.checkpoint
            if prepared.resumed {
                AppLogger.network.info(
                    "[Booklore] Resuming catalog checkpoint for library \(libraryId) with \(prepared.checkpoint.completedPages.count)/\(firstPage.totalPages) pages staged"
                )
            }
        } catch {
            AppLogger.network.warning("[Booklore] Catalog checkpoint unavailable: \(error.localizedDescription)")
        }

        var pageData: [Int: Data] = [0: firstPageData]
        if var current = checkpoint {
            for page in current.completedPages.sorted() where page > 0 && page < firstPage.totalPages {
                do {
                    let data = try GrimmoryCatalogCheckpointStore.pageData(
                        connectionId: connection.id,
                        libraryId: libraryId,
                        page: page
                    )
                    let stagedPage = try JSONDecoder().decode(BooklorePage<BookloreBookSummary>.self, from: data)
                    guard stagedPage.page == page,
                        stagedPage.totalPages == firstPage.totalPages,
                        stagedPage.totalElements == firstPage.totalElements
                    else {
                        throw ProviderError.invalidResponse
                    }
                    pageData[page] = data
                } catch {
                    GrimmoryCatalogCheckpointStore.discardPage(page: page, checkpoint: &current)
                    AppLogger.network.warning("[Booklore] Discarded invalid staged catalog page \(page)")
                }
            }
            checkpoint = current
        }

        let missingPages = (1..<firstPage.totalPages).filter { pageData[$0] == nil }
        var missingOffset = 0
        while missingOffset < missingPages.count {
            let endOffset = min(missingOffset + pageConcurrency, missingPages.count)
            let requestedPages = Array(missingPages[missingOffset..<endOffset])
            do {
                let pages = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                    for page in requestedPages {
                        group.addTask {
                            (page, try await self.fetchAppBooksPageData(libraryId: libraryId, page: page))
                        }
                    }

                    var loaded: [(Int, Data)] = []
                    loaded.reserveCapacity(requestedPages.count)
                    for try await page in group {
                        loaded.append(page)
                    }
                    return loaded.sorted { $0.0 < $1.0 }
                }

                for (page, data) in pages {
                    do {
                        let decoded = try JSONDecoder().decode(BooklorePage<BookloreBookSummary>.self, from: data)
                        guard decoded.page == page,
                            decoded.totalPages == firstPage.totalPages,
                            decoded.totalElements == firstPage.totalElements
                        else {
                            throw ProviderError.invalidResponse
                        }
                        pageData[page] = data
                        if var current = checkpoint {
                            do {
                                try GrimmoryCatalogCheckpointStore.recordPage(data, page: page, checkpoint: &current)
                                checkpoint = current
                            } catch {
                                checkpoint = nil
                                AppLogger.network.warning(
                                    "[Booklore] Could not persist catalog page \(page): \(error.localizedDescription)"
                                )
                            }
                        }
                    } catch {
                        AppLogger.network.error("[Booklore] Book page decode failed (page \(page)): \(String(describing: error))")
                        throw error
                    }
                }
            } catch {
                return try await switchToLegacyBooksAPI(
                    reason: "Mobile app books page batch failed (\(error.localizedDescription))",
                    libraryId: libraryId
                )
            }
            missingOffset = endOffset
        }

        var allBooks: [Book] = []
        let context = catalogMapperContext(libraryId: libraryId)
        func append(_ page: BooklorePage<BookloreBookSummary>) {
            let batch = page.content.map { BookloreCatalogMapper.book(from: $0, context: context) }
            allBooks.append(contentsOf: batch)
            onBatch?(
                LibraryFetchBatchResult(
                    books: batch,
                    loadedSoFar: allBooks.count,
                    totalCount: firstPage.totalElements
                )
            )
        }

        for page in 0..<firstPage.totalPages {
            guard let data = pageData[page] else {
                return try await switchToLegacyBooksAPI(
                    reason: "Mobile app books snapshot is missing page \(page)",
                    libraryId: libraryId
                )
            }
            do {
                append(try JSONDecoder().decode(BooklorePage<BookloreBookSummary>.self, from: data))
            } catch {
                return try await switchToLegacyBooksAPI(
                    reason: "Mobile app books staged page decode failed (\(error.localizedDescription))",
                    libraryId: libraryId
                )
            }
        }

        let companions = makeCompanionAudiobooks(forEbooks: &allBooks)
        if !companions.isEmpty {
            allBooks.append(contentsOf: companions)
            onBatch?(LibraryFetchBatchResult(books: companions, loadedSoFar: allBooks.count, totalCount: allBooks.count))
            AppLogger.network.info("[Booklore] Emitted \(companions.count) companion audiobook entries")
        }

        AppLogger.network.info("[Booklore] Fetched \(allBooks.count) books from library \(libraryId)")
        return allBooks
    }

    private func catalogFingerprint(for page: BooklorePage<BookloreBookSummary>) -> String {
        let identity = page.content.map { $0.id.stringValue }.joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func fetchAppBooksPageData(libraryId: String, page: Int) async throws -> Data {
        let request = try makeRequest(
            path: "/api/v1/app/books",
            queryItems: [
                URLQueryItem(name: "libraryId", value: libraryId),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "size", value: String(pageSize)),
                URLQueryItem(name: "sort", value: "addedOn"),
                URLQueryItem(name: "dir", value: "desc"),
            ]
        )
        if page == 0 {
            AppLogger.network.info("[Booklore] GET \(request.url?.redacted.absoluteString ?? "<nil>")")
        }

        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Mobile app books returned HTTP \(response.statusCode)")
        }
        try guardJSON(data, response: response, endpoint: "/api/v1/app/books")
        return data
    }

    var supportsRemoteBrowsing: Bool { supportsTransactionalCatalogImport }

    func remoteBookCount(libraryId: String) async throws -> Int {
        try await fetchRemoteBrowsePage(
            libraryId: libraryId,
            page: 0,
            size: 1,
            sort: .addedOn,
            descending: true,
            search: nil
        ).totalElements
    }

    func remoteBooksPage(
        libraryId: String,
        offset: Int,
        limit: Int,
        sort: GrimmoryRemoteSort,
        descending: Bool
    ) async throws -> GrimmoryRemotePage {
        guard offset >= 0, limit > 0 else { throw ProviderError.invalidResponse }
        let size = min(limit, remoteBrowsePageSize)
        let firstPage = offset / size
        let lastPage = (offset + limit - 1) / size
        let pageNumbers = Array(firstPage...lastPage)

        var pages: [BooklorePage<BookloreBookSummary>] = []
        var chunkStart = 0
        while chunkStart < pageNumbers.count {
            let chunkEnd = min(chunkStart + pageConcurrency, pageNumbers.count)
            let chunk = Array(pageNumbers[chunkStart..<chunkEnd])
            let dataByPage = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for page in chunk {
                    group.addTask {
                        (
                            page,
                            try await self.fetchRemoteBrowsePageData(
                                libraryId: libraryId,
                                page: page,
                                size: size,
                                sort: sort,
                                descending: descending,
                                search: nil
                            )
                        )
                    }
                }
                var loaded: [Int: Data] = [:]
                for try await (page, data) in group { loaded[page] = data }
                return loaded
            }

            var reachedEnd = false
            for page in chunk {
                guard let data = dataByPage[page] else { throw ProviderError.invalidResponse }
                let decoded = try JSONDecoder().decode(BooklorePage<BookloreBookSummary>.self, from: data)
                pages.append(decoded)
                if !decoded.hasNext {
                    reachedEnd = true
                    break
                }
            }
            if reachedEnd { break }
            chunkStart = chunkEnd
        }

        let window = pages.flatMap(\.content).dropFirst(offset - firstPage * size).prefix(limit)
        let context = catalogMapperContext(libraryId: libraryId)
        return GrimmoryRemotePage(
            books: window.map { BookloreCatalogMapper.book(from: $0, context: context) },
            totalCount: pages[0].totalElements
        )
    }

    func remoteSearchBooks(libraryId: String, query: String, limit: Int) async throws -> [Book] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }

        let page = try await fetchRemoteBrowsePage(
            libraryId: libraryId,
            page: 0,
            size: min(limit, pageSize),
            sort: .addedOn,
            descending: true,
            search: trimmed
        )

        let needle = trimmed.lowercased()
        let context = catalogMapperContext(libraryId: libraryId)
        return page.content
            .map { BookloreCatalogMapper.book(from: $0, context: context) }
            .filter { book in
                let fields: [String?] = [book.title, book.author, book.narrator, book.series]
                return fields.contains { $0?.lowercased().contains(needle) == true }
            }
    }

    private func fetchRemoteBrowsePage(
        libraryId: String,
        page: Int,
        size: Int,
        sort: GrimmoryRemoteSort,
        descending: Bool,
        search: String?
    ) async throws -> BooklorePage<BookloreBookSummary> {
        let data = try await fetchRemoteBrowsePageData(
            libraryId: libraryId,
            page: page,
            size: size,
            sort: sort,
            descending: descending,
            search: search
        )
        return try JSONDecoder().decode(BooklorePage<BookloreBookSummary>.self, from: data)
    }

    private func fetchRemoteBrowsePageData(
        libraryId: String,
        page: Int,
        size: Int,
        sort: GrimmoryRemoteSort,
        descending: Bool,
        search: String?
    ) async throws -> Data {
        guard supportsRemoteBrowsing else { throw ProviderError.notImplemented }

        var queryItems = [
            URLQueryItem(name: "libraryId", value: libraryId),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "size", value: String(size)),
            URLQueryItem(name: "sort", value: sort.rawValue),
            URLQueryItem(name: "dir", value: descending ? "desc" : "asc"),
        ]
        if let search {
            queryItems.append(URLQueryItem(name: "search", value: search))
        }

        let request = try makeRequest(path: "/api/v1/app/books", queryItems: queryItems)
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Mobile app books returned HTTP \(response.statusCode)")
        }
        try guardJSON(data, response: response, endpoint: "/api/v1/app/books")
        return data
    }

    private func makeCompanionAudiobooks(forEbooks ebooks: inout [Book]) -> [Book] {
        var companions: [Book] = []
        for index in ebooks.indices {
            let ebook = ebooks[index]
            guard ebook.mediaType == .ebook,
                ebook.hasAlternateFormat,
                ebook.epub3Features?.hasMediaOverlay != true,
                !ebook.id.hasPrefix(Self.companionAudiobookIDPrefix)
            else { continue }

            let audiobookStableId = "grimmory:\(connection.id.uuidString):\(Self.companionAudiobookIDPrefix + ebook.id)"

            ebooks[index].linkedAudiobookStableId = audiobookStableId
            ebooks[index].hasAlternateFormat = false

            companions.append(makeCompanionAudiobook(forEbook: ebook))
        }
        return companions
    }

    private func makeCompanionAudiobook(forEbook ebook: Book) -> Book {
        let audiobookId = Self.companionAudiobookIDPrefix + ebook.id
        let ebookStableId = "grimmory:\(connection.id.uuidString):\(ebook.id)"

        var audiobook = Book(
            id: audiobookId,
            title: ebook.title,
            author: ebook.author,
            authors: ebook.authors,
            narrator: nil,
            seriesInfo: ebook.seriesInfo,
            duration: nil,
            coverURL: absoluteURL(
                from: fallbackCoverPath(for: ebook.id, mediaType: .audiobook),
                mediaType: .audiobook
            ),
            mediaType: .audiobook,
            hideFromContinue: false,
            description: ebook.description,
            genres: ebook.genres,
            publisher: ebook.publisher,
            currentTime: 0,
            isFinished: false,
            lastUpdate: ebook.lastUpdate,
            libraryId: ebook.libraryId,
            providerId: connection.id,
            source: .booklore,
            rawMetadata: nil,
            filePath: nil,
            publishedYear: ebook.publishedYear,
            personalRating: ebook.personalRating,
            goodreadsRating: ebook.goodreadsRating
        )
        audiobook.linkedAudiobookStableId = ebookStableId
        return audiobook
    }

    func fetchBooksDelta(libraryId: String, since: Date) async throws -> (books: [Book], cursor: Date)? {
        if useLegacyRestAPI || useLegacyCatalogFallback || useKomgaFallback {
            return nil
        }

        var page = 0
        var collected: [Book] = []
        var maxSeen: Date = since
        let context = catalogMapperContext(libraryId: libraryId)

        while true {
            let request = try makeRequest(
                path: "/api/v1/app/books",
                queryItems: [
                    URLQueryItem(name: "libraryId", value: libraryId),
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "size", value: String(pageSize)),
                    URLQueryItem(name: "sort", value: "addedOn"),
                    URLQueryItem(name: "dir", value: "desc"),
                ]
            )
            let (data, response): (Data, HTTPURLResponse)
            do {
                (data, response) = try await performAuthorizedRequest(request)
            } catch {
                return nil
            }
            guard response.statusCode == 200 else { return nil }
            do {
                try guardJSON(data, response: response, endpoint: "/api/v1/app/books")
            } catch { return nil }

            let result: BooklorePage<BookloreBookSummary>
            do {
                result = try JSONDecoder().decode(BooklorePage<BookloreBookSummary>.self, from: data)
            } catch { return nil }

            if result.content.isEmpty { break }

            var pageHadNew = false
            var pageMaxSeen: Date = .distantPast
            for summary in result.content {
                guard let addedDate = summary.addedOn?.date else { continue }
                if addedDate > pageMaxSeen { pageMaxSeen = addedDate }
                if addedDate > since {
                    collected.append(BookloreCatalogMapper.book(from: summary, context: context))
                    pageHadNew = true
                }
            }
            if pageMaxSeen > maxSeen { maxSeen = pageMaxSeen }

            if !pageHadNew { break }
            if !result.hasNext { break }
            page += 1
        }

        AppLogger.network.info("[Booklore] Delta: \(collected.count) new books since \(since)")
        return (collected, maxSeen)
    }

    func fetchRecentBooks(libraryId: String, limit: Int) async throws -> [Book] {
        if useLegacyRestAPI {
            let all = (try? await fetchBooksViaLegacyAPI(libraryId: libraryId)) ?? []
            return Array(all.prefix(limit))
        }
        if useKomgaFallback {
            return try await fetchRecentBooksViaKomga(libraryId: libraryId, limit: limit)
        }

        let request = try makeRequest(
            path: "/api/v1/app/books",
            queryItems: [
                URLQueryItem(name: "libraryId", value: libraryId),
                URLQueryItem(name: "page", value: "0"),
                URLQueryItem(name: "size", value: String(min(limit, pageSize))),
                URLQueryItem(name: "sort", value: "addedOn"),
                URLQueryItem(name: "dir", value: "desc"),
            ]
        )
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await performAuthorizedRequest(request)
        } catch {
            let all =
                (try? await switchToLegacyBooksAPI(
                    reason: "Recent books request failed (\(error.localizedDescription))",
                    libraryId: libraryId
                )) ?? []
            return Array(all.prefix(limit))
        }
        guard response.statusCode == 200 else {
            let all =
                (try? await switchToLegacyBooksAPI(reason: "Recent books returned HTTP \(response.statusCode)", libraryId: libraryId)) ?? []
            return Array(all.prefix(limit))
        }

        do {
            try guardJSON(data, response: response, endpoint: "/api/v1/app/books")
        } catch {
            let all = (try? await switchToLegacyBooksAPI(reason: "Recent books returned non-JSON/HTML", libraryId: libraryId)) ?? []
            return Array(all.prefix(limit))
        }

        let result: BooklorePage<BookloreBookSummary>
        do {
            result = try JSONDecoder().decode(BooklorePage<BookloreBookSummary>.self, from: data)
        } catch {
            let all = (try? await switchToLegacyBooksAPI(reason: "Recent books decode failed", libraryId: libraryId)) ?? []
            return Array(all.prefix(limit))
        }

        if result.content.isEmpty {
            let all = (try? await switchToLegacyBooksAPI(reason: "Recent books returned empty page", libraryId: libraryId)) ?? []
            return Array(all.prefix(limit))
        }

        let context = catalogMapperContext(libraryId: libraryId)
        var books = result.content.map { BookloreCatalogMapper.book(from: $0, context: context) }
        let audiobookIndices = books.indices.filter { books[$0].mediaType == .audiobook }
        if !audiobookIndices.isEmpty {
            await withTaskGroup(of: (Int, Book).self) { group in
                for idx in audiobookIndices {
                    let book = books[idx]
                    group.addTask {
                        let enriched = await self.enrichListedAudiobook(book)
                        return (idx, enriched)
                    }
                }
                for await (idx, enriched) in group {
                    books[idx] = enriched
                }
            }
        }

        return books
    }

    private struct GrimmoryShelfSummary: Decodable {
        let id: Int
        let name: String
        let icon: String?
        let bookCount: Int?
        let publicShelf: Bool?

        private enum CodingKeys: String, CodingKey {
            case id, name, icon, bookCount, numberOfBooks, publicShelf
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            icon = try container.decodeIfPresent(String.self, forKey: .icon)
            bookCount =
                try container.decodeIfPresent(Int.self, forKey: .bookCount)
                ?? container.decodeIfPresent(Int.self, forKey: .numberOfBooks)
            publicShelf = try container.decodeIfPresent(Bool.self, forKey: .publicShelf)
        }
    }

    private struct GrimmoryMagicShelfSummary: Decodable {
        let id: Int
        let name: String
    }

    private func fetchShelfSummaries() async throws -> [GrimmoryShelfSummary] {
        var lastError: Error = ProviderError.invalidResponse

        for path in ["/api/v1/app/shelves", "/api/v1/shelves"] {
            do {
                let request = try makeRequest(path: path)
                let (data, response) = try await performAuthorizedRequest(request)
                guard response.statusCode == 200 else {
                    lastError = ProviderError.serverError("Shelf discovery returned HTTP \(response.statusCode)")
                    continue
                }
                do {
                    return try JSONDecoder().decode([GrimmoryShelfSummary].self, from: data)
                } catch {
                    lastError = error
                }
            } catch {
                lastError = error
            }
        }

        throw lastError
    }

    private func fetchMagicShelfSummaries() async throws -> [GrimmoryMagicShelfSummary] {
        var lastError: Error = ProviderError.invalidResponse

        for path in ["/api/v1/app/shelves/magic", "/api/magic-shelves"] {
            do {
                let request = try makeRequest(path: path)
                let (data, response) = try await performAuthorizedRequest(request)
                guard response.statusCode == 200 else {
                    lastError = ProviderError.serverError("Magic Shelf discovery returned HTTP \(response.statusCode)")
                    continue
                }
                do {
                    return try JSONDecoder().decode([GrimmoryMagicShelfSummary].self, from: data)
                } catch {
                    lastError = error
                }
            } catch {
                lastError = error
            }
        }

        throw lastError
    }

    func fetchCollections(libraryId: String?) async throws -> [Collection] {
        guard !useLegacyRestAPI, !useKomgaFallback else {
            throw ProviderError.notImplemented
        }

        let shelves = try await fetchShelfSummaries()

        let regularShelves: [Collection] = try await withThrowingTaskGroup(of: (Int, [String]).self) { group in
            for shelf in shelves {
                group.addTask {
                    let ids = try await self.fetchShelfBookIds(
                        shelfId: shelf.id,
                        expectedBookCount: shelf.bookCount
                    )
                    return (shelf.id, ids)
                }
            }
            var bookIdsByShelf: [Int: [String]] = [:]
            for try await (shelfId, ids) in group {
                bookIdsByShelf[shelfId] = ids
            }
            return shelves.map { shelf in
                let ids = bookIdsByShelf[shelf.id] ?? []
                return Collection(
                    id: String(shelf.id),
                    name: shelf.name,
                    description: nil,
                    books: ids,
                    bookCount: ids.count,
                    iconName: "books.vertical",
                    color: "purple",
                    providerId: connection.id
                )
            }
        }

        let magicShelves = try await fetchMagicShelfSummaries()
        let magicCollections: [Collection] = try await withThrowingTaskGroup(of: (Int, [String]).self) { group in
            for shelf in magicShelves {
                group.addTask {
                    (shelf.id, try await self.fetchMagicShelfBookIds(shelfId: shelf.id))
                }
            }
            var bookIdsByShelf: [Int: [String]] = [:]
            for try await (shelfId, ids) in group {
                bookIdsByShelf[shelfId] = ids
            }
            return magicShelves.map { shelf in
                let ids = bookIdsByShelf[shelf.id] ?? []
                return Collection(
                    id: "magic-\(shelf.id)",
                    name: shelf.name,
                    description: "Magic Shelf",
                    books: ids,
                    bookCount: ids.count,
                    iconName: "wand.and.stars",
                    color: "indigo",
                    providerId: connection.id
                )
            }
        }

        var seenCollectionIds = Set<String>()
        return (regularShelves + magicCollections).filter {
            seenCollectionIds.insert("\($0.providerId?.uuidString ?? "")-\($0.id)").inserted
        }
    }

    private func fetchFilteredBookIds(filterName: String, filterId: Int) async throws -> [String] {
        let request = try makeRequest(
            path: "/api/v1/app/books/ids",
            queryItems: [URLQueryItem(name: filterName, value: String(filterId))]
        )
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError(
                "Book ID lookup for \(filterName) \(filterId) returned HTTP \(response.statusCode)"
            )
        }
        return uniqueBookIds(
            try JSONDecoder().decode([FlexibleID].self, from: data).map(\.stringValue)
        )
    }

    private func fetchMagicShelfBookIds(shelfId: Int) async throws -> [String] {
        do {
            return try await fetchFilteredBookIds(filterName: "magicShelfId", filterId: shelfId)
        } catch {
            AppLogger.network.warning(
                "[Booklore] Magic Shelf \(shelfId) all-ID lookup failed; trying paginated membership: \(error.localizedDescription)"
            )
        }

        return try await fetchAllLegacyMagicShelfBookIds(shelfId: shelfId)
    }

    private func fetchAllLegacyMagicShelfBookIds(shelfId: Int) async throws -> [String] {
        var page = 0
        let pageSize = 500
        var allIds: [String] = []
        var seenIds = Set<String>()

        while true {
            let result = try await fetchLegacyMagicShelfBookIds(
                shelfId: shelfId,
                page: page,
                size: pageSize
            )
            let newIds = result.ids.filter { seenIds.insert($0).inserted }
            allIds.append(contentsOf: newIds)
            if !result.hasNext { break }
            if newIds.isEmpty {
                throw ProviderError.serverError(
                    "Magic Shelf \(shelfId) returned a repeated page before membership completed"
                )
            }
            page += 1
            if page > 1000 {
                throw ProviderError.serverError("Magic Shelf \(shelfId) membership exceeded 1000 pages")
            }
        }

        return allIds
    }

    private func fetchLegacyMagicShelfBookIds(
        shelfId: Int,
        page: Int,
        size: Int
    ) async throws -> (ids: [String], hasNext: Bool) {
        struct AppBook: Decodable {
            let id: FlexibleID
        }
        struct PageResponse: Decodable {
            let content: [AppBook]
            let page: Int?
            let totalPages: Int?
            let hasNext: Bool?
        }

        let request = try makeRequest(
            path: "/api/v1/app/shelves/magic/\(shelfId)/books",
            queryItems: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "size", value: String(size)),
            ]
        )
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError(
                "Magic Shelf \(shelfId) membership returned HTTP \(response.statusCode)"
            )
        }
        let result = try JSONDecoder().decode(PageResponse.self, from: data)
        let hasNext = result.hasNext ?? ((result.page ?? page) + 1 < (result.totalPages ?? 1))
        return (result.content.map(\.id.stringValue), hasNext)
    }

    private func fetchShelfBookIds(shelfId: Int, expectedBookCount: Int?) async throws -> [String] {
        var membershipCandidates: [[String]] = []

        func accepts(_ ids: [String]) -> Bool {
            guard let expectedBookCount else { return true }
            return ids.count == expectedBookCount
        }

        do {
            let ids = try await fetchFilteredBookIds(filterName: "shelfId", filterId: shelfId)
            membershipCandidates.append(ids)
            if accepts(ids) { return ids }
            AppLogger.network.warning(
                "[Booklore] Shelf \(shelfId) all-ID lookup returned \(ids.count) books; expected \(expectedBookCount ?? 0), trying direct membership"
            )
        } catch {
            AppLogger.network.warning(
                "[Booklore] Shelf \(shelfId) all-ID lookup failed; trying direct membership: \(error.localizedDescription)"
            )
        }

        do {
            let directIds = try await fetchLegacyShelfBookIds(shelfId: shelfId)
            membershipCandidates.append(directIds)
            if accepts(directIds) { return directIds }
            AppLogger.network.warning(
                "[Booklore] Shelf \(shelfId) direct membership returned \(directIds.count) books; expected \(expectedBookCount ?? 0), trying paginated app books"
            )
        } catch {
            AppLogger.network.warning(
                "[Booklore] Shelf \(shelfId) direct membership failed; trying paginated app books: \(error.localizedDescription)"
            )
        }

        do {
            let paginatedIds = try await fetchPaginatedShelfBookIds(shelfId: shelfId)
            membershipCandidates.append(paginatedIds)
            if accepts(paginatedIds) { return paginatedIds }
        } catch {
            AppLogger.network.warning(
                "[Booklore] Shelf \(shelfId) paginated membership failed: \(error.localizedDescription)"
            )
        }

        let returnedCounts = membershipCandidates.map(\.count)
        throw ProviderError.serverError(
            "Shelf \(shelfId) reports \(expectedBookCount.map(String.init) ?? "an unknown number of") books, but membership endpoints returned \(returnedCounts)"
        )
    }

    private func fetchPaginatedShelfBookIds(shelfId: Int) async throws -> [String] {
        struct ShelfBookPage: Decodable {
            let content: [ShelfBookEntry]
            let hasNext: Bool?
            struct ShelfBookEntry: Decodable { let id: FlexibleID }
        }

        var page = 0
        let pageSize = 500
        var ids: [String] = []

        while true {
            let request = try makeRequest(
                path: "/api/v1/app/books",
                queryItems: [
                    URLQueryItem(name: "shelfId", value: String(shelfId)),
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "size", value: String(pageSize)),
                ]
            )
            let (data, response) = try await performAuthorizedRequest(request)
            guard response.statusCode == 200 else {
                throw ProviderError.serverError(
                    "Shelf \(shelfId) app membership returned HTTP \(response.statusCode) on page \(page)"
                )
            }
            let result = try JSONDecoder().decode(ShelfBookPage.self, from: data)
            ids.append(contentsOf: result.content.map { $0.id.stringValue })
            if result.hasNext != true { break }
            page += 1
            if page > 1000 {
                throw ProviderError.serverError("Shelf \(shelfId) membership exceeded 1000 pages")
            }
        }
        return uniqueBookIds(ids)
    }

    private func fetchLegacyShelfBookIds(shelfId: Int) async throws -> [String] {
        struct ShelfBook: Decodable { let id: FlexibleID }

        let request = try makeRequest(path: "/api/v1/shelves/\(shelfId)/books")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError(
                "Shelf \(shelfId) direct membership returned HTTP \(response.statusCode)"
            )
        }
        let books = try JSONDecoder().decode([ShelfBook].self, from: data)
        return uniqueBookIds(books.map { $0.id.stringValue })
    }

    private func uniqueBookIds(_ ids: [String]) -> [String] {
        var seenIds = Set<String>()
        return ids.filter { !$0.isEmpty && seenIds.insert($0).inserted }
    }

    func fetchSeries(libraryId: String) async throws -> [Series] {
        let books = try await fetchBooks(libraryId: libraryId)

        var seriesMap: [String: (bookIds: [String], sequences: [String: String])] = [:]
        for book in books {
            guard let info = book.seriesInfo, !info.name.isEmpty else { continue }
            var entry = seriesMap[info.name] ?? (bookIds: [], sequences: [:])
            entry.bookIds.append(book.id)
            if let seq = info.sequence {
                entry.sequences[book.id] = seq
            }
            seriesMap[info.name] = entry
        }

        return seriesMap.map { name, data in
            Series(
                id: "grimmory-series-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))",
                name: name,
                description: nil,
                books: data.bookIds,
                bookSequences: data.sequences,
                bookCount: data.bookIds.count,
                libraryId: libraryId,
                providerId: connection.id
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func fetchUserMediaProgress(libraryId: String) async throws -> [UserMediaProgress] { return [] }

    func fetchFullBookDetails(bookId: String, libraryId: String) async throws -> Book {

        let isCompanionAudiobook = bookId.hasPrefix(Self.companionAudiobookIDPrefix)
        let bookId =
            isCompanionAudiobook
            ? String(bookId.dropFirst(Self.companionAudiobookIDPrefix.count))
            : bookId

        func finalize(_ base: Book) async -> Book {
            var resolved = isCompanionAudiobook ? makeCompanionAudiobook(forEbook: base) : base
            if resolved.mediaType == .ebook,
                resolved.epub3Features == nil,
                let features = await fetchEPUB3Features(bookId: bookId)
            {
                resolved.epub3Features = features
            }
            return await enrichAudiobookIfNeeded(resolved)
        }

        if useLegacyRestAPI {
            let request = try makeRequest(path: "/api/v1/libraries/\(libraryId)/book/\(bookId)")
            let (data, response) = try await performAuthorizedRequest(request)
            guard response.statusCode == 200 else {
                throw ProviderError.serverError("Failed to fetch book (HTTP \(response.statusCode))")
            }
            let book = try JSONDecoder().decode(BookloreLegacyBook.self, from: data)
            return await finalize(BookloreCatalogMapper.book(from: book, context: catalogMapperContext(libraryId: libraryId)))
        }
        if useKomgaFallback {
            let request = try makeKomgaBasicRequest(path: "/komga/api/v1/books/\(bookId)")
            let (data, response) = try await send(request)
            guard response.statusCode == 200 else {
                throw ProviderError.serverError("Failed to fetch book (HTTP \(response.statusCode))")
            }
            let book = try JSONDecoder().decode(KomgaBook.self, from: data)
            return await finalize(mapKomgaBookToBook(book, libraryId: libraryId))
        }

        func fetchAppStyleDetail(path: String) async throws -> BookloreBookDetail {
            let request = try makeRequest(path: path)
            let (data, response) = try await performAuthorizedRequest(request)
            guard response.statusCode == 200 else {
                throw ProviderError.serverError("Failed to fetch book details (HTTP \(response.statusCode))")
            }
            try guardJSON(data, response: response, endpoint: path)
            return try JSONDecoder().decode(BookloreBookDetail.self, from: data)
        }

        if let detail = try? await fetchAppStyleDetail(path: "/api/v1/app/books/\(bookId)") {
            return await finalize(mapToBook(detail, fallbackLibraryId: libraryId))
        }

        if let detail = try? await fetchAppStyleDetail(path: "/api/v1/books/\(bookId)") {
            return await finalize(mapToBook(detail, fallbackLibraryId: libraryId))
        }

        AppLogger.network.info("[Booklore] Full book details app endpoints unavailable - falling back to legacy detail endpoint")
        let request = try makeRequest(path: "/api/v1/libraries/\(libraryId)/book/\(bookId)")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch book (HTTP \(response.statusCode))")
        }
        let book = try JSONDecoder().decode(BookloreLegacyBook.self, from: data)
        return await finalize(BookloreCatalogMapper.book(from: book, context: catalogMapperContext(libraryId: libraryId)))
    }

    func fetchEPUB3Features(bookId: String) async -> EPUB3Features? {
        guard !useKomgaFallback else { return nil }
        let bookId =
            bookId.hasPrefix(Self.companionAudiobookIDPrefix)
            ? String(bookId.dropFirst(Self.companionAudiobookIDPrefix.count))
            : bookId

        struct EpubInfo: Decodable {
            struct Item: Decodable {
                let href: String?
                let mediaType: String?
            }
            let manifest: [Item]?
            let metadata: [String: String]?
        }

        do {
            let request = try makeRequest(path: "/api/v1/epub/\(bookId)/info")
            let (data, response) = try await performAuthorizedRequest(request)
            guard response.statusCode == 200 else { return nil }
            let info = try JSONDecoder().decode(EpubInfo.self, from: data)

            let smilCount = (info.manifest ?? []).filter { item in
                item.mediaType?.localizedCaseInsensitiveContains("smil") == true
                    || item.href?.lowercased().hasSuffix(".smil") == true
            }.count
            guard smilCount > 0 || info.metadata?["media:duration"] != nil else { return nil }

            return EPUB3Features(hasMediaOverlay: true, hasFixedLayout: false, smilFileCount: smilCount)
        } catch {
            return nil
        }
    }

    private struct GrimmoryEpubStreamInfo: Decodable {
        struct ManifestItem: Decodable {
            let href: String?
            let mediaType: String?
            let size: Int64?
        }
        let containerPath: String?
        let manifest: [ManifestItem]?
    }

    func makeEpubStreamingSession(for book: Book) async throws -> GrimmoryEpubStreamingSession {
        guard !useKomgaFallback, !useLegacyRestAPI else {
            throw ProviderError.notImplemented
        }
        guard let bookId = resolveGrimmoryBookId(for: book) else {
            throw ProviderError.invalidResponse
        }
        let resource = try await resolveGrimmoryEPUBResource(for: book)
        let queryItems =
            (resource?.isPrimary ?? true)
            ? []
            : [URLQueryItem(name: "bookType", value: "EPUB")]

        let request = try makeRequest(path: "/api/v1/epub/\(bookId)/info", queryItems: queryItems)
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Grimmory EPUB streaming unavailable (HTTP \(response.statusCode))")
        }
        let info = try JSONDecoder().decode(GrimmoryEpubStreamInfo.self, from: data)

        var entries: [GrimmoryEpubStreamingSession.Entry] = []
        var seen = Set<String>()
        func addEntry(_ path: String?, mediaType: String?, size: Int64?) {
            guard let path, !path.isEmpty, !path.contains(".."), seen.insert(path).inserted else { return }
            entries.append(.init(path: path, mediaType: mediaType, size: UInt64(max(size ?? 0, 0))))
        }
        addEntry("META-INF/container.xml", mediaType: "application/xml", size: nil)
        addEntry(info.containerPath, mediaType: "application/oebps-package+xml", size: nil)
        for item in info.manifest ?? [] {
            addEntry(item.href, mediaType: item.mediaType, size: item.size)
        }
        guard entries.count > 2 else {
            throw ProviderError.invalidResponse
        }
        let hasOverlaySMIL = entries.contains {
            $0.path.lowercased().hasSuffix(".smil") || $0.mediaType?.localizedCaseInsensitiveContains("smil") == true
        }
        guard !hasOverlaySMIL else {

            throw ProviderError.notImplemented
        }

        let cacheDirName = resource.map { "book-\(book.id)-file-\($0.fileId)" } ?? "book-\(book.id)"
        let cacheRoot = LocalEbookImporter.shared.streamedEpubCacheRoot
            .appendingPathComponent(connection.id.uuidString, isDirectory: true)
            .appendingPathComponent(cacheDirName, isDirectory: true)

        return GrimmoryEpubStreamingSession(
            entries: entries,
            cacheRoot: cacheRoot,
            fetchRemote: { path in
                try await self.fetchEpubStreamResource(bookId: bookId, path: path, queryItems: queryItems)
            }
        )
    }

    private func fetchEpubStreamResource(
        bookId: Int,
        path: String,
        queryItems: [URLQueryItem]
    ) async throws -> Data {
        let encodedPath =
            path
            .split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        let request = try makeRequest(path: "/api/v1/epub/\(bookId)/file/\(encodedPath)", queryItems: queryItems)
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to stream EPUB resource (HTTP \(response.statusCode))")
        }
        return data
    }

    func fetchFilePath(bookId: String) async -> String? {
        guard !useKomgaFallback else { return nil }
        let bookId =
            bookId.hasPrefix(Self.companionAudiobookIDPrefix)
            ? String(bookId.dropFirst(Self.companionAudiobookIDPrefix.count))
            : bookId
        do {
            let request = try makeRequest(path: "/api/v1/books/\(bookId)")
            let (data, response) = try await performAuthorizedRequest(request)
            guard response.statusCode == 200 else { return nil }

            struct FilePathResponse: Decodable {
                let primaryFile: BooklorePrimaryFile?
            }
            let decoded = try JSONDecoder().decode(FilePathResponse.self, from: data)
            return decoded.primaryFile?.filePath
        } catch {
            AppLogger.network.error("[Booklore] fetchFilePath failed for book \(bookId): \(error.localizedDescription)")
            return nil
        }
    }

    private func enrichAudiobookIfNeeded(_ baseBook: Book) async -> Book {
        guard baseBook.mediaType == .audiobook else {
            return baseBook
        }

        var enriched = baseBook
        let streamHeaders = getStreamingHeaders()
        var sessionTracks: [AudioTrackInfo] = []

        if let session = try? await startPlaybackSession(for: baseBook) {
            sessionTracks = session.audioTracks
            let trackDuration = session.audioTracks.reduce(0.0) { partial, track in
                partial + max(track.duration, 0)
            }
            let resolvedDuration = max(enriched.duration ?? 0, trackDuration)
            if resolvedDuration > 0 {
                enriched.duration = resolvedDuration
                if enriched.currentTime > resolvedDuration {
                    enriched.currentTime = resolvedDuration
                }
            }

            let normalizedSessionChapters = BookloreBookMapper.normalizeChapters(
                session.chapters,
                bookDuration: enriched.duration ?? resolvedDuration
            )
            if !normalizedSessionChapters.isEmpty {
                enriched.chapters = normalizedSessionChapters
            }

            if BookloreBookMapper.chaptersAreInadequate(enriched.chapters ?? [], bookDuration: enriched.duration ?? resolvedDuration),
                session.audioTracks.count > 1
            {
                let synthesized: [Chapter] = session.audioTracks.enumerated().map { index, track in
                    let start = max(track.startOffset, 0)
                    let end = start + max(track.duration, 0)
                    let title = track.title ?? "Track \(index + 1)"
                    return Chapter(
                        id: "grimmory_track_\(track.index)",
                        start: start,
                        end: end,
                        title: title,
                        index: index
                    )
                }
                if !synthesized.isEmpty {
                    enriched.chapters = BookloreBookMapper.normalizeChapters(synthesized, bookDuration: enriched.duration ?? resolvedDuration)
                }
            }
        }

        if let streamURL = getAudioURL(for: enriched) {
            let chapterDuration = enriched.duration ?? 0
            if sessionTracks.count <= 1,
                BookloreBookMapper.chaptersAreInadequate(enriched.chapters ?? [], bookDuration: chapterDuration),
                let extractedChapters = await MetadataLayeringManager.shared.extractEmbeddedChapters(
                    from: streamURL,
                    headers: streamHeaders
                ),
                !extractedChapters.isEmpty
            {
                let bookloreChapters = extractedChapters.enumerated().map { index, chapter in
                    Chapter(
                        id: "grimmory-embedded-\(index)",
                        start: chapter.start,
                        end: chapter.end,
                        title: chapter.title,
                        index: index
                    )
                }
                enriched.chapters = BookloreBookMapper.normalizeChapters(bookloreChapters, bookDuration: chapterDuration)
                AppLogger.network.info("Extracted \(extractedChapters.count) embedded chapters from Grimmory stream")
            }

            let needsMetadataBackfill =
                (enriched.author?.isEmpty ?? true)
                || enriched.author == "Unknown Author"
                || enriched.narrator == nil
                || (enriched.description?.isEmpty ?? true)
                || enriched.series == nil
                || enriched.publisher == nil
                || enriched.publishedYear == nil
                || (enriched.genres?.isEmpty ?? true)
                || (enriched.duration ?? 0) <= 0

            if needsMetadataBackfill,
                sessionTracks.count <= 1,
                let embedded = try? await FileMetadataExtractor.shared.extractMetadataFromRemoteStream(
                    streamURL: streamURL,
                    headers: streamHeaders,
                    timeout: 15.0
                )
            {
                if let embeddedTitle = embedded.title,
                    !embeddedTitle.isEmpty,
                    enriched.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || enriched.title == enriched.series
                {
                    enriched.title = embeddedTitle
                }
                if let embeddedAuthor = embedded.author,
                    !embeddedAuthor.isEmpty,
                    (enriched.author?.isEmpty ?? true) || enriched.author == "Unknown Author"
                {
                    enriched.author = embeddedAuthor
                }
                if let embeddedNarrator = embedded.narrator,
                    !embeddedNarrator.isEmpty,
                    enriched.narrator?.isEmpty ?? true
                {
                    enriched.narrator = embeddedNarrator
                }
                if let embeddedDescription = embedded.description,
                    !embeddedDescription.isEmpty,
                    enriched.description?.isEmpty ?? true
                {
                    enriched.description = embeddedDescription
                }
                if let embeddedSeries = embedded.series,
                    !embeddedSeries.isEmpty,
                    enriched.series?.isEmpty ?? true
                {
                    enriched.series = embeddedSeries
                }
                if let embeddedSeriesNumber = embedded.seriesNumber,
                    enriched.seriesNumber == nil
                {
                    enriched.seriesNumber = embeddedSeriesNumber
                }
                if let embeddedYear = embedded.year,
                    enriched.publishedYear == nil
                {
                    enriched.publishedYear = embeddedYear
                }
                if let embeddedGenres = embedded.genres,
                    !embeddedGenres.isEmpty,
                    enriched.genres?.isEmpty ?? true
                {
                    enriched.genres = embeddedGenres
                }
                if let embeddedPublisher = embedded.publisher,
                    !embeddedPublisher.isEmpty,
                    enriched.publisher?.isEmpty ?? true
                {
                    enriched.publisher = embeddedPublisher
                }
                if let embeddedISBN = embedded.isbn,
                    !embeddedISBN.isEmpty,
                    enriched.isbn?.isEmpty ?? true
                {
                    enriched.isbn = embeddedISBN
                }
                if let embeddedASIN = embedded.asin,
                    !embeddedASIN.isEmpty,
                    enriched.asin?.isEmpty ?? true
                {
                    enriched.asin = embeddedASIN
                }
                if let embeddedDuration = embedded.duration,
                    embeddedDuration > 0,
                    (enriched.duration ?? 0) <= 0
                {
                    enriched.duration = embeddedDuration
                }

                await MetadataManager.shared.recordStreamExtractedMetadata(for: enriched)
            }
        }

        return enriched
    }

    private func enrichListedAudiobook(_ book: Book) async -> Book {
        var enriched = book
        var detailProgressFraction: Double?

        if let detailReq = try? makeRequest(path: "/api/v1/app/books/\(grimmoryNumericId(book))"),
            let (detailData, detailResp) = try? await performAuthorizedRequest(detailReq),
            detailResp.statusCode == 200,
            let detail = try? JSONDecoder().decode(BookloreBookDetail.self, from: detailData)
        {
            enriched = mergeListedAudiobook(enriched, with: detail)
            detailProgressFraction = Book.normalizedFractionProgress(detail.audiobookProgress?.percentage)

            if let fraction = detailProgressFraction,
                let duration = enriched.duration,
                duration > 0
            {
                enriched.currentTime = duration * fraction
                enriched.isFinished = enriched.isFinished || fraction >= 0.99
                AppLogger.network.info(
                    "[Booklore] Enriching '\(book.title)': detail progress \(fraction * 100)%% -> currentTime \(enriched.currentTime)s (duration \(duration)s)"
                )
            } else {
                AppLogger.network.info(
                    "[Booklore] Enriching '\(book.title)': audiobookProgress=\(String(describing: detail.audiobookProgress?.percentage)), duration=\(String(describing: enriched.duration)) - currentTime not set yet"
                )
            }
        } else {
            AppLogger.network.warning("[Booklore] Enriching '\(book.title)': detail fetch failed or returned nil audiobookProgress")
        }

        if let info = try? await playbackClient.fetchInfo(
            bookId: grimmoryNumericId(book)
        ) {
            enriched = mergeListedAudiobook(enriched, with: info)
        } else {
            AppLogger.network.warning("[Booklore] Enriching '\(book.title)': info fetch failed - duration may be unset")
        }

        if let fraction = detailProgressFraction, fraction > 0,
            let duration = enriched.duration,
            duration > 0
        {
            let actualFraction = enriched.currentTime / duration

            if enriched.currentTime <= 0 || abs(actualFraction - fraction) > 0.02 {
                AppLogger.network.info(
                    "[Booklore] Correcting progress drift for '\(book.title)': was \(actualFraction * 100)%% (\(enriched.currentTime)s), expected \(fraction * 100)%%"
                )
                enriched.currentTime = duration * fraction
            }
        } else if detailProgressFraction != nil {
            AppLogger.network.warning(
                "[Booklore] Enriching '\(book.title)': could not set currentTime after info fetch - duration=\(String(describing: enriched.duration))"
            )
        }

        AppLogger.network.info(
            "[Booklore] Enriched '\(book.title)': finalCurrentTime=\(enriched.currentTime)s, duration=\(String(describing: enriched.duration))s"
        )
        return enriched
    }

    private func mergeListedAudiobook(_ book: Book, with detail: BookloreBookDetail) -> Book {
        var enriched = book
        let primaryFile = detail.files?.first(where: { $0.isPrimary == true }) ?? detail.files?.first
        let detailDuration = detail.durationSeconds.map(Double.init) ?? detail.duration

        if enriched.mediaType == .audiobook,
            let titleFromFile = BookloreBookMapper.title(fromPrimaryFileName: primaryFile?.fileName)
        {
            enriched.title = titleFromFile
        }

        if let detailAuthors = detail.authors, !detailAuthors.isEmpty,
            (enriched.author?.isEmpty ?? true) || enriched.author == "Unknown Author"
        {
            enriched.author = BookloreBookMapper.displayAuthor(from: detailAuthors)
            enriched.authors = detailAuthors
        }

        if let detailDuration, detailDuration > 0 {
            enriched.duration = max(enriched.duration ?? 0, detailDuration)
        }

        if let description = detail.description,
            !description.isEmpty,
            enriched.description?.isEmpty ?? true
        {
            enriched.description = description
        }

        if let publisher = detail.publisher,
            !publisher.isEmpty,
            enriched.publisher?.isEmpty ?? true
        {
            enriched.publisher = publisher
        }

        if let language = detail.language,
            !language.isEmpty,
            enriched.language?.isEmpty ?? true
        {
            enriched.language = language
        }

        if let libraryName = detail.libraryName,
            !libraryName.isEmpty,
            enriched.libraryName?.isEmpty ?? true
        {
            enriched.libraryName = libraryName
        }

        if let publishedYear = BookloreBookMapper.publishedYear(from: detail.publishedDate),
            enriched.publishedYear == nil
        {
            enriched.publishedYear = publishedYear
        }

        if let goodreadsRating = detail.goodreadsRating,
            enriched.goodreadsRating == nil
        {
            enriched.goodreadsRating = goodreadsRating
        }

        if let isbn13 = detail.isbn13,
            !isbn13.isEmpty,
            enriched.isbn?.isEmpty ?? true
        {
            enriched.isbn = isbn13
        }

        if let categories = detail.categories,
            !categories.isEmpty,
            enriched.genres?.isEmpty ?? true
        {
            enriched.genres = Array(categories).sorted { lhs, rhs in
                lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
        }

        let mappedDetailChapters = BookloreBookMapper.chapters(from: detail.chapters, bookDuration: enriched.duration ?? detailDuration ?? 0)
        if !mappedDetailChapters.isEmpty {
            enriched.chapters = mappedDetailChapters
        }

        let detailReadStatus = detail.readStatus?.uppercased()
        if detailReadStatus == "READ" {
            enriched.isFinished = true
        }
        enriched.hideFromContinue = BookloreBookMapper.statusSuppressesContinue(detailReadStatus)
        if let rs = detailReadStatus {
            enriched.serverReadStatus = rs
        }

        if let updatedAt = parseDate(detail.dateFinished) ?? parseDate(detail.lastReadTime) ?? parseDate(detail.addedOn) {
            enriched.lastUpdate = updatedAt
        }

        return enriched
    }

    private func mergeListedAudiobook(_ book: Book, with info: BookloreAudiobookInfo) -> Book {
        var enriched = book
        let previousDuration = enriched.duration ?? 0
        let progressFraction = previousDuration > 0 ? min(max(enriched.currentTime / previousDuration, 0), 1) : nil

        if let infoTitle = info.title,
            !infoTitle.isEmpty,
            enriched.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            enriched.title = infoTitle
        }

        if let infoAuthor = info.author,
            !infoAuthor.isEmpty,
            (enriched.author?.isEmpty ?? true) || enriched.author == "Unknown Author"
        {
            enriched.author = infoAuthor
        }

        if let narrator = info.narrator,
            !narrator.isEmpty
        {
            enriched.narrator = narrator
        }

        if let infoDuration = info.duration,
            infoDuration > 0
        {
            enriched.duration = infoDuration
            if let progressFraction {
                enriched.currentTime = infoDuration * progressFraction
            }
        }

        let mappedInfoChapters = BookloreBookMapper.chapters(from: info.chapters, bookDuration: enriched.duration ?? info.duration ?? 0)
        if !mappedInfoChapters.isEmpty {
            enriched.chapters = mappedInfoChapters
        }

        return enriched
    }

    private func mapToBook(_ detail: BookloreBookDetail, fallbackLibraryId: String) -> Book {
        let seriesInfo = BookloreBookMapper.normalizedSeriesInfo(name: detail.seriesName, sequence: detail.seriesNumber.map { String($0) })

        let primaryFile = detail.files?.first(where: { $0.isPrimary == true }) ?? detail.files?.first
        let resolvedType =
            resolvedFileType(file: primaryFile)
            ?? BookloreCatalogMapper.resolvedFileType(primaryFileType: detail.primaryFileType, primaryFile: detail.primaryFile)
        let mediaType = BookloreBookMapper.mediaType(from: resolvedType)

        let rawProgress: Double? =
            detail.readProgress
            ?? detail.audiobookProgress?.percentage
            ?? detail.epubProgress?.percentage
            ?? detail.pdfProgress?.percentage
        let readProg = Book.normalizedFractionProgress(rawProgress) ?? 0

        let duration: Double? = detail.durationSeconds.map { Double($0) } ?? detail.duration.flatMap { $0 > 0 ? $0 : nil }
        let fallbackThumbnail = fallbackCoverPath(for: detail.id.stringValue, mediaType: mediaType)
        let currentTime =
            mediaType == .audiobook && (duration ?? 0) > 0
            ? readProg * (duration ?? 0)
            : 0

        var resolvedTitle = detail.title
        if mediaType == .audiobook,
            let titleFromFile = BookloreBookMapper.title(fromPrimaryFileName: primaryFile?.fileName)
        {
            resolvedTitle = titleFromFile
        }

        let serverReadStatus = detail.readStatus?.uppercased()
        let isFinished = readProg >= 0.99 || serverReadStatus == "READ" || detail.dateFinished != nil
        let hideFromContinue = BookloreBookMapper.statusSuppressesContinue(serverReadStatus)

        let genres = detail.categories.map { Array($0) } ?? []

        let mappedChapters: [Chapter] =
            detail.chapters?.enumerated().map { (i, ch) in
                Chapter(
                    id: "grimmory_ch_\(i)",
                    start: ch.start ?? 0,
                    end: ch.end ?? (duration ?? 0),
                    title: ch.title ?? "Chapter \(i + 1)"
                )
            } ?? []

        let serverLocator: String?
        if detail.epubProgress != nil {
            serverLocator = nil
        } else if let page = detail.pdfProgress?.page {
            serverLocator = "{\"page\":\(page)}"
        } else {
            serverLocator = nil
        }

        let resolvedFilePath: String? =
            detail.primaryFile?.filePath
            ?? detail.files?.first(where: { $0.isPrimary == true })?.filePath
            ?? detail.files?.first?.filePath

        let readAloudTags = ["read aloud", "readaloud", "read-aloud"]
        var epub3Features: EPUB3Features? = nil
        if genres.contains(where: { tag in readAloudTags.contains(tag.lowercased()) }) {
            epub3Features = EPUB3Features(hasMediaOverlay: true, hasFixedLayout: false, smilFileCount: 1)
        }

        let bookId = detail.id.stringValue
        let author = BookloreBookMapper.displayAuthor(from: detail.authors)
        let detailAuthors: [String]? = detail.authors
        let cover =
            absoluteURL(from: detail.thumbnailUrl, mediaType: mediaType)
            ?? absoluteURL(from: fallbackThumbnail, mediaType: mediaType)

        let lastUpdate =
            parseDate(detail.dateFinished)
            ?? parseDate(detail.lastReadTime)
            ?? parseDate(detail.addedOn)
            ?? Date()

        let libId = detail.libraryId?.stringValue ?? fallbackLibraryId
        let ebProgress = mediaType == .ebook ? readProg : nil
        let backendId = connection.id.uuidString

        var result = Book(
            id: bookId,
            title: resolvedTitle,
            author: author,
            authors: detailAuthors,
            narrator: nil,
            seriesInfo: seriesInfo,
            duration: duration,
            coverURL: cover,
            mediaType: mediaType,
            epubLocator: serverLocator,
            ebookProgress: ebProgress,
            hideFromContinue: hideFromContinue,
            dateAdded: parseDate(detail.addedOn),
            description: detail.description,
            genres: genres,
            chapters: mappedChapters,
            publisher: detail.publisher,
            currentTime: currentTime,
            isFinished: isFinished,
            lastUpdate: lastUpdate,
            libraryId: libId,
            providerId: connection.id,
            backendId: backendId,
            source: .booklore,
            rawMetadata: nil,
            filePath: resolvedFilePath,
            epub3Features: epub3Features,
            publishedYear: BookloreBookMapper.publishedYear(from: detail.publishedDate),
            personalRating: detail.personalRating.map { $0 / 2 },
            goodreadsRating: detail.goodreadsRating
        )
        if mediaType == .ebook {
            result.ebookFormat = BookloreBookMapper.normalizedEbookFormat(resolvedType)
        }
        result.serverReadStatus = serverReadStatus
        return result
    }

    private func fetchGrimmorySyncDetail(bookId: Int) async throws -> BookloreSyncBookDetail {
        let request = try makeRequest(path: "/api/v1/app/books/\(bookId)")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw ProviderError.unauthorized
            }
            throw ProviderError.serverError(
                "Failed to resolve Grimmory ebook files (HTTP \(response.statusCode))"
            )
        }
        return try JSONDecoder().decode(BookloreSyncBookDetail.self, from: data)
    }

    private func selectedGrimmoryEPUBResource(
        for book: Book,
        bookId: Int,
        detail: BookloreSyncBookDetail
    ) throws -> GrimmoryEbookResource? {
        let declaredFormat = BookloreBookMapper.normalizedEbookFormat(book.ebookFormat)
        if let declaredFormat, declaredFormat != EbookFormat.epub.rawValue {
            return nil
        }

        let files = detail.files ?? []
        if let cached = cachedEbookResources[book.id],
            cached.bookId == bookId,
            files.contains(where: {
                $0.id?.stringValue == String(cached.fileId) && isEPUBFile($0)
            })
        {
            return cached
        }
        let primaryFile = files.first(where: { $0.isPrimary == true }) ?? files.first
        if declaredFormat == nil, let primaryFile, !isEPUBFile(primaryFile) {
            return nil
        }

        let epubFiles = files.filter(isEPUBFile)
        guard
            let selected = epubFiles.first(where: { $0.isPrimary == true })
                ?? epubFiles.first,
            let rawFileId = selected.id?.stringValue,
            let fileId = Int(rawFileId),
            fileId > 0
        else {
            throw ProviderError.serverError("No EPUB file is available for this Grimmory book")
        }

        return GrimmoryEbookResource(
            bookId: bookId,
            fileId: fileId,
            isPrimary: selected.isPrimary == true,
            fileName: selected.fileName
        )
    }

    private func cacheGrimmoryResource(
        _ resource: GrimmoryEbookResource,
        for book: Book
    ) {
        cachedEbookResources[book.id] = resource
    }

    private func resolveGrimmoryEPUBResource(
        for book: Book
    ) async throws -> GrimmoryEbookResource? {
        guard let bookId = resolveGrimmoryBookId(for: book) else {
            throw ProviderError.invalidResponse
        }
        let detail = try await fetchGrimmorySyncDetail(bookId: bookId)
        let resource = try selectedGrimmoryEPUBResource(
            for: book,
            bookId: bookId,
            detail: detail
        )
        if let resource {
            cacheGrimmoryResource(resource, for: book)
        }
        return resource
    }

    private func grimmoryResourceCacheIdentifier(
        for book: Book,
        resource: GrimmoryEbookResource
    ) -> String {
        "grimmory-\(connection.id.uuidString)-\(book.id)-file-\(resource.fileId)"
    }

    func downloadEbook(for book: Book, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let resource = try await resolveGrimmoryEPUBResource(for: book)
        let cacheIdentifier =
            resource.map {
                grimmoryResourceCacheIdentifier(for: book, resource: $0)
            } ?? book.id
        let expectedExtension = resource == nil
            ? BookloreBookMapper.normalizedEbookFormat(book.ebookFormat)
            : EbookFormat.epub.rawValue

        if let cached = LocalEbookImporter.shared.cachedEbook(forBookId: cacheIdentifier) {
            if expectedExtension == nil || cached.pathExtension.lowercased() == expectedExtension {
                AppLogger.network.info("Using cached ebook for \(book.title) (\(book.id))")
                onProgress?(1)
                return cached
            }
            try? LocalEbookImporter.shared.deleteRemoteEbookArtifacts(forBookId: cacheIdentifier)
        }

        AppLogger.network.info("Downloading ebook: \(book.title) (\(book.id))")
        let downloadPath: String
        if let resource {
            downloadPath =
                resource.isPrimary
                ? "/api/v1/books/\(resource.bookId)/download"
                : "/api/v1/books/\(resource.bookId)/files/\(resource.fileId)/download"
        } else {
            downloadPath = "/api/v1/books/\(book.id)/download"
        }
        let request = try makeRequest(path: downloadPath)
        let (localURL, httpResponse) = try await performAuthorizedDownload(request, onProgress: onProgress)
        guard httpResponse.statusCode == 200 else {
            throw ProviderError.serverError("Failed to download ebook (HTTP \(httpResponse.statusCode))")
        }

        let ext = EbookFormat.detectedExtension(inDownloadResponse: httpResponse) ?? expectedExtension ?? "epub"
        let safeTitle =
            resource?.fileName
            .map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            ?? book.title.replacingOccurrences(of: "/", with: "-")
        AppLogger.network.info("Downloaded ebook: \(book.title) (\(ext), \(localURL.lastPathComponent))")
        let cachedURL = try LocalEbookImporter.shared.cacheRemoteEbook(
            tempURL: localURL,
            preferredFilename: "\(safeTitle).\(ext)",
            bookIdentifier: cacheIdentifier
        )
        onProgress?(1)
        return cachedURL
    }

    nonisolated static let companionAudiobookIDPrefix = "grimmory-ab-"

    nonisolated func grimmoryNumericId(_ book: Book) -> String {
        if book.id.hasPrefix(Self.companionAudiobookIDPrefix) {
            return String(book.id.dropFirst(Self.companionAudiobookIDPrefix.count))
        }
        return book.id
    }

    private func resolveGrimmoryBookId(for book: Book) -> Int? {
        if let directId = Int(grimmoryNumericId(book)), directId > 0 {
            return directId
        }

        guard let sourceStableId = book.readAloudSourceStableId,
            let sourceIdPart = sourceStableId.split(separator: ":").last,
            let sourceBookId = Int(sourceIdPart),
            sourceBookId > 0
        else {
            return nil
        }

        AppLogger.network.debug(
            "[Booklore] Resolved Read Aloud source bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
        )
        return sourceBookId
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
        guard !useLegacyRestAPI, !useKomgaFallback else {
            AppLogger.network.debug(
                "[Booklore] Ebook progress push unsupported for active API tier bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
            )
            return
        }

        if book.epub3Features?.hasMediaOverlay == true {
            AppLogger.network.debug(
                "[Booklore] Syncing reading position only for media-overlay bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
            )
        }

        guard let bookId = resolveGrimmoryBookId(for: book) else {
            AppLogger.network.error(
                "[Booklore] Ebook progress push skipped; invalid bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
            )
            return
        }

        let resource = try await resolveGrimmoryEPUBResource(for: book)
        try await progressClient.updateEbookProgress(
            for: book,
            bookId: bookId,
            resourceFileId: resource?.fileId,
            progress: progress,
            epubLocator: epubLocator,
            sourceEngine: sourceEngine
        )
    }

    func uploadEbookReadingSession(
        for book: Book,
        startDate: Date,
        startProgress: Double,
        endProgress: Double,
        epubLocator: String?
    ) async throws {
        guard !useLegacyRestAPI, !useKomgaFallback else { return }
        guard let bookId = resolveGrimmoryBookId(for: book) else { return }
        try await readingSessionClient.uploadEbookSession(
            for: book,
            bookId: bookId,
            startDate: startDate,
            startProgress: startProgress,
            endProgress: endProgress,
            locator: epubLocator
        )
    }

    enum GrimmoryReadStatus: String {
        case reading = "READING"
        case abandoned = "ABANDONED"
    }

    func updateReadStatus(for book: Book, status: GrimmoryReadStatus) async throws {
        guard !useLegacyRestAPI, !useKomgaFallback else {
            throw ProviderError.notImplemented
        }

        struct StatusRequest: Encodable {
            let status: String
        }

        var request = try makeRequest(path: "/api/v1/app/books/\(grimmoryNumericId(book))/status", method: "PUT")
        request.httpBody = try JSONEncoder().encode(StatusRequest(status: status.rawValue))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await performAuthorizedRequest(request)
        guard (200...204).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to update Grimmory read status (HTTP \(response.statusCode))")
        }

        AppLogger.network.info("Updated read status to \(status.rawValue) for \(book.title)")
    }

    func updatePersonalRating(for book: Book, rating: Int) async throws {
        guard supportsPersonalRating else {
            throw ProviderError.notImplemented
        }
        guard let numericId = Int(grimmoryNumericId(book)) else {
            throw ProviderError.serverError("Unrecognized Grimmory book id")
        }

        struct RatingRequest: Encodable {
            let ids: [Int]
            let rating: Int
        }

        var request = try makeRequest(path: "/api/v1/books/personal-rating", method: "PUT")
        request.httpBody = try JSONEncoder().encode(RatingRequest(ids: [numericId], rating: min(max(rating, 1), 5) * 2))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await performAuthorizedRequest(request)
        guard (200...204).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to update Grimmory rating (HTTP \(response.statusCode))")
        }
    }

    func fetchNotebookEntries(for book: Book) async throws -> [AppNotebookEntry] {
        guard !useLegacyRestAPI, !useKomgaFallback else { return [] }

        var entries: [AppNotebookEntry] = []
        var pageIndex = 0
        while true {
            let request = try makeRequest(
                path: "/api/v1/app/notebook/books/\(grimmoryNumericId(book))/entries",
                queryItems: [
                    URLQueryItem(name: "page", value: String(pageIndex)),
                    URLQueryItem(name: "size", value: "200"),
                ]
            )
            let (data, response) = try await performAuthorizedRequest(request)
            guard response.statusCode == 200 else { return entries }
            let page = try JSONDecoder().decode(NotebookEntriesPage.self, from: data)
            entries.append(contentsOf: page.content)
            guard page.hasNext == true else { break }
            pageIndex += 1
        }
        return entries
    }

    func fetchRemoteAnnotations(for book: Book) async throws -> [RemoteAnnotationRecord] {
        guard !useLegacyRestAPI, !useKomgaFallback else { return [] }

        let request = try makeRequest(path: "/api/v1/annotations/book/\(grimmoryNumericId(book))")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else { return [] }
        return try JSONDecoder().decode([RemoteAnnotationRecord].self, from: data)
    }

    func fetchRemoteBookmarks(for book: Book) async throws -> [RemoteBookmarkRecord] {
        guard !useLegacyRestAPI, !useKomgaFallback else { return [] }

        let request = try makeRequest(path: "/api/v1/bookmarks/book/\(grimmoryNumericId(book))")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else { return [] }
        return try JSONDecoder().decode([RemoteBookmarkRecord].self, from: data)
    }

    func fetchBookNotes(for book: Book) async throws -> [RemoteBookNoteRecord] {
        guard !useLegacyRestAPI, !useKomgaFallback else { return [] }

        let request = try makeRequest(path: "/api/v2/book-notes/book/\(grimmoryNumericId(book))")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else { return [] }
        return try JSONDecoder().decode([RemoteBookNoteRecord].self, from: data)
    }

    func createRemoteBookmark(
        for book: Book,
        title: String?,
        note: String?,
        locator: String?,
        color: String? = nil,
        priority: Int? = nil,
        positionMs: Int? = nil,
        trackIndex: Int? = nil
    ) async throws -> RemoteBookmarkRecord {
        guard !useLegacyRestAPI, !useKomgaFallback else {
            throw ProviderError.notImplemented
        }

        struct BookmarkCreateRequest: Encodable {
            let bookId: Int
            let title: String?
            let cfi: String?
            let positionMs: Int?
            let trackIndex: Int?
        }

        var request = try makeRequest(path: "/api/v1/bookmarks", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            BookmarkCreateRequest(
                bookId: Int(grimmoryNumericId(book)) ?? 0,
                title: title,
                cfi: EpubLocationBridge.epubCFIForProviderUpload(from: locator),
                positionMs: positionMs,
                trackIndex: trackIndex
            )
        )
        let (data, response) = try await performAuthorizedRequest(request)
        guard (200...201).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to create Grimmory bookmark (HTTP \(response.statusCode))")
        }
        let created = try JSONDecoder().decode(RemoteBookmarkRecord.self, from: data)

        guard note != nil || color != nil || priority != nil else { return created }

        struct BookmarkUpdateRequest: Encodable {
            let notes: String?
            let color: String?
            let priority: Int?
        }

        var updateRequest = try makeRequest(path: "/api/v1/bookmarks/\(created.id)", method: "PUT")
        updateRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        updateRequest.httpBody = try JSONEncoder().encode(
            BookmarkUpdateRequest(notes: note, color: color, priority: priority)
        )
        let (updateData, updateResponse) = try await performAuthorizedRequest(updateRequest)
        guard updateResponse.statusCode == 200 else {

            AppLogger.network.warning(
                "[Grimmory] Bookmark \(created.id) created but note/color/priority update returned HTTP \(updateResponse.statusCode)"
            )
            return created
        }
        return try JSONDecoder().decode(RemoteBookmarkRecord.self, from: updateData)
    }

    func deleteRemoteBookmark(id: Int) async throws {
        guard !useLegacyRestAPI, !useKomgaFallback else { return }
        let request = try makeRequest(path: "/api/v1/bookmarks/\(id)", method: "DELETE")
        let (_, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 204 || response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to delete Grimmory bookmark (HTTP \(response.statusCode))")
        }
    }

    func createRemoteAnnotation(for book: Book, annotation: ReaderAnnotation) async throws -> RemoteAnnotationRecord {
        guard !useLegacyRestAPI, !useKomgaFallback else {
            throw ProviderError.notImplemented
        }

        struct AnnotationCreateRequest: Encodable {
            let bookId: Int
            let cfi: String?
            let text: String
            let color: String
            let style: String
            let note: String?
            let chapterTitle: String?
        }

        guard let cfi = EpubLocationBridge.epubCFIForProviderUpload(from: annotation.locator) else {
            throw ProviderError.noCFI
        }

        var request = try makeRequest(path: "/api/v1/annotations", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            AnnotationCreateRequest(
                bookId: Int(grimmoryNumericId(book)) ?? 0,
                cfi: cfi,
                text: annotation.text,
                color: annotation.colorHex,
                style: annotation.style.rawValue,
                note: annotation.note,
                chapterTitle: annotation.chapterTitle
            )
        )

        let (data, response) = try await performAuthorizedRequest(request)
        guard (200...201).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to create Grimmory annotation (HTTP \(response.statusCode))")
        }
        return try JSONDecoder().decode(RemoteAnnotationRecord.self, from: data)
    }

    func updateRemoteAnnotation(id: Int, annotation: ReaderAnnotation) async throws -> RemoteAnnotationRecord {
        guard !useLegacyRestAPI, !useKomgaFallback else {
            throw ProviderError.notImplemented
        }

        struct AnnotationUpdateRequest: Encodable {
            let color: String
            let style: String
            let note: String?
        }

        var request = try makeRequest(path: "/api/v1/annotations/\(id)", method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            AnnotationUpdateRequest(
                color: annotation.colorHex,
                style: annotation.style.rawValue,
                note: annotation.note
            )
        )

        let (data, response) = try await performAuthorizedRequest(request)
        guard (200...201).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to update Grimmory annotation (HTTP \(response.statusCode))")
        }
        return try JSONDecoder().decode(RemoteAnnotationRecord.self, from: data)
    }

    func deleteRemoteAnnotation(id: Int) async throws {
        guard !useLegacyRestAPI, !useKomgaFallback else { return }
        let request = try makeRequest(path: "/api/v1/annotations/\(id)", method: "DELETE")
        let (_, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 204 || response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to delete Grimmory annotation (HTTP \(response.statusCode))")
        }
    }

    func createBookNote(
        for book: Book,
        cfi: String?,
        selectedText: String,
        noteContent: String,
        color: String = "#00FF00",
        chapterTitle: String? = nil
    ) async throws -> RemoteBookNoteRecord {
        guard !useLegacyRestAPI, !useKomgaFallback else {
            throw ProviderError.notImplemented
        }

        struct BookNoteCreateRequest: Encodable {
            let bookId: Int
            let cfi: String?
            let selectedText: String
            let noteContent: String
            let color: String
            let chapterTitle: String?
        }

        var request = try makeRequest(path: "/api/v2/book-notes", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            BookNoteCreateRequest(
                bookId: Int(grimmoryNumericId(book)) ?? 0,
                cfi: cfi,
                selectedText: selectedText,
                noteContent: noteContent,
                color: color,
                chapterTitle: chapterTitle
            )
        )

        let (data, response) = try await performAuthorizedRequest(request)
        guard (200...201).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to create Grimmory book note (HTTP \(response.statusCode))")
        }
        return try JSONDecoder().decode(RemoteBookNoteRecord.self, from: data)
    }

    func fetchEbookProgressState(for book: Book) async throws -> ProviderEbookProgress? {
        guard !useLegacyRestAPI, !useKomgaFallback else { return nil }

        guard let bookId = resolveGrimmoryBookId(for: book) else { return nil }
        let detail = try await fetchGrimmorySyncDetail(bookId: bookId)
        let resource = try selectedGrimmoryEPUBResource(
            for: book,
            bookId: bookId,
            detail: detail
        )
        if let resource {
            cacheGrimmoryResource(resource, for: book)
        }
        return try await progressClient.fetchEbookProgress(
            for: book,
            bookId: bookId,
            context: BookloreProgressClient.EbookProgressContext(
                hasEpubResource: resource != nil,
                readProgress: detail.readProgress,
                readStatus: detail.readStatus,
                lastReadTime: detail.lastReadTime,
                pdfProgress: detail.pdfProgress.map {
                    BookloreProgressClient.EbookProgressContext.PageProgress(
                        page: $0.page,
                        percentage: $0.percentage,
                        updatedAt: $0.updatedAt
                    )
                },
                cbxProgress: detail.cbxProgress.map {
                    BookloreProgressClient.EbookProgressContext.PageProgress(
                        page: $0.page,
                        percentage: $0.percentage,
                        updatedAt: $0.updatedAt
                    )
                }
            )
        )
    }

    func fetchEbookProgress(for book: Book) async throws -> (progress: Double, locator: String?, updatedAt: Date?, isAbandoned: Bool)? {
        guard let result = try await fetchEbookProgressState(for: book) else { return nil }
        return (result.progress, result.locator, result.updatedAt, result.readState.isAbandoned)
    }

    func fetchAudiobookProgressState(for book: Book) async throws -> ProviderAudiobookProgress? {
        guard !useLegacyRestAPI, !useKomgaFallback else { return nil }
        return await progressClient.fetchAudiobookProgress(
            for: book,
            bookId: grimmoryNumericId(book)
        )
    }

    func fetchAudiobookProgress(
        for book: Book
    ) async throws -> (positionSeconds: TimeInterval, percentage: Double, trackIndex: Int?, updatedAt: Date?, isAbandoned: Bool)? {
        guard let result = try await fetchAudiobookProgressState(for: book) else { return nil }
        return (
            result.positionSeconds,
            result.percentage,
            result.trackIndex,
            result.updatedAt,
            result.readState.isAbandoned
        )
    }

    private func mediaURL(path: String) -> URL? {
        let base = normalize(connection.url)
        guard var components = URLComponents(string: "\(base)\(path)") else {
            return nil
        }
        if let token = connection.token, !token.isEmpty {
            var queryItems = components.queryItems ?? []
            queryItems.removeAll { $0.name == "token" }
            queryItems.append(URLQueryItem(name: "token", value: token))
            components.queryItems = queryItems
        }
        return components.url
    }

    func getAudioURL(for book: Book) -> URL? {
        mediaURL(path: "/api/v1/audiobooks/\(grimmoryNumericId(book))/stream")
    }

    func getAudioTrackURL(for book: Book, trackIndex: Int) -> URL? {
        mediaURL(path: "/api/v1/audiobooks/\(grimmoryNumericId(book))/track/\(trackIndex)/stream")
    }

    func getStreamingHeaders() -> [String: String] {
        var headers: [String: String] = [:]
        if let customHeaders = connection.customHeaders {
            for (key, value) in customHeaders {
                headers[key] = value
            }
        }
        return headers
    }

    private func fetchBookDetailForPlayback(bookId: String) async -> BookloreBookDetail? {
        if let request = try? makeRequest(path: "/api/v1/app/books/\(bookId)"),
            let (data, response) = try? await performAuthorizedRequest(request),
            response.statusCode == 200,
            let detail = try? JSONDecoder().decode(BookloreBookDetail.self, from: data)
        {
            return detail
        }

        if let request = try? makeRequest(path: "/api/v1/books/\(bookId)"),
            let (data, response) = try? await performAuthorizedRequest(request),
            response.statusCode == 200,
            let detail = try? JSONDecoder().decode(BookloreBookDetail.self, from: data)
        {
            return detail
        }

        return nil
    }

    private func isLikelyAudioFile(_ file: BookloreBookFile) -> Bool {
        let ext = (file.fileExtension ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["mp3", "m4a", "m4b", "mp4", "aac", "flac", "ogg", "oga", "opus", "wav"].contains(ext) {
            return true
        }
        let type = (file.bookType ?? "").lowercased()
        return type.contains("audio") || type.contains("audiobook")
    }

    private func isEPUBFile(_ file: BookloreBookFile) -> Bool {
        let candidates = [
            file.fileExtension,
            file.fileType,
            file.bookType,
            file.fileName.map { URL(fileURLWithPath: $0).pathExtension },
            file.filePath.map { URL(fileURLWithPath: $0).pathExtension },
        ]
        return
            candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains("epub")
    }

    func startPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo {
        let mapping = try await playbackClient.fetchMapping(
            bookId: grimmoryNumericId(book)
        ) { index in
            getAudioTrackURL(for: book, trackIndex: index)
        }
        var tracks = mapping?.tracks ?? []
        var chapters = mapping?.chapters ?? []
        var serverDuration = mapping?.duration ?? 0
        let infoBookFileId = mapping?.bookFileId

        if tracks.count <= 1,
            let detail = await fetchBookDetailForPlayback(bookId: grimmoryNumericId(book))
        {
            if let fileId = (detail.files?.first(where: { $0.isPrimary == true }) ?? detail.files?.first)?.id?.stringValue,
                let intId = Int(fileId), intId > 0
            {
                progressClient.cacheAudiobookFileId(intId, for: book.id)
            }

            let detailDuration = detail.durationSeconds.map(Double.init) ?? detail.duration ?? 0
            let totalDuration = max(serverDuration, detailDuration)
            let audioFiles = (detail.files ?? []).filter { isLikelyAudioFile($0) }

            if audioFiles.count > 1 {
                let sortedFiles = audioFiles.sorted { lhs, rhs in
                    let l = lhs.fileName ?? ""
                    let r = rhs.fileName ?? ""
                    return l.localizedStandardCompare(r) == .orderedAscending
                }

                let fallbackPerTrackDuration =
                    totalDuration > 0
                    ? totalDuration / Double(sortedFiles.count)
                    : 3600

                var rebuiltTracks: [AudioTrackInfo] = []
                var rebuiltChapters: [Chapter] = []
                var offset: Double = 0

                for (index, file) in sortedFiles.enumerated() {
                    guard let streamURL = getAudioTrackURL(for: book, trackIndex: index)?.absoluteString,
                        !streamURL.isEmpty
                    else {
                        continue
                    }

                    let title =
                        file.fileName.map {
                            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
                        } ?? "Chapter \(index + 1)"

                    rebuiltTracks.append(
                        AudioTrackInfo(
                            index: index,
                            startOffset: offset,
                            duration: fallbackPerTrackDuration,
                            contentUrl: streamURL,
                            mimeType: AudiobookFormat.streamingMimeType(forFileExtension: file.fileExtension),
                            title: title
                        )
                    )

                    if chapters.isEmpty {
                        rebuiltChapters.append(
                            Chapter(
                                id: "grimmory_file_\(index)",
                                start: offset,
                                end: offset + fallbackPerTrackDuration,
                                title: title,
                                index: index
                            )
                        )
                    }

                    offset += fallbackPerTrackDuration
                }

                if !rebuiltTracks.isEmpty {
                    tracks = rebuiltTracks
                    if chapters.isEmpty {
                        chapters = rebuiltChapters
                    }
                    if serverDuration <= 0 {
                        serverDuration = totalDuration
                    }
                }
            }

            let hasFolderBasedFile = (detail.files ?? []).contains { $0.folderBased == true }
            if tracks.count <= 1, hasFolderBasedFile,
                let probed = await probeMultiTrackURLs(for: book)
            {
                var probedTracks: [AudioTrackInfo] = []
                var probedChapters: [Chapter] = []
                var offset: Double = 0
                for (index, entry) in probed.enumerated() {
                    let title = "Track \(index + 1)"
                    probedTracks.append(
                        AudioTrackInfo(
                            index: index,
                            startOffset: offset,
                            duration: entry.duration,
                            contentUrl: entry.url.absoluteString,
                            mimeType: entry.mimeType,
                            title: title
                        )
                    )
                    if chapters.isEmpty {
                        probedChapters.append(
                            Chapter(
                                id: "grimmory_probe_\(index)",
                                start: offset,
                                end: offset + entry.duration,
                                title: title,
                                index: index
                            )
                        )
                    }
                    offset += entry.duration
                }
                if !probedTracks.isEmpty {
                    tracks = probedTracks
                    if chapters.isEmpty { chapters = probedChapters }
                    if serverDuration <= 0 { serverDuration = offset }
                }
            }
        }

        if tracks.isEmpty {
            let url = getAudioURL(for: book)?.absoluteString ?? ""
            tracks.append(
                AudioTrackInfo(
                    index: 0,
                    startOffset: 0,
                    duration: serverDuration,
                    contentUrl: url,
                    mimeType: "audio/mp4"
                )
            )
        }

        AppLogger.network.info(
            "[Grimmory] Playback session: \(tracks.count) track(s), \(chapters.count) chapter(s), duration: \(serverDuration)s"
        )
        if let fileId = infoBookFileId, fileId > 0 {
            progressClient.cacheAudiobookFileId(fileId, for: book.id)
        }

        let resolvedBookFileId = progressClient.cachedAudiobookFileId(for: book.id) ?? Int(grimmoryNumericId(book)) ?? 0
        return PlaybackSessionInfo(
            sessionId: "grimmory_\(grimmoryNumericId(book))_\(resolvedBookFileId)",
            audioTracks: tracks,
            chapters: chapters,

            serverCurrentTime: nil
        )
    }

    func fetchAudiobookDownloadTracks(for book: Book) async -> [(url: URL, mimeType: String)]? {
        await playbackClient.fetchDownloadTracks(
            bookId: grimmoryNumericId(book)
        ) { index in
            getAudioTrackURL(for: book, trackIndex: index)
        }
    }

    func makeTrackProbeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        addAuthHeaders(&request)
        return request
    }

    private func probeMultiTrackURLs(for book: Book) async -> [(url: URL, mimeType: String, duration: TimeInterval)]? {
        var tracks: [(url: URL, mimeType: String, duration: TimeInterval)] = []
        let streamHeaders = getStreamingHeaders()
        // AVURLAsset cannot use the transport session, so headers have to ride on the asset options.
        let assetOptions: [String: Any]? = streamHeaders.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": streamHeaders]

        for index in 0..<300 {
            guard let trackURL = getAudioTrackURL(for: book, trackIndex: index),
                let (_, http) = try? await performAuthorizedRequest(makeTrackProbeRequest(url: trackURL)),
                (200...299).contains(http.statusCode)
            else {
                break
            }

            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "audio/mpeg"

            let asset = AVURLAsset(url: trackURL, options: assetOptions)
            let assetDuration: TimeInterval
            if let cmDuration = try? await asset.load(.duration) {
                let seconds = CMTimeGetSeconds(cmDuration)
                assetDuration = seconds.isFinite && seconds > 0 ? seconds : 0
            } else {
                assetDuration = 0
            }
            tracks.append((url: trackURL, mimeType: contentType, duration: assetDuration))
        }

        AppLogger.network.info(
            "[Grimmory] Probed \(tracks.count) track(s) bookId=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
        )
        return tracks.count > 1 ? tracks : nil
    }

    func updatePlaybackProgress(
        book: Book,
        sessionId: String?,
        currentTime: TimeInterval,
        isFinished: Bool,
        timeListened: TimeInterval
    ) async throws {
        guard !useLegacyRestAPI, !useKomgaFallback else { return }

        guard let duration = book.duration, duration > 0 else { return }
        let progress = try await progressClient.updateAudiobookProgress(
            for: book,
            bookId: grimmoryNumericId(book),
            sessionId: sessionId,
            currentTime: currentTime,
            duration: duration,
            isFinished: isFinished
        )

        if timeListened > 0 {
            do {
                try await uploadReadingSession(
                    for: book,
                    currentTime: currentTime,
                    duration: duration,
                    timeListened: timeListened
                )
            } catch {
                AppLogger.network.error(
                    "Failed to sync reading session bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)): \(error.localizedDescription)"
                )
            }
        }

        AppLogger.network.debug(
            "[Booklore] Synced playback progress bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) percentage=\(Int(progress * 100))"
        )
    }

    private func uploadReadingSession(
        for book: Book,
        currentTime: TimeInterval,
        duration: TimeInterval,
        timeListened: TimeInterval
    ) async throws {
        guard let bookId = Int(grimmoryNumericId(book)), bookId > 0 else { return }
        try await readingSessionClient.uploadAudiobookSession(
            for: book,
            bookId: bookId,
            currentTime: currentTime,
            duration: duration,
            timeListened: timeListened
        )
    }

    func fetchCurrentUser() async throws -> GrimmoryUser {
        let request = try makeRequest(path: "/api/v1/users/me")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch user (HTTP \(response.statusCode))")
        }

        if let user = try? JSONDecoder().decode(GrimmoryUser.self, from: data) {
            return user
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return GrimmoryUser(
                id: json["id"] as? Int,
                username: json["username"] as? String ?? json["name"] as? String,
                email: json["email"] as? String,
                roles: json["roles"] as? [String],
                permissions: nil,
                name: json["name"] as? String
            )
        }
        throw ProviderError.decodingFailed
    }

    func fetchGrimmoryShelves() async throws -> [GrimmoryShelf] {
        guard !useLegacyRestAPI, !useKomgaFallback else { return [] }
        return try await fetchShelfSummaries().map {
            GrimmoryShelf(
                id: $0.id,
                name: $0.name,
                bookCount: $0.bookCount,
                icon: $0.icon,
                publicShelf: $0.publicShelf
            )
        }
    }

    func fetchReadingSessions(limit: Int = 20) async throws -> [GrimmoryReadingSessionEntry] {
        guard !useLegacyRestAPI, !useKomgaFallback else { return [] }

        let activeBooks = ((try? await fetchRecentBooks(limit: 25)) ?? []).filter { $0.lastReadTime != nil }
        guard !activeBooks.isEmpty else { return [] }
        return await readingSessionClient.fetchSessions(
            bookIds: activeBooks.map(\.bookId),
            limit: limit
        )
    }

    private func fetchBooksFromStableCatalogForStats() async throws -> [GrimmoryRecentBook] {
        let request = try makeRequest(path: "/api/v1/books")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else { return [] }

        struct CatalogPrimaryFile: Decodable {
            let bookType: String?
            let fileName: String?
        }
        struct CatalogMetadata: Decodable {
            let title: String?
            let authors: [String]?
        }
        struct CatalogBook: Decodable {
            let id: FlexibleID
            let addedOn: String?
            let metadata: CatalogMetadata?
            let primaryFile: CatalogPrimaryFile?
        }

        guard let books = try? JSONDecoder().decode([CatalogBook].self, from: data) else {
            return []
        }

        let base = normalize(connection.url)
        return books.map { book in
            let mediaType = BookloreBookMapper.mediaType(from: book.primaryFile?.bookType)
            let fallbackPath = fallbackCoverPath(for: book.id.stringValue, mediaType: mediaType)
            let resolvedTitle =
                mediaType == .audiobook
                ? (BookloreBookMapper.title(fromPrimaryFileName: book.primaryFile?.fileName) ?? book.metadata?.title ?? "Unknown")
                : (book.metadata?.title ?? "Unknown")
            return GrimmoryRecentBook(
                bookId: Int(book.id.stringValue) ?? 0,
                title: resolvedTitle,
                author: BookloreBookMapper.displayAuthor(from: book.metadata?.authors),
                readProgress: nil,
                lastReadTime: book.addedOn,
                readStatus: nil,
                coverURL: "\(base)\(fallbackPath)"
            )
        }
    }

    func fetchRecentBooks(limit: Int = 10) async throws -> [GrimmoryRecentBook] {
        guard !useLegacyRestAPI, !useKomgaFallback else { return [] }

        func makeAppBooksRequest(sort: String) throws -> URLRequest {
            try makeRequest(
                path: "/api/v1/app/books",
                queryItems: [
                    URLQueryItem(name: "page", value: "0"),
                    URLQueryItem(name: "size", value: String(limit)),
                    URLQueryItem(name: "sort", value: sort),
                    URLQueryItem(name: "dir", value: "desc"),
                ]
            )
        }

        var (data, response) = try await performAuthorizedRequest(try makeAppBooksRequest(sort: "lastReadTime"))
        if response.statusCode != 200 {

            AppLogger.network.warning(
                "[Booklore] fetchRecentBooks: lastReadTime sort returned HTTP \(response.statusCode), retrying with addedOn sort"
            )
            let fallback = try await performAuthorizedRequest(try makeAppBooksRequest(sort: "addedOn"))
            if fallback.1.statusCode == 200 {
                (data, response) = fallback
            } else {
                return try await Array(fetchBooksFromStableCatalogForStats().prefix(limit))
            }
        }

        struct AppBook: Decodable {
            let id: FlexibleID
            let title: String?
            let authors: [String]?
            let authorNames: [String]?
            let readProgress: Double?
            let lastReadTime: String?
            let readStatus: String?
            let thumbnailUrl: String?
            let primaryFileType: String?
            let primaryFileName: String?
            let primaryFile: BooklorePrimaryFile?
        }
        struct PageResponse: Decodable { let content: [AppBook] }

        let books: [AppBook]
        if let page = try? JSONDecoder().decode(PageResponse.self, from: data) {
            books = page.content
        } else if let arr = try? JSONDecoder().decode([AppBook].self, from: data) {
            books = arr
        } else {
            return try await Array(fetchBooksFromStableCatalogForStats().prefix(limit))
        }

        let base = normalize(connection.url)
        return books.map { book in
            let resolvedType = BookloreCatalogMapper.resolvedFileType(primaryFileType: book.primaryFileType, primaryFile: book.primaryFile)
            let mediaType = BookloreBookMapper.mediaType(from: resolvedType)
            let fallbackPath = fallbackCoverPath(for: book.id.stringValue, mediaType: mediaType)
            let resolvedCoverURL =
                absoluteURL(from: book.thumbnailUrl, mediaType: mediaType)
                ?? absoluteURL(from: fallbackPath, mediaType: mediaType)
            let resolvedTitle =
                mediaType == .audiobook
                ? (BookloreBookMapper.title(fromPrimaryFileName: book.primaryFileName ?? book.primaryFile?.fileName) ?? book.title ?? "Unknown")
                : (book.title ?? "Unknown")
            return GrimmoryRecentBook(
                bookId: Int(book.id.stringValue) ?? 0,
                title: resolvedTitle,
                author: BookloreBookMapper.displayAuthor(from: book.authors ?? book.authorNames),
                readProgress: book.readProgress,
                lastReadTime: book.lastReadTime,
                readStatus: book.readStatus,
                coverURL: resolvedCoverURL?.absoluteString ?? "\(base)\(fallbackPath)"
            )
        }
    }

    func fetchAllBooksForStats() async throws -> [GrimmoryRecentBook] {
        guard !useLegacyRestAPI, !useKomgaFallback else { return [] }

        var page = 0
        var allBooks: [GrimmoryRecentBook] = []
        let base = normalize(connection.url)
        var attemptedStableFallback = false

        while true {
            let request = try makeRequest(
                path: "/api/v1/app/books",
                queryItems: [
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "size", value: "50"),
                    URLQueryItem(name: "sort", value: "lastReadTime"),
                    URLQueryItem(name: "dir", value: "desc"),
                ]
            )
            let (data, response) = try await performAuthorizedRequest(request)
            guard response.statusCode == 200 else {
                if !attemptedStableFallback {
                    attemptedStableFallback = true
                    return try await fetchBooksFromStableCatalogForStats()
                }
                break
            }

            struct AppBook: Decodable {
                let id: FlexibleID
                let title: String?
                let authors: [String]?
                let authorNames: [String]?
                let readProgress: Double?
                let lastReadTime: String?
                let readStatus: String?
                let thumbnailUrl: String?
                let primaryFileType: String?
                let primaryFileName: String?
                let primaryFile: BooklorePrimaryFile?
            }
            struct PageResponse: Decodable {
                let content: [AppBook]
                let last: Bool?
                let hasNext: Bool?
            }

            guard let pageResp = try? JSONDecoder().decode(PageResponse.self, from: data) else {
                if !attemptedStableFallback {
                    attemptedStableFallback = true
                    return try await fetchBooksFromStableCatalogForStats()
                }
                break
            }
            if pageResp.content.isEmpty { break }

            allBooks.append(
                contentsOf: pageResp.content.map { book in
                    let resolvedType = BookloreCatalogMapper.resolvedFileType(primaryFileType: book.primaryFileType, primaryFile: book.primaryFile)
                    let mediaType = BookloreBookMapper.mediaType(from: resolvedType)
                    let fallbackPath = fallbackCoverPath(for: book.id.stringValue, mediaType: mediaType)
                    let resolvedCoverURL =
                        absoluteURL(from: book.thumbnailUrl, mediaType: mediaType)
                        ?? absoluteURL(from: fallbackPath, mediaType: mediaType)
                    let resolvedTitle =
                        mediaType == .audiobook
                        ? (BookloreBookMapper.title(fromPrimaryFileName: book.primaryFileName ?? book.primaryFile?.fileName) ?? book.title ?? "Unknown")
                        : (book.title ?? "Unknown")
                    return GrimmoryRecentBook(
                        bookId: Int(book.id.stringValue) ?? 0,
                        title: resolvedTitle,
                        author: BookloreBookMapper.displayAuthor(from: book.authors ?? book.authorNames),
                        readProgress: book.readProgress,
                        lastReadTime: book.lastReadTime,
                        readStatus: book.readStatus,
                        coverURL: resolvedCoverURL?.absoluteString ?? "\(base)\(fallbackPath)"
                    )
                }
            )

            if pageResp.last == true || pageResp.hasNext == false { break }
            page += 1
            if page > 50 { break }
        }
        return allBooks
    }

    func fetchUsers() async throws -> [GrimmoryManagedUser] {
        let request = try makeRequest(path: "/api/v1/users")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            if response.statusCode == 403 { throw ProviderError.unauthorized }
            throw ProviderError.serverError("Failed to fetch users (HTTP \(response.statusCode))")
        }
        return (try? JSONDecoder().decode([GrimmoryManagedUser].self, from: data)) ?? []
    }

    func fetchUser(id: Int) async throws -> GrimmoryManagedUser {
        let request = try makeRequest(path: "/api/v1/users/\(id)")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            if response.statusCode == 403 { throw ProviderError.unauthorized }
            throw ProviderError.serverError("Failed to fetch user (HTTP \(response.statusCode))")
        }
        return try JSONDecoder().decode(GrimmoryManagedUser.self, from: data)
    }

    func createUser(_ request: GrimmoryCreateUserRequest) async throws {
        let body = try JSONEncoder().encode(request)
        let req = try makeRequest(
            path: "/api/v1/auth/register",
            method: "POST",
            body: body,
            contentType: "application/json"
        )
        let (_, response) = try await performAuthorizedRequest(req)
        guard (200...204).contains(response.statusCode) else {
            if response.statusCode == 403 { throw ProviderError.unauthorized }
            throw ProviderError.serverError("Failed to create user (HTTP \(response.statusCode))")
        }
    }

    func updateUser(id: Int, request: GrimmoryUpdateUserRequest) async throws {
        let body = try JSONEncoder().encode(request)
        let req = try makeRequest(
            path: "/api/v1/users/\(id)",
            method: "PUT",
            body: body,
            contentType: "application/json"
        )
        let (_, response) = try await performAuthorizedRequest(req)
        guard (200...204).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to update user (HTTP \(response.statusCode))")
        }
    }

    func deleteUser(id: Int) async throws {
        let req = try makeRequest(path: "/api/v1/users/\(id)", method: "DELETE")
        let (_, response) = try await performAuthorizedRequest(req)
        guard (200...204).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to delete user (HTTP \(response.statusCode))")
        }
    }

    func changeUserPassword(userId: Int, newPassword: String) async throws {
        struct Req: Encodable { let userId: Int; let newPassword: String }
        let body = try JSONEncoder().encode(Req(userId: userId, newPassword: newPassword))
        let req = try makeRequest(
            path: "/api/v1/users/change-user-password",
            method: "PUT",
            body: body,
            contentType: "application/json"
        )
        let (_, response) = try await performAuthorizedRequest(req)
        guard (200...204).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to change password (HTTP \(response.statusCode))")
        }
    }

    func createShelf(name: String, icon: String? = nil, isPublic: Bool = false) async throws -> GrimmoryShelf {
        struct Req: Encodable { let name: String; let icon: String?; let publicShelf: Bool }
        let body = try JSONEncoder().encode(Req(name: name, icon: icon, publicShelf: isPublic))
        let req = try makeRequest(
            path: "/api/v1/shelves",
            method: "POST",
            body: body,
            contentType: "application/json"
        )
        let (data, response) = try await performAuthorizedRequest(req)
        guard (200...201).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to create shelf (HTTP \(response.statusCode))")
        }
        return try JSONDecoder().decode(GrimmoryShelf.self, from: data)
    }

    func updateShelf(id: Int, name: String, icon: String? = nil, isPublic: Bool = false) async throws {
        struct Req: Encodable { let name: String; let icon: String?; let publicShelf: Bool }
        let body = try JSONEncoder().encode(Req(name: name, icon: icon, publicShelf: isPublic))
        let req = try makeRequest(
            path: "/api/v1/shelves/\(id)",
            method: "PUT",
            body: body,
            contentType: "application/json"
        )
        let (_, response) = try await performAuthorizedRequest(req)
        guard (200...204).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to update shelf (HTTP \(response.statusCode))")
        }
    }

    func deleteShelf(id: Int) async throws {
        let req = try makeRequest(path: "/api/v1/shelves/\(id)", method: "DELETE")
        let (_, response) = try await performAuthorizedRequest(req)
        guard (200...204).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to delete shelf (HTTP \(response.statusCode))")
        }
    }

    func updateShelfAssignments(bookIds: [Int], assign: [Int], unassign: [Int]) async throws {
        struct Req: Encodable { let bookIds: [Int]; let shelvesToAssign: [Int]; let shelvesToUnassign: [Int] }
        let body = try JSONEncoder().encode(Req(bookIds: bookIds, shelvesToAssign: assign, shelvesToUnassign: unassign))
        let req = try makeRequest(
            path: "/api/v1/books/shelves",
            method: "POST",
            body: body,
            contentType: "application/json"
        )
        let (_, response) = try await performAuthorizedRequest(req)
        guard (200...204).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to update shelf assignments (HTTP \(response.statusCode))")
        }
    }

    func fetchMagicShelves() async throws -> [GrimmoryMagicShelf] {
        let request = try makeRequest(path: "/api/magic-shelves")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else { return [] }
        return (try? JSONDecoder().decode([GrimmoryMagicShelf].self, from: data)) ?? []
    }

    func saveMagicShelf(_ shelf: GrimmoryMagicShelf) async throws -> GrimmoryMagicShelf {
        let body = try JSONEncoder().encode(shelf)
        let req = try makeRequest(
            path: "/api/magic-shelves",
            method: "POST",
            body: body,
            contentType: "application/json"
        )
        let (data, response) = try await performAuthorizedRequest(req)
        guard (200...201).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to save magic shelf (HTTP \(response.statusCode))")
        }
        return try JSONDecoder().decode(GrimmoryMagicShelf.self, from: data)
    }

    func deleteMagicShelf(id: Int) async throws {
        let req = try makeRequest(path: "/api/magic-shelves/\(id)", method: "DELETE")
        let (_, response) = try await performAuthorizedRequest(req)
        guard (200...204).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to delete magic shelf (HTTP \(response.statusCode))")
        }
    }

}

struct BookloreJWT {
    let exp: TimeInterval?

    static func normalizedToken(_ value: String) -> String? {
        var token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.lowercased().hasPrefix("bearer ") {
            token = String(token.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard token.split(separator: ".", omittingEmptySubsequences: false).count == 3 else { return nil }
        return token
    }

    init?(_ token: String) {
        guard let token = Self.normalizedToken(token) else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        exp = json["exp"] as? TimeInterval
    }

    func isExpiring(buffer: TimeInterval = 60) -> Bool {
        guard let exp else { return false }
        return Date().timeIntervalSince1970 >= exp - buffer
    }
}

final class BookloreTransport: @unchecked Sendable {
    private let session: URLSession
    private let authDelegate: BookloreAuthDelegate

    var credential: URLCredential { authDelegate.credential }
    var sessionHeaders: [AnyHashable: Any]? { session.configuration.httpAdditionalHeaders }

    init(connection: ServerConnection) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = [
            "User-Agent":
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        ]
        authDelegate = BookloreAuthDelegate(
            username: connection.username ?? "",
            password: connection.password ?? ""
        )
        session = URLSession(configuration: configuration, delegate: authDelegate, delegateQueue: nil)
    }

    func setCustomHeadersProvider(_ provider: @escaping () -> [String: String]?) {
        authDelegate.customHeadersProvider = provider
    }

    func makeRequest(
        connection: ServerConnection,
        path: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil,
        includeAuth: Bool = true,
        allowBasicFallback: Bool = false
    ) throws -> URLRequest {
        let base = Self.normalize(connection.url)
        guard var components = URLComponents(string: "\(base)\(path)") else {
            throw ProviderError.invalidURL
        }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { throw ProviderError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if includeAuth {
            addAuthHeaders(to: &request, connection: connection, allowBasicFallback: allowBasicFallback)
        } else {
            for (key, value) in connection.customHeaders ?? [:]
            where key.caseInsensitiveCompare("Authorization") != .orderedSame {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        return request
    }

    func addAuthHeaders(
        to request: inout URLRequest,
        connection: ServerConnection,
        allowBasicFallback: Bool = false
    ) {
        for (key, value) in connection.customHeaders ?? [:] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let token = connection.token, !token.isEmpty {
            if token.hasPrefix("Basic ") {
                request.setValue(token, forHTTPHeaderField: "Authorization")
            } else {
                request.setValue(
                    "Bearer \(BookloreJWT.normalizedToken(token) ?? token)",
                    forHTTPHeaderField: "Authorization"
                )
            }
        } else if allowBasicFallback,
            let username = connection.username,
            let password = connection.password,
            !username.isEmpty,
            let data = "\(username):\(password)".data(using: .utf8)
        {
            request.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    private static func normalize(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasSuffix("/") { result.removeLast() }
        if !result.hasPrefix("http") { result = "http://\(result)" }
        return result
    }
}

final class BookloreAuthDelegate: NSObject, URLSessionTaskDelegate, URLSessionDelegate, @unchecked Sendable {
    let credential: URLCredential
    private var challengeCount = 0
    var customHeadersProvider: (() -> [String: String]?)?

    init(username: String, password: String) {
        credential = URLCredential(user: username, password: password, persistence: .forSession)
        super.init()
    }

    @objc func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        if let redirectURL = request.url,
            let host = redirectURL.host?.lowercased(),
            host.contains("cloudflareaccess.com") || redirectURL.path.hasPrefix("/cdn-cgi/access/")
        {
            AppLogger.network.warning("Blocked redirect to Cloudflare Access login: \(redirectURL)")
            completionHandler(nil)
            return
        }
        var redirectRequest = request
        for (key, value) in customHeadersProvider?() ?? [:]
        where redirectRequest.value(forHTTPHeaderField: key) == nil {
            redirectRequest.setValue(value, forHTTPHeaderField: key)
        }
        completionHandler(redirectRequest)
    }

    @objc nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        let host = challenge.protectionSpace.host
        if method == NSURLAuthenticationMethodClientCertificate {
            if let identity = NetworkHostUtils.findMTLSIdentity(forHost: host) {
                completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        } else if method == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust,
            NetworkHostUtils.isLocalNetworkHost(host)
        {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    @objc func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        AppLogger.network.debug("Booklore auth challenge method=\(method) attempt=\(challengeCount + 1)")
        if method == NSURLAuthenticationMethodClientCertificate {
            if let identity = NetworkHostUtils.findMTLSIdentity(forHost: challenge.protectionSpace.host) {
                completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        } else if (method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest)
            && challengeCount < 2
        {
            challengeCount += 1
            completionHandler(.useCredential, credential)
        } else if method == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust,
            NetworkHostUtils.isLocalNetworkHost(challenge.protectionSpace.host)
        {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

struct FlexibleID: Decodable {
    let stringValue: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            stringValue = string
        } else if let int = try? container.decode(Int.self) {
            stringValue = String(int)
        } else if let int64 = try? container.decode(Int64.self) {
            stringValue = String(int64)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected string or integer ID")
            )
        }
    }
}

struct FlexibleDate: Decodable {
    let date: Date?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let epoch = try? container.decode(Double.self) {
            date = Self.date(fromEpoch: epoch)
        } else if let string = try? container.decode(String.self) {
            date = Self.parse(string)
        } else {
            date = nil
        }
    }

    nonisolated static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let epoch = Double(value) {
            return date(fromEpoch: epoch)
        }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }

    nonisolated private static func date(fromEpoch value: Double) -> Date {
        Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1_000 : value)
    }
}

struct BookloreEpubProgress: Decodable {
    let percentage: Double?
    let cfi: String?
    let href: String?
    let updatedAt: String?
}

struct BooklorePage<T: Decodable>: Decodable {
    let content: [T]
    let page: Int
    let size: Int
    let totalElements: Int
    let totalPages: Int
    let hasNext: Bool
    let hasPrevious: Bool
}

struct BooklorePrimaryFile: Decodable {
    let fileName: String?
    let filePath: String?
    let fileSubPath: String?
    let bookType: String?
    let fileType: String?
    let fileExtension: String?

    enum CodingKeys: String, CodingKey {
        case fileName
        case filePath
        case fileSubPath
        case bookType
        case fileType
        case type
        case format
        case fileExtension
        case extensionValue = "extension"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
        filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
        fileSubPath = try container.decodeIfPresent(String.self, forKey: .fileSubPath)
        bookType = try container.decodeIfPresent(String.self, forKey: .bookType)
        fileType =
            try container.decodeIfPresent(String.self, forKey: .fileType)
            ?? container.decodeIfPresent(String.self, forKey: .type)
            ?? container.decodeIfPresent(String.self, forKey: .format)
        fileExtension =
            try container.decodeIfPresent(String.self, forKey: .fileExtension)
            ?? container.decodeIfPresent(String.self, forKey: .extensionValue)
    }
}

struct BookloreBookSummary: Decodable {
    let id: FlexibleID
    let title: String
    let authors: [String]?
    let thumbnailUrl: String?
    let audiobookCoverUpdatedOn: String?
    let duration: Double?
    let seriesName: String?
    let seriesNumber: Double?
    let libraryId: FlexibleID?
    let addedOn: FlexibleDate?
    let publishedDate: String?
    let personalRating: Double?
    let goodreadsRating: Double?
    let readProgress: Double?
    let readStatus: String?
    let primaryFileType: String?
    let primaryFileName: String?
    let durationSeconds: Int?
    let dateFinished: String?
    let lastReadTime: String?
    let epubProgress: BookloreEpubProgress?
    let primaryFile: BooklorePrimaryFile?
    let publisher: String?
    let categories: [String]?
    let language: String?
    let narrator: String?
    let isbn13: String?
    let isbn10: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case authors
        case thumbnailUrl
        case audiobookCoverUpdatedOn
        case duration
        case durationMs
        case seriesName
        case seriesNumber
        case libraryId
        case addedOn
        case publishedDate
        case personalRating
        case goodreadsRating
        case readProgress
        case readStatus
        case primaryFileType
        case fileType
        case type
        case format
        case primaryFileName
        case durationSeconds
        case dateFinished
        case lastReadTime
        case epubProgress
        case primaryFile
        case publisher
        case categories
        case language
        case narrator
        case isbn13
        case isbn10
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(FlexibleID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        authors = try container.decodeIfPresent([String].self, forKey: .authors)
        thumbnailUrl = try container.decodeIfPresent(String.self, forKey: .thumbnailUrl)
        audiobookCoverUpdatedOn = try container.decodeIfPresent(String.self, forKey: .audiobookCoverUpdatedOn)
        let durationMs = try container.decodeIfPresent(Double.self, forKey: .durationMs)
        let durationPlain = try container.decodeIfPresent(Double.self, forKey: .duration)
        duration = durationMs.map { $0 / 1000 } ?? durationPlain.map { $0 > 10_000 ? $0 / 1000 : $0 }
        seriesName = try container.decodeIfPresent(String.self, forKey: .seriesName)
        seriesNumber = try container.decodeIfPresent(Double.self, forKey: .seriesNumber)
        libraryId = try container.decodeIfPresent(FlexibleID.self, forKey: .libraryId)
        addedOn = try container.decodeIfPresent(FlexibleDate.self, forKey: .addedOn)
        publishedDate = try container.decodeIfPresent(String.self, forKey: .publishedDate)
        personalRating = try container.decodeIfPresent(Double.self, forKey: .personalRating)
        goodreadsRating = try container.decodeIfPresent(Double.self, forKey: .goodreadsRating)
        readProgress = try container.decodeIfPresent(Double.self, forKey: .readProgress)
        readStatus = try container.decodeIfPresent(String.self, forKey: .readStatus)
        primaryFileType =
            try container.decodeIfPresent(String.self, forKey: .primaryFileType)
            ?? container.decodeIfPresent(String.self, forKey: .fileType)
            ?? container.decodeIfPresent(String.self, forKey: .type)
            ?? container.decodeIfPresent(String.self, forKey: .format)
        primaryFileName = try container.decodeIfPresent(String.self, forKey: .primaryFileName)
        durationSeconds = try container.decodeIfPresent(Int.self, forKey: .durationSeconds)
        dateFinished = try container.decodeIfPresent(String.self, forKey: .dateFinished)
        lastReadTime = try container.decodeIfPresent(String.self, forKey: .lastReadTime)
        epubProgress = try container.decodeIfPresent(BookloreEpubProgress.self, forKey: .epubProgress)
        primaryFile = try container.decodeIfPresent(BooklorePrimaryFile.self, forKey: .primaryFile)
        publisher = try container.decodeIfPresent(String.self, forKey: .publisher)
        categories = try container.decodeIfPresent([String].self, forKey: .categories)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        narrator = try container.decodeIfPresent(String.self, forKey: .narrator)
        isbn13 = try container.decodeIfPresent(String.self, forKey: .isbn13)
        isbn10 = try container.decodeIfPresent(String.self, forKey: .isbn10)
    }
}

struct BookloreLegacyLibrary: Decodable {
    let id: FlexibleID
    let name: String
    let allowedFormats: [String]?
}

struct BookloreLegacyBook: Decodable {
    let id: FlexibleID
    let libraryId: FlexibleID?
    let name: String?
    let title: String?
    let addedOn: FlexibleDate?
    let readStatus: String?
    let metadata: BookloreLegacyMetadata?
    let primaryFile: BookloreLegacyBookFile?
    let alternativeFormats: [BookloreLegacyBookFile]?

    var hasAudiobookAlternative: Bool {
        (alternativeFormats ?? []).contains { ($0.bookType ?? "").uppercased() == "AUDIOBOOK" }
    }
}

struct BookloreLegacyMetadata: Decodable {
    let title: String?
    let authors: [String]?
    let seriesName: String?
    let seriesNumber: Float?
    let description: String?
    let publisher: String?
    let narrator: String?
    let audiobookCoverUpdatedOn: String?
}

struct BookloreLegacyBookFile: Decodable {
    let bookType: String?
    let fileType: String?
    let fileExtension: String?
    let fileName: String?
    let filePath: String?
    let folderBased: Bool?

    enum CodingKeys: String, CodingKey {
        case bookType
        case fileType
        case type
        case format
        case fileExtension
        case extensionValue = "extension"
        case fileName
        case filename
        case filePath
        case folderBased
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookType = try container.decodeIfPresent(String.self, forKey: .bookType)
        fileType =
            try container.decodeIfPresent(String.self, forKey: .fileType)
            ?? container.decodeIfPresent(String.self, forKey: .type)
            ?? container.decodeIfPresent(String.self, forKey: .format)
        fileExtension =
            try container.decodeIfPresent(String.self, forKey: .fileExtension)
            ?? container.decodeIfPresent(String.self, forKey: .extensionValue)
        fileName =
            try container.decodeIfPresent(String.self, forKey: .fileName)
            ?? container.decodeIfPresent(String.self, forKey: .filename)
        filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
        folderBased = try container.decodeIfPresent(Bool.self, forKey: .folderBased)
    }
}

enum BookloreBookMapper {
    private static let ebookFileTypes: Set<String> = [
        "EPUB", "PDF", "CBX", "CBR", "CBZ", "FB2", "MOBI", "AZW3", "AZW",
    ]
    private static let audiobookFileTypes: Set<String> = [
        "AUDIOBOOK", "MP3", "M4A", "M4B", "MP4", "AAC", "FLAC", "OGG", "OGA", "OPUS", "WAV",
    ]

    static func normalizedFileType(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix(".") {
            value.removeFirst()
        }

        switch value.lowercased() {
        case "application/epub+zip": return "epub"
        case "application/pdf": return "pdf"
        case "application/x-cbz", "application/vnd.comicbook+zip", "application/zip", "application/x-zip-compressed":
            return "cbz"
        case "application/x-cbr", "application/vnd.comicbook-rar", "application/x-rar-compressed", "application/vnd.rar":
            return "cbr"
        case "application/x-mobipocket-ebook": return "mobi"
        case "application/x-mobi8-ebook": return "azw3"
        case "audio/mpeg": return "mp3"
        case "audio/mp4": return "m4a"
        case "audio/aac": return "aac"
        case "audio/flac": return "flac"
        case "audio/ogg": return "ogg"
        case "audio/opus": return "opus"
        case "audio/wav": return "wav"
        default: return value
        }
    }

    static func resolvedFileType(_ candidates: [String?]) -> String? {
        candidates.lazy.compactMap(normalizedFileType).first
    }

    static func fileExtension(from path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        let fileExtension = (path as NSString).pathExtension
        return fileExtension.isEmpty ? nil : fileExtension
    }

    static func mediaType(from fileType: String?) -> AppMediaType {
        switch normalizedFileType(fileType)?.uppercased() {
        case let value? where ebookFileTypes.contains(value): .ebook
        case let value? where audiobookFileTypes.contains(value): .audiobook
        default: .ebook
        }
    }

    static func libraryType(from formats: [String]?) -> String {
        guard let formats, !formats.isEmpty else { return "book" }
        let normalized = Set(formats.compactMap(normalizedFileType).map { $0.uppercased() })
        let hasEbook = !normalized.isDisjoint(with: ebookFileTypes)
        let hasAudio = normalized.contains("AUDIOBOOK")
        if hasAudio && !hasEbook { return "audiobook" }
        if hasEbook && !hasAudio { return "ebook" }
        return "book"
    }

    static func normalizedEbookFormat(_ value: String?) -> String? {
        guard let normalized = normalizedFileType(value)?.lowercased(),
            EbookFormat.allExtensions.contains(normalized)
        else { return nil }
        return normalized
    }

    static func displayAuthor(from values: [String]?) -> String {
        guard let values else { return "Unknown Author" }
        let normalized = Set(
            values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        guard !normalized.isEmpty else { return "Unknown Author" }
        return normalized.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .joined(separator: ", ")
    }

    static func title(fromPrimaryFileName fileName: String?) -> String? {
        guard let fileName = fileName?.trimmingCharacters(in: .whitespacesAndNewlines), !fileName.isEmpty else {
            return nil
        }
        let title = (fileName as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    static func publishedYear(from value: String?) -> Int? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let prefix = value.split(separator: "-").first, let year = Int(prefix) {
            return year
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return date.map { Calendar(identifier: .gregorian).component(.year, from: $0) }
    }

    static func normalizedSeriesInfo(name: String?, sequence: String?) -> SeriesInfo? {
        guard let rawName = name?.trimmingCharacters(in: .whitespacesAndNewlines), !rawName.isEmpty else { return nil }
        if let volume = strippedSeriesVolume(rawName) {
            return SeriesInfo(name: volume.base, sequence: sequence ?? volume.number)
        }
        return SeriesInfo(name: rawName, sequence: sequence)
    }

    static func chapters(from rawChapters: [GrimmoryChapter]?, bookDuration: TimeInterval) -> [Chapter] {
        guard let rawChapters, !rawChapters.isEmpty else { return [] }
        let mapped = rawChapters.enumerated().map { index, chapter in
            let start = max(chapter.start ?? 0, 0)
            let end = max(chapter.end ?? start, start)
            let title = chapter.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? "Chapter \(index + 1)"
            return Chapter(
                id: "grimmory_ch_\(index)",
                start: start,
                end: end,
                title: resolvedTitle,
                index: index
            )
        }
        return normalizeChapters(mapped, bookDuration: max(bookDuration, mapped.map(\.end).max() ?? 0))
    }

    static func chaptersAreInadequate(_ chapters: [Chapter], bookDuration: TimeInterval) -> Bool {
        guard !chapters.isEmpty else { return true }
        return bookDuration > 1_800 && chapters.count <= 1
    }

    static func normalizeChapters(_ chapters: [Chapter], bookDuration: TimeInterval) -> [Chapter] {
        guard !chapters.isEmpty else { return [] }
        let sorted = chapters.sorted { lhs, rhs in
            lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
        }
        return sorted.enumerated().map { index, chapter in
            let nextStart = sorted.indices.contains(index + 1) ? sorted[index + 1].start : nil
            let fallbackEnd = nextStart ?? (bookDuration > 0 ? bookDuration : chapter.end)
            return Chapter(
                id: chapter.id,
                start: chapter.start,
                end: max(chapter.end > chapter.start ? chapter.end : fallbackEnd, chapter.start),
                title: chapter.title,
                index: index
            )
        }
    }

    static func statusSuppressesContinue(_ status: String?) -> Bool {
        guard let status else { return false }
        return status != "READING" && status != "RE_READING"
    }

    static func normalizedBaseURL(_ urlString: String) -> String {
        var str = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasSuffix("/") { str.removeLast() }
        if !str.hasPrefix("http") { str = "http://\(str)" }
        return str
    }

    static func rewriteCoverPath(_ path: String, mediaType: AppMediaType? = nil) -> String {
        if path.hasPrefix("/api/v1/media/book/") {
            guard mediaType == .audiobook else {
                return path
            }
            if path.hasSuffix("/cover") {
                return String(path.dropLast("/cover".count)) + "/audiobook-cover"
            }
            if path.hasSuffix("/thumbnail") {
                return String(path.dropLast("/thumbnail".count)) + "/audiobook-thumbnail"
            }
            return path
        }

        guard path.hasPrefix("/api/books/") else {
            return path
        }

        let suffixMappings: [(suffix: String, mapped: (String) -> String)] = [
            ("/audiobook-cover", { "/api/v1/media/book/\($0)/audiobook-cover" }),
            ("/audiobook-thumbnail", { "/api/v1/media/book/\($0)/audiobook-thumbnail" }),
            (
                "/cover",
                {
                    switch mediaType {
                    case .audiobook:
                        return "/api/v1/media/book/\($0)/audiobook-thumbnail"
                    default:
                        return "/api/v1/media/book/\($0)/cover"
                    }
                }
            ),
            (
                "/thumbnail",
                {
                    switch mediaType {
                    case .audiobook:
                        return "/api/v1/media/book/\($0)/audiobook-thumbnail"
                    default:
                        return "/api/v1/media/book/\($0)/thumbnail"
                    }
                }
            ),
        ]

        for (suffix, mapper) in suffixMappings {
            if path.hasSuffix(suffix) {
                let stripped = path.dropFirst("/api/books/".count).dropLast(suffix.count)
                if !stripped.isEmpty {
                    return mapper(String(stripped))
                }
            }
        }

        return path
    }

    static func rewriteCoverURL(_ url: URL, mediaType: AppMediaType? = nil) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        let correctedPath = rewriteCoverPath(components.path, mediaType: mediaType)
        guard correctedPath != components.path else {
            return url
        }

        components.path = correctedPath
        return components.url ?? url
    }

    static func absoluteURL(from value: String?, serverURL: String, mediaType: AppMediaType? = nil) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        if let absolute = URL(string: value), absolute.scheme != nil {
            return rewriteCoverURL(absolute, mediaType: mediaType)
        }

        let corrected = rewriteCoverPath(value, mediaType: mediaType)
        let base = normalizedBaseURL(serverURL)
        if corrected.hasPrefix("/") {
            return URL(string: "\(base)\(corrected)")
        }
        return URL(string: "\(base)/\(corrected)")
    }

    static func versionedCoverURL(_ url: URL?, updatedOn: String?) -> URL? {
        guard let url, let updatedOn, !updatedOn.isEmpty,
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return url
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "v" }
        queryItems.append(URLQueryItem(name: "v", value: updatedOn))
        components.queryItems = queryItems
        return components.url ?? url
    }

    private static func strippedSeriesVolume(_ name: String) -> (base: String, number: String)? {
        let pattern = #"^(.*\S)\s+(?:#\s*|vol\.?\s*|volume\s+|book\s+|bk\.?\s*)(\d+(?:\.\d+)?)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(name.startIndex..., in: name)
        guard let match = regex.firstMatch(in: name, range: range),
            let baseRange = Range(match.range(at: 1), in: name),
            let numberRange = Range(match.range(at: 2), in: name)
        else { return nil }
        let base = String(name[baseRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        return (base, String(name[numberRange]))
    }
}

enum BookloreCatalogMapper {
    struct Context {
        let providerId: UUID
        let libraryId: String
        let source: Book.BookSource
        let serverURL: String
    }

    static func book(from summary: BookloreBookSummary, context: Context) -> Book {
        let seriesInfo = BookloreBookMapper.normalizedSeriesInfo(name: summary.seriesName, sequence: summary.seriesNumber.map { String($0) })

        let knownEbookFileTypes: Set<String> = ["EPUB", "PDF", "CBX", "CBR", "CBZ", "FB2", "MOBI", "AZW3", "AZW"]
        let resolvedType = resolvedFileType(primaryFileType: summary.primaryFileType, primaryFile: summary.primaryFile)
        let primaryIsRealEbook = (resolvedType?.uppercased()).map(knownEbookFileTypes.contains) ?? false
        let hasAudiobookSignal = summary.audiobookCoverUpdatedOn != nil || (summary.thumbnailUrl?.contains("/audiobook-") == true)

        var detectedMediaType = BookloreBookMapper.mediaType(from: resolvedType)
        var isDualFormatEbook = false
        if detectedMediaType != .audiobook, hasAudiobookSignal {
            if primaryIsRealEbook {
                isDualFormatEbook = true
            } else {
                detectedMediaType = .audiobook
            }
        }
        let readProg = Book.normalizedFractionProgress(summary.readProgress ?? summary.epubProgress?.percentage) ?? 0
        let duration: Double? = summary.durationSeconds.map { Double($0) } ?? summary.duration.flatMap { $0 > 0 ? $0 : nil }
        let currentTime =
            detectedMediaType == .audiobook && (duration ?? 0) > 0
            ? readProg * (duration ?? 0)
            : 0
        let serverReadStatus = summary.readStatus?.uppercased()
        let isFinished = readProg >= 0.99 || serverReadStatus == "READ" || summary.dateFinished != nil
        let hideFromContinue = BookloreBookMapper.statusSuppressesContinue(serverReadStatus)

        let lastUpdate =
            FlexibleDate.parse(summary.dateFinished)
            ?? FlexibleDate.parse(summary.lastReadTime)
            ?? summary.addedOn?.date
            ?? Date()

        let resolvedFilePath = summary.primaryFile?.filePath ?? summary.primaryFileName
        let resolvedTitle: String = {
            if detectedMediaType == .audiobook,
                let titleFromFile = BookloreBookMapper.title(fromPrimaryFileName: summary.primaryFileName ?? summary.primaryFile?.fileName)
            {
                return titleFromFile
            }
            return summary.title
        }()

        let coverURL = BookloreBookMapper.absoluteURL(
            from: summary.thumbnailUrl,
            serverURL: context.serverURL,
            mediaType: detectedMediaType
        )
        let versionedCoverURL = BookloreBookMapper.versionedCoverURL(
            coverURL,
            updatedOn: detectedMediaType == .audiobook ? summary.audiobookCoverUpdatedOn : nil
        )

        var result = Book(
            id: summary.id.stringValue,
            title: resolvedTitle,
            author: BookloreBookMapper.displayAuthor(from: summary.authors),
            authors: summary.authors,
            narrator: summary.narrator,
            seriesInfo: seriesInfo,
            duration: duration,
            coverURL: versionedCoverURL,
            mediaType: detectedMediaType,
            epubLocator: nil,
            ebookProgress: detectedMediaType == .ebook ? readProg : nil,
            hideFromContinue: hideFromContinue,
            dateAdded: summary.addedOn?.date,
            description: nil,
            genres: summary.categories,
            chapters: [],
            publisher: summary.publisher,
            currentTime: currentTime,
            isFinished: isFinished,
            lastUpdate: lastUpdate,
            libraryId: summary.libraryId?.stringValue ?? context.libraryId,
            providerId: context.providerId,
            source: context.source,
            rawMetadata: nil,
            filePath: resolvedFilePath,
            publishedYear: BookloreBookMapper.publishedYear(from: summary.publishedDate),
            personalRating: summary.personalRating.map { $0 / 2 },
            goodreadsRating: summary.goodreadsRating,
            language: summary.language
        )
        result.isbn = summary.isbn13 ?? summary.isbn10
        result.serverReadStatus = serverReadStatus
        if detectedMediaType == .ebook {
            result.ebookFormat = BookloreBookMapper.normalizedEbookFormat(resolvedType)
        }
        if isDualFormatEbook {
            result.hasAlternateFormat = true
        }
        return result
    }

    static func book(from legacy: BookloreLegacyBook, context: Context) -> Book {
        let resolvedType = resolvedFileType(file: legacy.primaryFile)
        let mediaType = BookloreBookMapper.mediaType(from: resolvedType)
        let title = {
            if mediaType == .audiobook,
                let titleFromFile = BookloreBookMapper.title(fromPrimaryFileName: legacy.primaryFile?.fileName ?? legacy.primaryFile?.filePath)
            {
                return titleFromFile
            }
            return legacy.title ?? legacy.metadata?.title ?? legacy.name ?? "Unknown"
        }()
        let author = BookloreBookMapper.displayAuthor(from: legacy.metadata?.authors)
        let legacyAuthors: [String]? = legacy.metadata?.authors
        let narrator = legacy.metadata?.narrator
        let seriesInfo = BookloreBookMapper.normalizedSeriesInfo(
            name: legacy.metadata?.seriesName,
            sequence: legacy.metadata?.seriesNumber.map { String($0) }
        )
        let serverReadStatus = legacy.readStatus?.uppercased()
        let isAudiobook = mediaType == .audiobook
        let coverPath =
            isAudiobook
            ? "/api/books/\(legacy.id.stringValue)/audiobook-cover"
            : "/api/books/\(legacy.id.stringValue)/cover"
        let coverURL = BookloreBookMapper.absoluteURL(from: coverPath, serverURL: context.serverURL)
        var result = Book(
            id: legacy.id.stringValue,
            title: title,
            author: author,
            authors: legacyAuthors,
            narrator: narrator,
            seriesInfo: seriesInfo,
            duration: 0,
            coverURL: coverURL,
            mediaType: mediaType,
            hideFromContinue: BookloreBookMapper.statusSuppressesContinue(serverReadStatus),
            dateAdded: legacy.addedOn?.date,
            description: legacy.metadata?.description,
            genres: [],
            chapters: [],
            publisher: legacy.metadata?.publisher,
            progress: 0,
            currentTime: 0,
            isFinished: serverReadStatus == "READ",
            lastUpdate: legacy.addedOn?.date ?? Date(),
            libraryId: legacy.libraryId?.stringValue ?? context.libraryId,
            providerId: context.providerId,
            source: context.source,
            rawMetadata: nil
        )
        result.serverReadStatus = serverReadStatus

        if mediaType == .ebook, legacy.hasAudiobookAlternative {
            result.hasAlternateFormat = true
        }
        if mediaType == .ebook {
            result.ebookFormat = BookloreBookMapper.normalizedEbookFormat(resolvedType)
        }
        return result
    }

    static func resolvedFileType(primaryFileType: String?, primaryFile: BooklorePrimaryFile?) -> String? {
        BookloreBookMapper.resolvedFileType([
            primaryFile?.fileType,
            primaryFile?.fileExtension,
            primaryFile?.bookType,
            primaryFileType,
            BookloreBookMapper.fileExtension(from: primaryFile?.fileName),
            BookloreBookMapper.fileExtension(from: primaryFile?.filePath),
            BookloreBookMapper.fileExtension(from: primaryFile?.fileSubPath),
        ])
    }

    private static func resolvedFileType(file: BookloreLegacyBookFile?) -> String? {
        BookloreBookMapper.resolvedFileType([
            file?.fileType,
            file?.fileExtension,
            file?.bookType,
            BookloreBookMapper.fileExtension(from: file?.fileName),
            BookloreBookMapper.fileExtension(from: file?.filePath),
        ])
    }
}

nonisolated struct GrimmoryTrack: Decodable {
    let index: Int?
    let fileName: String?
    let title: String?
    let duration: Double?
    let mimeType: String?
    let cumulativeStart: Double?

    private enum CodingKeys: String, CodingKey {
        case index
        case trackIndex
        case fileName
        case filename
        case title
        case duration
        case durationMs
        case mimeType
        case contentType
        case cumulativeStart
        case cumulativeStartMs
        case startOffset
        case startOffsetMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index =
            try container.decodeIfPresent(Int.self, forKey: .index)
            ?? container.decodeIfPresent(Int.self, forKey: .trackIndex)
        fileName =
            try container.decodeIfPresent(String.self, forKey: .fileName)
            ?? container.decodeIfPresent(String.self, forKey: .filename)
        title = try container.decodeIfPresent(String.self, forKey: .title)

        let durationMilliseconds = try container.decodeIfPresent(Double.self, forKey: .durationMs)
        let durationValue = try container.decodeIfPresent(Double.self, forKey: .duration)
        duration = durationMilliseconds.map { $0 / 1_000 }
            ?? durationValue.map { $0 > 10_000 ? $0 / 1_000 : $0 }
        mimeType =
            try container.decodeIfPresent(String.self, forKey: .mimeType)
            ?? container.decodeIfPresent(String.self, forKey: .contentType)
        let startMilliseconds =
            try container.decodeIfPresent(Double.self, forKey: .cumulativeStartMs)
            ?? container.decodeIfPresent(Double.self, forKey: .startOffsetMs)
        let startValue =
            try container.decodeIfPresent(Double.self, forKey: .cumulativeStart)
            ?? container.decodeIfPresent(Double.self, forKey: .startOffset)
        cumulativeStart = startMilliseconds.map { $0 / 1_000 }
            ?? startValue.map { $0 > 10_000 ? $0 / 1_000 : $0 }
    }
}

nonisolated struct GrimmoryChapter: Decodable {
    let title: String?
    let start: Double?
    let end: Double?

    private enum CodingKeys: String, CodingKey {
        case title
        case start
        case end
        case startTimeMs
        case endTimeMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)

        let startMilliseconds = try container.decodeIfPresent(Double.self, forKey: .startTimeMs)
        let startValue = try container.decodeIfPresent(Double.self, forKey: .start)
        let endMilliseconds = try container.decodeIfPresent(Double.self, forKey: .endTimeMs)
        let endValue = try container.decodeIfPresent(Double.self, forKey: .end)
        start = startMilliseconds.map { $0 / 1_000 }
            ?? startValue.map { $0 > 10_000 ? $0 / 1_000 : $0 }
        end = endMilliseconds.map { $0 / 1_000 }
            ?? endValue.map { $0 > 10_000 ? $0 / 1_000 : $0 }
    }
}

nonisolated struct BookloreAudiobookInfo: Decodable {
    let bookId: Int?
    let bookFileId: Int?
    let title: String?
    let author: String?
    let narrator: String?
    let duration: Double?
    let tracks: [GrimmoryTrack]?
    let chapters: [GrimmoryChapter]?

    private enum CodingKeys: String, CodingKey {
        case bookId
        case bookFileId
        case title
        case author
        case narrator
        case duration
        case durationMs
        case tracks
        case chapters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookId = try container.decodeIfPresent(Int.self, forKey: .bookId)
        bookFileId = try container.decodeIfPresent(Int.self, forKey: .bookFileId)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        narrator = try container.decodeIfPresent(String.self, forKey: .narrator)
        let durationMilliseconds = try container.decodeIfPresent(Double.self, forKey: .durationMs)
        let durationValue = try container.decodeIfPresent(Double.self, forKey: .duration)
        duration = durationMilliseconds.map { $0 / 1_000 }
            ?? durationValue.map { $0 > 10_000 ? $0 / 1_000 : $0 }
        tracks = try container.decodeIfPresent([GrimmoryTrack].self, forKey: .tracks)
        chapters = try container.decodeIfPresent([GrimmoryChapter].self, forKey: .chapters)
    }
}

struct BooklorePlaybackMapping {
    let tracks: [AudioTrackInfo]
    let chapters: [Chapter]
    let duration: TimeInterval
    let bookFileId: Int?
}

enum BooklorePlaybackMapper {
    static func map(
        _ info: BookloreAudiobookInfo,
        trackURL: (Int) -> URL?
    ) -> BooklorePlaybackMapping {
        var tracks: [AudioTrackInfo] = []
        var chapters: [Chapter] = []
        let serverDuration = info.duration ?? 0

        if let infoTracks = info.tracks {
            var offset: Double = 0
            for (position, track) in infoTracks.enumerated() {
                let index = track.index ?? position
                let duration = track.duration ?? 0
                let startOffset = track.cumulativeStart ?? offset
                let title = track.title
                    ?? track.fileName.map {
                        URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
                    }
                tracks.append(
                    AudioTrackInfo(
                        index: index,
                        startOffset: startOffset,
                        duration: duration,
                        contentUrl: trackURL(index)?.absoluteString ?? "",
                        mimeType: track.mimeType ?? "audio/mp4",
                        title: title
                    )
                )
                offset = max(offset, startOffset + duration)
            }
        }

        if let infoChapters = info.chapters {
            let trackBackedDuration = tracks.reduce(0) { $0 + max($1.duration, 0) }
            let totalDuration = max(serverDuration, trackBackedDuration)
            let shouldMapChaptersToTracks =
                infoChapters.count == tracks.count
                && infoChapters.allSatisfy { chapter in
                    guard let start = chapter.start else { return true }
                    return start <= 0
                }

            for (position, chapter) in infoChapters.enumerated() {
                let fallbackTrack = tracks.indices.contains(position) ? tracks[position] : nil
                let start: Double
                if shouldMapChaptersToTracks, let fallbackTrack {
                    start = fallbackTrack.startOffset
                } else if let explicitStart = chapter.start, explicitStart >= 0 {
                    start = explicitStart
                } else if let fallbackTrack {
                    start = fallbackTrack.startOffset
                } else if let previousChapter = chapters.last {
                    start = previousChapter.end
                } else {
                    start = 0
                }

                let nextExplicitStart = infoChapters.dropFirst(position + 1)
                    .compactMap(\.start)
                    .first(where: { $0 > start })
                let trackEnd = fallbackTrack.map { $0.startOffset + max($0.duration, 0) }
                let fallbackEnd = nextExplicitStart ?? trackEnd ?? totalDuration
                let explicitEnd = chapter.end.flatMap { $0 > start ? $0 : nil }
                chapters.append(
                    Chapter(
                        id: "grimmory_ch_\(position)",
                        start: start,
                        end: max(explicitEnd ?? fallbackEnd, start),
                        title: chapter.title ?? "Chapter \(position + 1)"
                    )
                )
            }

            if totalDuration > 0, !chapters.isEmpty {
                for index in chapters.indices {
                    let nextStart = chapters.indices.contains(index + 1)
                        ? chapters[index + 1].start
                        : totalDuration
                    let normalizedEnd = max(
                        chapters[index].end,
                        nextStart,
                        chapters[index].start
                    )
                    if normalizedEnd != chapters[index].end {
                        chapters[index] = Chapter(
                            id: chapters[index].id,
                            start: chapters[index].start,
                            end: normalizedEnd,
                            title: chapters[index].title,
                            index: chapters[index].index
                        )
                    }
                }
            }
        }

        return BooklorePlaybackMapping(
            tracks: tracks,
            chapters: chapters,
            duration: serverDuration,
            bookFileId: info.bookFileId
        )
    }
}

@MainActor
final class BooklorePlaybackClient {
    typealias RequestBuilder = (String) throws -> URLRequest
    typealias AuthorizedRequest = (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let makeRequest: RequestBuilder
    private let performAuthorizedRequest: AuthorizedRequest

    init(
        makeRequest: @escaping RequestBuilder,
        performAuthorizedRequest: @escaping AuthorizedRequest
    ) {
        self.makeRequest = makeRequest
        self.performAuthorizedRequest = performAuthorizedRequest
    }

    func fetchInfo(bookId: String) async throws -> BookloreAudiobookInfo? {
        let request = try makeRequest("/api/v1/audiobooks/\(bookId)/info")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(BookloreAudiobookInfo.self, from: data)
    }

    func fetchMapping(
        bookId: String,
        trackURL: (Int) -> URL?
    ) async throws -> BooklorePlaybackMapping? {
        guard let info = try await fetchInfo(bookId: bookId) else { return nil }
        return BooklorePlaybackMapper.map(info, trackURL: trackURL)
    }

    func fetchDownloadTracks(
        bookId: String,
        trackURL: (Int) -> URL?
    ) async -> [(url: URL, mimeType: String)]? {
        guard let info = try? await fetchInfo(bookId: bookId),
            let tracks = info.tracks,
            tracks.count > 1
        else {
            return nil
        }

        let resolvedTracks = tracks
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }
            .compactMap { track -> (url: URL, mimeType: String)? in
                let index = track.index ?? 0
                guard let url = trackURL(index) else { return nil }
                return (url, track.mimeType ?? "audio/mpeg")
            }
        return resolvedTracks.count > 1 ? resolvedTracks : nil
    }
}

@MainActor
final class BookloreProgressClient {
    typealias RequestBuilder = (String) throws -> URLRequest
    typealias AuthorizedRequest = (URLRequest) async throws -> (Data, HTTPURLResponse)
    typealias ResponseValidator = (Data, HTTPURLResponse, String) throws -> Void

    struct EbookProgressContext {
        struct PageProgress {
            let page: Int?
            let percentage: Double?
            let updatedAt: String?
        }

        let hasEpubResource: Bool
        let readProgress: Double?
        let readStatus: String?
        let lastReadTime: String?
        let pdfProgress: PageProgress?
        let cbxProgress: PageProgress?
    }

    private struct AudiobookProgressPayload: Decodable {
        struct Position: Decodable {
            let positionMs: Double?
            let trackIndex: Int?
            let percentage: Double?
            let updatedAt: String?
        }

        let audiobookProgress: Position?
        let readStatus: String?
        let readProgress: Double?
        let lastReadTime: String?
        let duration: Double?
        let durationSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case audiobookProgress
            case readStatus
            case readProgress
            case lastReadTime
            case duration
            case durationMs
            case durationSeconds
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            audiobookProgress = try container.decodeIfPresent(Position.self, forKey: .audiobookProgress)
            readStatus = try container.decodeIfPresent(String.self, forKey: .readStatus)
            readProgress = try container.decodeIfPresent(Double.self, forKey: .readProgress)
            lastReadTime = try container.decodeIfPresent(String.self, forKey: .lastReadTime)
            let durationMs = try container.decodeIfPresent(Double.self, forKey: .durationMs)
            let durationValue = try container.decodeIfPresent(Double.self, forKey: .duration)
            duration = durationMs.map { $0 / 1_000 }
                ?? durationValue.map { $0 > 10_000 ? $0 / 1_000 : $0 }
            durationSeconds = try container.decodeIfPresent(Int.self, forKey: .durationSeconds)
        }
    }

    private struct AppEbookProgressPayload: Decodable {
        struct EpubPosition: Decodable {
            let percentage: Double?
            let cfi: String?
            let href: String?
            let updatedAt: String?
        }

        let readProgress: Double?
        let readStatus: String?
        let lastReadTime: String?
        let epubProgress: EpubPosition?
    }

    struct EbookProgressRequest: Encodable {
        struct FileProgress: Encodable {
            let bookFileId: Int
            let positionData: String?
            let positionHref: String?
            let progressPercent: Double
            let ttsPositionCfi: String?
            let contentSourceProgressPercent: Double?
        }

        let fileProgress: FileProgress
    }

    private struct ReadProgressRequest: Encodable {
        struct FileProgress: Encodable {
            let bookFileId: Int
            let progressPercent: Double
        }

        let bookId: Int
        let fileProgress: FileProgress
    }

    private struct AudiobookInfo: Decodable {
        let bookFileId: Int?
    }

    private struct AudiobookProgressRequest: Encodable {
        struct FileProgress: Encodable {
            let bookFileId: Int
            let positionData: String?
            let positionHref: String?
            let progressPercent: Double
        }

        let bookId: Int
        let fileProgress: FileProgress
        let dateFinished: String?
    }

    private let makeRequest: RequestBuilder
    private let performAuthorizedRequest: AuthorizedRequest
    private let validateResponse: ResponseValidator
    private var audiobookFileIds: [String: Int] = [:]

    init(
        makeRequest: @escaping RequestBuilder,
        performAuthorizedRequest: @escaping AuthorizedRequest,
        validateResponse: @escaping ResponseValidator = { _, _, _ in }
    ) {
        self.makeRequest = makeRequest
        self.performAuthorizedRequest = performAuthorizedRequest
        self.validateResponse = validateResponse
    }

    func fetchAudiobookProgress(
        for book: Book,
        bookId: String
    ) async -> ProviderAudiobookProgress? {
        let primaryData: Data
        let primaryResponse: HTTPURLResponse
        do {
            (primaryData, primaryResponse) = try await performAuthorizedRequest(
                try makeRequest("/api/v1/app/books/\(bookId)")
            )
        } catch {
            return nil
        }

        if primaryResponse.statusCode == 200,
            let progress = Self.decodeAudiobookProgress(primaryData, for: book)
        {
            return progress
        }

        guard
            let fallback = try? await performAuthorizedRequest(
                try makeRequest("/api/v1/books/\(bookId)")
            ),
            fallback.1.statusCode == 200
        else {
            return nil
        }
        return Self.decodeAudiobookProgress(fallback.0, for: book)
    }

    func fetchEbookProgress(
        for book: Book,
        bookId: Int,
        context: EbookProgressContext
    ) async throws -> ProviderEbookProgress? {
        let (data, response) = try await performAuthorizedRequest(
            try makeRequest("/api/v1/app/books/\(bookId)/progress")
        )
        let appProgress: AppEbookProgressPayload?
        switch response.statusCode {
        case 200:
            try validateResponse(data, response, "/api/v1/app/books/{bookId}/progress")
            appProgress = try JSONDecoder().decode(AppEbookProgressPayload.self, from: data)
        case 404:
            appProgress = nil
        case 401, 403:
            throw ProviderError.unauthorized
        default:
            throw ProviderError.serverError(
                "Failed to fetch Booklore app progress (HTTP \(response.statusCode))"
            )
        }

        let epubProgress = context.hasEpubResource ? appProgress?.epubProgress : nil
        let exactCFI = EpubLocationBridge.canonicalFullEPUBCFI(epubProgress?.cfi)
        let endpointPercentage =
            epubProgress?.percentage
            ?? appProgress?.readProgress
            ?? context.readProgress
            ?? context.pdfProgress?.percentage
            ?? context.cbxProgress?.percentage
        let readState = ProviderReadState(
            serverValue: appProgress?.readStatus ?? context.readStatus
        )
        let percentage =
            endpointPercentage
            ?? (readState.isFinished ? book.canonicalEbookProgress * 100 : 0)
        let fraction = Book.normalizedFractionProgress(percentage) ?? 0

        let locator: String? = {
            if let exactCFI {
                return EpubLocationBridge.readiumLocator(
                    href: epubProgress?.href,
                    epubCFI: exactCFI,
                    fraction: fraction,
                    sourceEngine: .foliate
                )
            }
            if context.hasEpubResource {
                return nil
            }
            if let page = context.pdfProgress?.page {
                return "{\"page\":\(page)}"
            }
            if let page = context.cbxProgress?.page {
                return "cbz-page:\(page)"
            }
            return nil
        }()

        guard
            fraction > 0
                || locator != nil
                || readState.isFinished
                || readState.isAbandoned
                || readState == .notReading
        else {
            return nil
        }

        if exactCFI != nil {
            AppLogger.network.debug(
                "[Booklore] Received exact EPUB position bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
            )
        }
        return ProviderEbookProgress(
            progress: fraction,
            locator: locator,
            updatedAt: Self.parseTimestamp(
                epubProgress?.updatedAt
                    ?? appProgress?.lastReadTime
                    ?? context.lastReadTime
                    ?? context.pdfProgress?.updatedAt
                    ?? context.cbxProgress?.updatedAt
            ),
            readState: readState
        )
    }

    func cacheAudiobookFileId(_ fileId: Int, for bookId: String) {
        guard fileId > 0 else { return }
        audiobookFileIds[bookId] = fileId
    }

    func cachedAudiobookFileId(for bookId: String) -> Int? {
        audiobookFileIds[bookId]
    }

    func updateEbookProgress(
        for book: Book,
        bookId: Int,
        resourceFileId: Int?,
        progress: Double,
        epubLocator: String?,
        sourceEngine: ReaderEngineKind?
    ) async throws {
        let progressPercent = min(max(progress, 0), 1) * 100
        let provenanceLocator = sourceEngine.flatMap {
            EpubLocationBridge.markingSourceEngine($0, in: epubLocator)
        } ?? epubLocator
        let location = EpubLocationBridge.extractGrimmoryLocation(from: provenanceLocator)
        let fullCFI: String? = {
            if sourceEngine == .foliate {
                return EpubLocationBridge.canonicalFullEPUBCFI(
                    EpubLocationBridge.epubCFI(from: epubLocator)
                )
            }
            return EpubLocationBridge.canonicalFullEPUBCFI(location.epubCFI)
        }()
        let isOrdinaryEPUB =
            !book.isReadAloudBook
            && book.epub3Features?.hasMediaOverlay != true

        if isOrdinaryEPUB, let resourceFileId {
            let resourcePercentage = Self.resourcePercentage(from: provenanceLocator)
            var request = try makeRequest("/api/v1/app/books/\(bookId)/progress")
            request.httpMethod = "PUT"
            request.httpBody = try JSONEncoder().encode(
                EbookProgressRequest(
                    fileProgress: .init(
                        bookFileId: resourceFileId,
                        positionData: fullCFI,
                        positionHref: fullCFI == nil ? nil : location.href,
                        progressPercent: progressPercent,
                        ttsPositionCfi: nil,
                        contentSourceProgressPercent: fullCFI == nil
                            ? nil
                            : resourcePercentage
                    )
                )
            )
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let (_, response) = try await performAuthorizedRequest(request)
            guard (200...204).contains(response.statusCode) else {
                throw ProviderError.serverError(
                    "Failed to sync Booklore EPUB position (HTTP \(response.statusCode))"
                )
            }
            AppLogger.network.debug(
                "[Booklore] Pushed EPUB position bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) type=\(fullCFI == nil ? "percentage" : "cfi") percentage=\(progressPercent)"
            )
            return
        }

        let fileId = resourceFileId ?? bookId
        var request = try makeRequest("/api/v1/books/progress")
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(
            ReadProgressRequest(
                bookId: bookId,
                fileProgress: .init(
                    bookFileId: fileId,
                    progressPercent: progressPercent
                )
            )
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await performAuthorizedRequest(request)
        guard (200...204).contains(response.statusCode) else {
            throw ProviderError.serverError(
                "Failed to sync Booklore ebook progress (HTTP \(response.statusCode))"
            )
        }
        AppLogger.network.debug(
            "[Booklore] Pushed ebook progress bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) percentage=\(progressPercent)"
        )
    }

    func updateAudiobookProgress(
        for book: Book,
        bookId: String,
        sessionId: String?,
        currentTime: TimeInterval,
        duration: TimeInterval,
        isFinished: Bool
    ) async throws -> Double {
        let fraction = min(max(currentTime / duration, 0), 1)
        let progressPercent = fraction * 100
        guard let fileId = await resolveAudiobookFileId(
            for: book,
            bookId: bookId,
            sessionId: sessionId
        ) else {
            AppLogger.network.warning(
                "[Booklore] Audiobook position push skipped; missing file ID bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
            )
            return fraction
        }

        let positionData: String?
        let positionHref: String?
        if book.isMultiFile, let localPosition = book.localPosition(for: currentTime) {
            positionData = String(Int((localPosition.localOffset * 1_000).rounded()))
            positionHref = String(localPosition.trackIndex)
        } else {
            positionData = String(Int((currentTime * 1_000).rounded()))
            positionHref = nil
        }

        let body = AudiobookProgressRequest(
            bookId: Int(bookId) ?? 0,
            fileProgress: AudiobookProgressRequest.FileProgress(
                bookFileId: fileId,
                positionData: positionData,
                positionHref: positionHref,
                progressPercent: progressPercent
            ),
            dateFinished: isFinished ? ISO8601DateFormatter().string(from: Date()) : nil
        )
        var request = try makeRequest("/api/v1/books/progress")
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await performAuthorizedRequest(request)
        guard (200...204).contains(response.statusCode) else {
            throw ProviderError.serverError(
                "Failed to sync Booklore progress (HTTP \(response.statusCode))"
            )
        }
        AppLogger.network.debug(
            "[Booklore] Pushed audiobook progress bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) percentage=\(progressPercent)"
        )
        return fraction
    }

    static func audiobookFileId(from sessionId: String?) -> Int? {
        guard let sessionId, sessionId.hasPrefix("grimmory_") else { return nil }
        let parts = sessionId.split(separator: "_")
        guard parts.count >= 3, let fileId = Int(parts[2]), fileId > 0 else { return nil }
        return fileId
    }

    private static func resourcePercentage(from locator: String?) -> Double? {
        guard let data = locator?.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let locations = object["locations"] as? [String: Any],
            let progression = (locations["progression"] as? NSNumber)?.doubleValue
        else {
            return nil
        }
        return min(max(progression, 0), 1) * 100
    }

    static func decodeAudiobookProgress(
        _ data: Data,
        for book: Book
    ) -> ProviderAudiobookProgress? {
        guard let payload = try? JSONDecoder().decode(AudiobookProgressPayload.self, from: data) else {
            return nil
        }

        let progress = payload.audiobookProgress
        let readState = ProviderReadState(serverValue: payload.readStatus)
        let percentage = progress?.percentage ?? payload.readProgress ?? (readState.isFinished ? 100 : 0)
        let fraction = Book.normalizedFractionProgress(percentage) ?? 0
        guard fraction > 0 || readState.isFinished || readState.isAbandoned || readState == .notReading else {
            return nil
        }

        let trackIndex = progress?.trackIndex
        let positionMilliseconds = progress?.positionMs ?? 0
        let serverDuration = payload.durationSeconds.map(Double.init) ?? payload.duration
        let positionSeconds: TimeInterval
        if let trackIndex, trackIndex > 0 {
            if let chapters = book.chapters, trackIndex < chapters.count {
                positionSeconds = chapters[trackIndex].start + positionMilliseconds / 1_000
            } else if let duration = book.duration, duration > 0 {
                positionSeconds = fraction * duration
            } else if let serverDuration, serverDuration > 0 {
                positionSeconds = fraction * serverDuration
            } else {
                positionSeconds = 0
            }
        } else if positionMilliseconds > 0 {
            positionSeconds = positionMilliseconds / 1_000
        } else if let serverDuration, serverDuration > 0 {
            positionSeconds = fraction * serverDuration
        } else if let duration = book.duration, duration > 0 {
            positionSeconds = fraction * duration
        } else {
            positionSeconds = 0
        }

        AppLogger.network.debug(
            "[Booklore] Received audiobook progress bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) percentage=\(percentage) positionSeconds=\(positionSeconds)"
        )
        return ProviderAudiobookProgress(
            positionSeconds: positionSeconds,
            percentage: fraction,
            trackIndex: trackIndex,
            updatedAt: parseTimestamp(payload.lastReadTime ?? progress?.updatedAt),
            readState: readState
        )
    }

    static func parseTimestamp(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }

        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSSS",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss.SSS",
            "yyyy-MM-dd HH:mm:ss",
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }

        if let epoch = Double(value) {
            return Date(timeIntervalSince1970: epoch > 1_000_000_000_000 ? epoch / 1_000 : epoch)
        }
        return nil
    }

    private func resolveAudiobookFileId(
        for book: Book,
        bookId: String,
        sessionId: String?
    ) async -> Int? {
        if let fileId = Self.audiobookFileId(from: sessionId) {
            cacheAudiobookFileId(fileId, for: book.id)
            return fileId
        }
        if let fileId = audiobookFileIds[book.id], fileId > 0 {
            return fileId
        }

        guard let result = try? await performAuthorizedRequest(
            try makeRequest("/api/v1/audiobooks/\(bookId)/info")
        ),
            result.1.statusCode == 200,
            let info = try? JSONDecoder().decode(AudiobookInfo.self, from: result.0),
            let fileId = info.bookFileId,
            fileId > 0
        else {
            return nil
        }
        cacheAudiobookFileId(fileId, for: book.id)
        return fileId
    }
}

@MainActor
final class BookloreReadingSessionClient {
    typealias RequestBuilder = (String) throws -> URLRequest
    typealias AuthorizedRequest = (URLRequest) async throws -> (Data, HTTPURLResponse)

    private struct EbookSessionRequest: Encodable {
        let bookId: Int
        let bookType: String
        let startTime: String
        let endTime: String
        let durationSeconds: Int
        let startProgress: Double
        let endProgress: Double
        let progressDelta: Double
        let startLocation: String?
        let endLocation: String?
    }

    private struct AudiobookSessionRequest: Encodable {
        let bookId: Int
        let bookType: String
        let startTime: String
        let endTime: String
        let durationSeconds: Int
        let durationFormatted: String
        let startProgress: Double
        let endProgress: Double
        let progressDelta: Double
        let startLocation: String
        let endLocation: String
    }

    private struct SessionPage: Decodable {
        let content: [GrimmoryReadingSessionEntry]
    }

    private let makeRequest: RequestBuilder
    private let performAuthorizedRequest: AuthorizedRequest
    private let now: () -> Date

    init(
        makeRequest: @escaping RequestBuilder,
        performAuthorizedRequest: @escaping AuthorizedRequest,
        now: @escaping () -> Date = Date.init
    ) {
        self.makeRequest = makeRequest
        self.performAuthorizedRequest = performAuthorizedRequest
        self.now = now
    }

    func uploadEbookSession(
        for book: Book,
        bookId: Int,
        startDate: Date,
        startProgress: Double,
        endProgress: Double,
        locator: String?
    ) async throws {
        let endDate = now()
        let durationSeconds = max(1, Int(endDate.timeIntervalSince(startDate).rounded()))
        guard durationSeconds >= 5 else { return }

        let startPercent = min(max(startProgress, 0), 1) * 100
        let endPercent = min(max(endProgress, 0), 1) * 100
        let progressDelta = endPercent - startPercent
        let endLocation = Self.locationValue(from: locator)
        let startLocation: Int? = {
            guard let endLocation else { return nil }
            if endPercent > 0 {
                return max(1, Int((Double(endLocation) * (startPercent / endPercent)).rounded()))
            }
            let estimated = endLocation - Int(
                (progressDelta / 100 * Double(max(endLocation, 1))).rounded()
            )
            return max(1, estimated)
        }()
        let body = EbookSessionRequest(
            bookId: bookId,
            bookType: Self.ebookType(for: book),
            startTime: Self.sessionFormatter.string(from: startDate),
            endTime: Self.sessionFormatter.string(from: endDate),
            durationSeconds: durationSeconds,
            startProgress: Self.roundedPercentage(startPercent),
            endProgress: Self.roundedPercentage(endPercent),
            progressDelta: Self.roundedPercentage(progressDelta),
            startLocation: startLocation.map(String.init),
            endLocation: endLocation.map(String.init)
        )

        var request = try makeRequest("/api/v1/reading-sessions")
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await performAuthorizedRequest(request)
        let diagnosticID = DiagnosticLogSanitizer.identifier(for: book.stableId)
        if (200...202).contains(response.statusCode) {
            AppLogger.network.debug(
                "[Booklore] Uploaded ebook reading session bookDiagnosticID=\(diagnosticID) durationSeconds=\(durationSeconds)"
            )
        } else {
            AppLogger.network.error(
                "[Booklore] Ebook reading session upload failed bookDiagnosticID=\(diagnosticID) status=\(response.statusCode)"
            )
        }
    }

    func uploadAudiobookSession(
        for book: Book,
        bookId: Int,
        currentTime: TimeInterval,
        duration: TimeInterval,
        timeListened: TimeInterval
    ) async throws {
        let listenedSeconds = max(1, Int(timeListened.rounded()))
        let clampedEndTime = min(max(currentTime, 0), duration)
        let startPosition = max(0, clampedEndTime - timeListened)
        let startProgress = Self.percentage(position: startPosition, duration: duration)
        let endProgress = Self.percentage(position: clampedEndTime, duration: duration)
        let endTime = now()
        let startTime = endTime.addingTimeInterval(-Double(listenedSeconds))
        let body = AudiobookSessionRequest(
            bookId: bookId,
            bookType: "AUDIOBOOK",
            startTime: Self.preciseFormatter.string(from: startTime),
            endTime: Self.preciseFormatter.string(from: endTime),
            durationSeconds: listenedSeconds,
            durationFormatted: Self.formattedDuration(listenedSeconds),
            startProgress: startProgress,
            endProgress: endProgress,
            progressDelta: endProgress - startProgress,
            startLocation: String(max(0, Int((startPosition * 1_000).rounded()))),
            endLocation: String(max(0, Int((clampedEndTime * 1_000).rounded())))
        )

        var request = try makeRequest("/api/v1/reading-sessions")
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await performAuthorizedRequest(request)
        guard (200...202).contains(response.statusCode) else {
            throw ProviderError.serverError(
                "Failed to sync Booklore reading session (HTTP \(response.statusCode))"
            )
        }
        AppLogger.network.debug(
            "[Booklore] Uploaded audiobook reading session bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) durationSeconds=\(listenedSeconds)"
        )
    }

    func fetchSessions(bookIds: [Int], limit: Int) async -> [GrimmoryReadingSessionEntry] {
        let pageSize = min(max(limit, 1), 100)
        var entries: [GrimmoryReadingSessionEntry] = []

        for bookId in bookIds {
            guard var request = try? makeRequest("/api/v1/reading-sessions/book/\(bookId)") else {
                continue
            }
            if var components = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) {
                components.queryItems = (components.queryItems ?? []) + [
                    URLQueryItem(name: "page", value: "0"),
                    URLQueryItem(name: "size", value: String(pageSize)),
                ]
                request.url = components.url
            }
            guard let (data, response) = try? await performAuthorizedRequest(request),
                response.statusCode == 200,
                let page = try? JSONDecoder().decode(SessionPage.self, from: data)
            else {
                continue
            }
            entries.append(contentsOf: page.content)
        }

        return Array(
            entries.sorted { Self.date(from: $0.startTime) > Self.date(from: $1.startTime) }
                .prefix(limit)
        )
    }

    private static func ebookType(for book: Book) -> String {
        if let url = book.ebookFileURL ?? book.filePath.map({ URL(fileURLWithPath: $0) }) {
            switch url.pathExtension.lowercased() {
            case "cbz", "cbr", "cb7": return "CBX"
            case "azw": return "AZW3"
            case let fileExtension where !fileExtension.isEmpty:
                return fileExtension.uppercased()
            default:
                break
            }
        }
        return "EPUB"
    }

    private static func locationValue(from locator: String?) -> Int? {
        guard let data = locator?.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        if let page = json["page"] as? Int {
            return page
        }
        return (json["locations"] as? [String: Any])?["position"] as? Int
    }

    private static func percentage(position: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return roundedPercentage(min(max(position / duration, 0), 1) * 100)
    }

    private static func roundedPercentage(_ percentage: Double) -> Double {
        (percentage * 10).rounded() / 10
    }

    private static func formattedDuration(_ durationSeconds: Int) -> String {
        let hours = durationSeconds / 3_600
        let minutes = (durationSeconds % 3_600) / 60
        let seconds = durationSeconds % 60
        var parts: [String] = []
        if hours > 0 {
            parts.append("\(hours)h")
        }
        if minutes > 0 || hours > 0 {
            parts.append("\(minutes)m")
        }
        parts.append("\(seconds)s")
        return parts.joined(separator: " ")
    }

    private static func date(from value: String) -> Date {
        preciseFormatter.date(from: value)
            ?? sessionFormatter.date(from: value)
            ?? .distantPast
    }

    private static let preciseFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let sessionFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

struct GrimmoryCatalogCheckpoint: Codable {
    let version: Int
    let connectionId: UUID
    let libraryId: String
    let serverIdentity: String
    let totalPages: Int
    let totalElements: Int
    let pageSize: Int
    let firstPageFingerprint: String
    var completedPages: Set<Int>
    var committedPages: Set<Int>?
    var reconciliationGeneration: Int?
    var existingCountBefore: Int?
    var committedBookCount: Int?
    var updatedAt: Date
}

enum GrimmoryCatalogCheckpointStore {
    private static let version = 1
    private static let manifestFilename = "manifest.json"

    static func prepare(
        connectionId: UUID,
        libraryId: String,
        serverIdentity: String,
        totalPages: Int,
        totalElements: Int,
        pageSize: Int,
        firstPageFingerprint: String,
        firstPageData: Data
    ) throws -> (checkpoint: GrimmoryCatalogCheckpoint, resumed: Bool) {
        let directory = directoryURL(connectionId: connectionId, libraryId: libraryId)
        let existing = loadManifest(at: directory)
        let canResume = existing.map {
            $0.version == version
                && $0.connectionId == connectionId
                && $0.libraryId == libraryId
                && $0.serverIdentity == serverIdentity
                && $0.totalPages == totalPages
                && $0.totalElements == totalElements
                && $0.pageSize == pageSize
                && $0.firstPageFingerprint == firstPageFingerprint
        } ?? false

        if !canResume {
            try? FileManager.default.removeItem(at: directory)
        }
        try createDirectoryIfNeeded(directory)

        var checkpoint: GrimmoryCatalogCheckpoint
        if canResume, let existing {
            checkpoint = existing
        } else {
            checkpoint = GrimmoryCatalogCheckpoint(
                version: version,
                connectionId: connectionId,
                libraryId: libraryId,
                serverIdentity: serverIdentity,
                totalPages: totalPages,
                totalElements: totalElements,
                pageSize: pageSize,
                firstPageFingerprint: firstPageFingerprint,
                completedPages: [],
                committedPages: [],
                reconciliationGeneration: nil,
                existingCountBefore: nil,
                committedBookCount: 0,
                updatedAt: Date()
            )
        }
        try firstPageData.write(to: pageURL(0, in: directory), options: .atomic)
        checkpoint.completedPages.insert(0)
        checkpoint.updatedAt = Date()
        try saveManifest(checkpoint, at: directory)
        return (checkpoint, canResume)
    }

    static func pageData(connectionId: UUID, libraryId: String, page: Int) throws -> Data {
        try Data(contentsOf: pageURL(page, in: directoryURL(connectionId: connectionId, libraryId: libraryId)))
    }

    static func recordPage(
        _ data: Data,
        page: Int,
        checkpoint: inout GrimmoryCatalogCheckpoint
    ) throws {
        let directory = directoryURL(connectionId: checkpoint.connectionId, libraryId: checkpoint.libraryId)
        try data.write(to: pageURL(page, in: directory), options: .atomic)
        checkpoint.completedPages.insert(page)
        checkpoint.updatedAt = Date()
        try saveManifest(checkpoint, at: directory)
    }

    static func discardPage(page: Int, checkpoint: inout GrimmoryCatalogCheckpoint) {
        let directory = directoryURL(connectionId: checkpoint.connectionId, libraryId: checkpoint.libraryId)
        try? FileManager.default.removeItem(at: pageURL(page, in: directory))
        checkpoint.completedPages.remove(page)
        checkpoint.updatedAt = Date()
        try? saveManifest(checkpoint, at: directory)
    }

    static func bindReconciliation(
        _ reconciliation: ReconciliationStart,
        checkpoint: inout GrimmoryCatalogCheckpoint
    ) throws {
        checkpoint.reconciliationGeneration = reconciliation.generation
        checkpoint.existingCountBefore = reconciliation.existingCount
        checkpoint.committedPages = []
        checkpoint.committedBookCount = 0
        checkpoint.updatedAt = Date()
        try saveManifest(
            checkpoint,
            at: directoryURL(connectionId: checkpoint.connectionId, libraryId: checkpoint.libraryId)
        )
    }

    static func markCommitted(
        pages: [Int],
        bookCount: Int,
        checkpoint: inout GrimmoryCatalogCheckpoint
    ) throws {
        var committed = checkpoint.committedPages ?? []
        committed.formUnion(pages)
        checkpoint.committedPages = committed
        checkpoint.committedBookCount = (checkpoint.committedBookCount ?? 0) + bookCount
        checkpoint.updatedAt = Date()
        try saveManifest(
            checkpoint,
            at: directoryURL(connectionId: checkpoint.connectionId, libraryId: checkpoint.libraryId)
        )
    }

    static func clear(connectionId: UUID, libraryId: String) {
        try? FileManager.default.removeItem(at: directoryURL(connectionId: connectionId, libraryId: libraryId))
    }

    static func pendingConnectionIds() -> Set<UUID> {
        let root = rootDirectoryURL()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result = Set<UUID>()
        for case let url as URL in enumerator where url.lastPathComponent == manifestFilename {
            guard let data = try? Data(contentsOf: url),
                let checkpoint = try? JSONDecoder().decode(GrimmoryCatalogCheckpoint.self, from: data),
                checkpoint.version == version
            else { continue }
            result.insert(checkpoint.connectionId)
        }
        return result
    }

    private static func loadManifest(at directory: URL) -> GrimmoryCatalogCheckpoint? {
        let url = directory.appendingPathComponent(manifestFilename, isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GrimmoryCatalogCheckpoint.self, from: data)
    }

    private static func saveManifest(_ checkpoint: GrimmoryCatalogCheckpoint, at directory: URL) throws {
        let data = try JSONEncoder().encode(checkpoint)
        try data.write(to: directory.appendingPathComponent(manifestFilename, isDirectory: false), options: .atomic)
    }

    private static func createDirectoryIfNeeded(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
    }

    private static func rootDirectoryURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GrimmoryCatalogCheckpoints", isDirectory: true)
    }

    private static func directoryURL(connectionId: UUID, libraryId: String) -> URL {
        let digest = SHA256.hash(data: Data("\(connectionId.uuidString):\(libraryId)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return rootDirectoryURL().appendingPathComponent(digest, isDirectory: true)
    }

    private static func pageURL(_ page: Int, in directory: URL) -> URL {
        directory.appendingPathComponent("page-\(page).json", isDirectory: false)
    }
}
