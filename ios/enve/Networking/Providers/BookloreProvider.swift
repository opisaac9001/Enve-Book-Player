import AVFoundation
import Combine
import CryptoKit
import Foundation
import Logging
import os.lock
#if canImport(WebKit)
import WebKit
#endif

class BookloreProvider: IncrementalCatalogProvider, RecentCatalogPagingProvider, PlaybackSessionProvider, AudiobookProgressProvider,
    EbookProgressProvider, EngineAwareEbookProgressProvider, EbookDownloadProvider, ComicReadingDirectionProvider, PersonalRatingProvider, SavedBooksProvider, ObservableObject,
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

    #if !os(tvOS)
    let cloudflareRefresh: CloudflareSilentRefreshService
    #endif
    private let defaults: UserDefaults
    let keychain: KeychainHelper
    let ebooks: LocalEbookImporter
    let rejectedContent: RejectedContentStore
    let metadataLayering: MetadataLayeringManager
    let metadataManager: MetadataManager
    let catalogCheckpoints: GrimmoryCatalogCheckpointStore
    let certificateTransport: InsecureURLSession
    let isolatesCredentials: Bool
    private var tierUpgradeTask: Task<Void, Never>?
    let transport: BookloreTransport
    lazy var progressClient = BookloreProgressClient(
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
    struct PendingListening: Codable {
        let book: Book
        var seconds: TimeInterval
        var position: TimeInterval
        var duration: TimeInterval
    }
    // Kept on disk so listening that hasn't reached Grimmory yet survives the app closing.
    var pendingListening: [String: PendingListening] {
        get {
            guard let data = defaults.data(forKey: pendingListeningKey) else { return [:] }
            return (try? JSONDecoder().decode([String: PendingListening].self, from: data)) ?? [:]
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: pendingListeningKey)
        }
    }
    private var pendingListeningKey: String { "grimmory.pendingListening.\(connection.id.uuidString)" }
    let maxPendingListening: TimeInterval = 15 * 60
    var pausedListeningBooks: Set<String> = []

    lazy var readingSessionClient = BookloreReadingSessionClient(
        makeRequest: { [unowned self] path in
            try self.makeRequest(path: path)
        },
        performAuthorizedRequest: { [unowned self] request in
            try await self.performAuthorizedRequest(request)
        }
    )
    lazy var playbackClient = BooklorePlaybackClient(
        makeRequest: { [unowned self] path in
            try self.makeRequest(path: path)
        },
        performAuthorizedRequest: { [unowned self] request in
            try await self.performAuthorizedRequest(request)
        }
    )
    let pageSize = 500
    let remoteBrowsePageSize = 50
    let pageConcurrency = 8
    let tierPreference: BookloreTierPreference
    var useKomgaFallback = false
    var useLegacyRestAPI = false
    var useLegacyCatalogFallback = false
    var refreshToken: String?

    var refreshTokenKeychainKey: String {
        "booklore_refresh_\(connection.id.uuidString)"
    }

    func saveRefreshToken(_ token: String?) {
        guard let token, !token.isEmpty else { return }
        refreshToken = token
        keychain.set(token, key: refreshTokenKeychainKey)
    }

    private func loadRefreshTokenFromKeychain() -> String? {
        keychain.get(refreshTokenKeychainKey)
    }

    var onTokenUpdated: ((ServerConnection) -> Void)?

    private var unfairLock = os_unfair_lock()
    var activeLoginTask: Task<Void, Error>?
    var activeRefreshTask: Task<String?, Error>?
    var credentialLoginBlockedUntil: Date?
    var cachedEbookResources: [String: GrimmoryEbookResource] = [:]
    func lockLoginTask() { os_unfair_lock_lock(&unfairLock) }
    func unlockLoginTask() { os_unfair_lock_unlock(&unfairLock) }

    let coverFetchLimiter = ConcurrencyLimiter(maxConcurrent: 2)

    static let missingCoverByteCount = 19071
    static func isMissingCoverPlaceholder(_ data: Data) -> Bool {
        guard data.count == missingCoverByteCount else { return false }
        let digest = Insecure.MD5.hash(data: data).map { String(format: "%02hhx", $0) }.joined()
        return digest == "0951a9fe4dd9ae81c5725c2a79c8bfaa"
    }

    let coverFailureCache = CoverFailureCache()

    let coverCircuitBreaker = CoverCircuitBreaker()

    static var pendingCatalogSyncConnectionIds: Set<UUID> {
        GrimmoryCatalogCheckpointStore().pendingConnectionIds()
    }

    init(connection: ServerConnection = ServerConnection(name: "Grimmory", url: "", type: .booklore), profileSession: ProfileSession? = nil) {
        self.connection = connection
        #if !os(tvOS)
        cloudflareRefresh = CloudflareSilentRefreshService(websiteDataStore: profileSession?.websiteDataStore ?? .default())
        #endif
        defaults = profileSession?.defaults ?? .standard
        keychain = profileSession?.legacyKeychain ?? .shared
        ebooks = profileSession?.ebooks ?? .shared
        rejectedContent = profileSession?.rejectedContent ?? .shared
        metadataLayering = profileSession?.metadataLayering ?? .shared
        metadataManager = profileSession?.metadataManager ?? .shared
        catalogCheckpoints = GrimmoryCatalogCheckpointStore(root: profileSession?.storage.applicationSupportDirectory ?? ProfileStorageLocations.owner.applicationSupportDirectory)
        isolatesCredentials = profileSession?.isOwner == false
        certificateTransport = profileSession?.transport ?? .delegateInstance

        let tierPreference = BookloreTierPreference(connectionId: connection.id, defaults: defaults)
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
        transport = BookloreTransport(connection: connection, profileSession: profileSession)
        transport.setCustomHeadersProvider { [weak self] in self?.connection.customHeaders }

        self.refreshToken = loadRefreshTokenFromKeychain()
        if refreshToken != nil {
            AppLogger.network.info("Restored refresh token from Keychain")
        }

        if restoredTier != nil, tierPreference.consumeUpgradeProbe() {
            tierUpgradeTask = Task { [weak self] in await self?.attemptTierUpgrade() }
        }
    }

    func retire() async {
        onTokenUpdated = nil
        tierUpgradeTask?.cancel()
        activeLoginTask?.cancel()
        activeRefreshTask?.cancel()
        transport.invalidate()
        #if !os(tvOS)
        await cloudflareRefresh.retire()
        #endif
        await tierUpgradeTask?.value
        _ = try? await activeLoginTask?.value
        _ = try? await activeRefreshTask?.value
        tierUpgradeTask = nil
        activeLoginTask = nil
        activeRefreshTask = nil
    }

    func fallbackCoverPath(for bookId: String, mediaType: AppMediaType) -> String {
        switch mediaType {
        case .audiobook:
            return "/api/v1/media/book/\(bookId)/audiobook-thumbnail"
        default:
            return "/api/v1/media/book/\(bookId)/cover"
        }
    }

    func absoluteURL(from value: String?, mediaType: AppMediaType? = nil) -> URL? {
        BookloreBookMapper.absoluteURL(from: value, serverURL: connection.url, mediaType: mediaType)
    }

    func catalogMapperContext(libraryId: String) -> BookloreCatalogMapper.Context {
        BookloreCatalogMapper.Context(
            providerId: connection.id,
            libraryId: libraryId,
            source: .booklore,
            serverURL: connection.url
        )
    }

    func parseDate(_ value: String?) -> Date? {
        FlexibleDate.parse(value)
    }

    func parseDate(_ value: FlexibleDate?) -> Date? {
        return value?.date
    }

    func resolvedFileType(file: BookloreBookFile?) -> String? {
        BookloreBookMapper.resolvedFileType([
            file?.fileType,
            file?.fileExtension,
            file?.bookType,
            BookloreBookMapper.fileExtension(from: file?.fileName),
            BookloreBookMapper.fileExtension(from: file?.filePath),
        ])
    }

    func normalize(_ urlString: String) -> String {
        BookloreBookMapper.normalizedBaseURL(urlString)
    }

    func makeKomgaBasicRequest(path: String, queryItems: [URLQueryItem] = []) throws -> URLRequest {
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

    func guardJSON(_ data: Data, response: HTTPURLResponse, endpoint: String) throws {
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

    func serverErrorMessage(from data: Data) -> String? {
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

    // Dual-format books without their own audiobook art show the ebook cover.

    nonisolated static let companionAudiobookIDPrefix = "grimmory-ab-"

}
