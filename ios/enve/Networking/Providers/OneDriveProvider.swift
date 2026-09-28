import AVFoundation
import Foundation
import Logging

struct OneDriveBrowserItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isFolder: Bool
    let size: Int64?
    let modifiedAt: Date?

    var isSupportedBookFile: Bool {
        guard !isFolder else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return AudiobookFormat.from(fileExtension: ext) != nil
            || EbookFormat.from(fileExtension: ext) != nil
            || ext == "zip"
    }
}

struct OneDriveAccount: Sendable {
    let driveId: String
    let displayName: String
    let driveName: String
}

enum OneDriveError: LocalizedError {
    case notAuthenticated
    case invalidResponse
    case unsupportedItem
    case missingDownloadURL
    case graph(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: "Sign in to OneDrive again."
        case .invalidResponse: "OneDrive returned an invalid response."
        case .unsupportedItem: "That OneDrive item is not a supported book file."
        case .missingDownloadURL: "OneDrive did not provide a download link for this file."
        case .graph(let message): message
        }
    }
}

@MainActor
final class OneDriveProvider: WholeSnapshotCatalogProvider, PlaybackSessionProvider, EbookDownloadProvider,
    @unchecked Sendable
{
    var connection: ServerConnection

    var capabilities: ProviderCapabilities {
        [.fullImport, .downloads]
    }

    private let session: URLSession
    private let oauthManager: OAuthManager
    private let tokenStorage: SecureTokenStorage
    private var token: OAuthToken?

    private static let graphBaseURL = URL(string: "https://graph.microsoft.com/v1.0")!
    private static let maximumCatalogItems = 1_000_000

    init(
        connection: ServerConnection,
        session: URLSession = .shared,
        oauthManager: OAuthManager = .shared,
        tokenStorage: SecureTokenStorage = .shared,
        initialToken: OAuthToken? = nil
    ) {
        self.connection = connection
        self.session = session
        self.oauthManager = oauthManager
        self.tokenStorage = tokenStorage
        token = initialToken ?? (try? tokenStorage.loadToken(forProvider: tokenStorageKey))
    }

    var authenticationState: AuthenticationState {
        guard let token else { return .notAuthenticated }
        return token.isExpired ? .tokenExpired : .authenticated
    }

    func authenticate() async throws -> OneDriveAccount {
        let authorized = try await oauthManager.authorize(config: .oneDrive())
        token = authorized
        try tokenStorage.saveToken(authorized, forProvider: tokenStorageKey)
        let account = try await fetchAccount()
        connection.userId = account.driveId
        connection.username = account.displayName
        connection.isConnected = true
        connection.lastVerified = Date()
        connection.authMode = .sso
        return account
    }

    func refreshAuthentication() async throws {
        let storedToken = try tokenStorage.loadToken(forProvider: tokenStorageKey)
        guard let stored = token ?? storedToken,
            let refreshToken = stored.refreshToken
        else {
            throw OneDriveError.notAuthenticated
        }
        let refreshed = try await oauthManager.refreshToken(refreshToken: refreshToken, config: .oneDrive())
        token = refreshed
        try tokenStorage.saveToken(refreshed, forProvider: tokenStorageKey)
    }

    func signOut() throws {
        token = nil
        try tokenStorage.deleteToken(forProvider: tokenStorageKey)
    }

    static func deleteCredentials(connectionId: UUID) {
        try? SecureTokenStorage.shared.deleteToken(forProvider: tokenStorageKey(connectionId: connectionId))
    }

    static func moveCredentials(from sourceId: UUID, to destinationId: UUID) throws {
        guard sourceId != destinationId else { return }
        let storage = SecureTokenStorage.shared
        let sourceKey = tokenStorageKey(connectionId: sourceId)
        guard let token = try storage.loadToken(forProvider: sourceKey) else { return }
        try storage.saveToken(token, forProvider: tokenStorageKey(connectionId: destinationId))
        try storage.deleteToken(forProvider: sourceKey)
    }

    func validateConnection() async throws -> Bool {
        let account = try await fetchAccount()
        connection.userId = account.driveId
        connection.username = account.displayName
        return true
    }

    func fetchAccount() async throws -> OneDriveAccount {
        let drive: GraphDrive = try await request(
            path: "/me/drive",
            queryItems: [URLQueryItem(name: "$select", value: "id,name,driveType,owner")]
        )
        let displayName = drive.owner?.user?.displayName ?? drive.owner?.group?.displayName ?? "Microsoft account"
        return OneDriveAccount(driveId: drive.id, displayName: displayName, driveName: drive.name ?? "OneDrive")
    }

    func rootBrowserItem() async throws -> OneDriveBrowserItem {
        try browserItem(from: await item(path: "/me/drive/root"))
    }

    func listBrowserItems(folderId: String?) async throws -> [OneDriveBrowserItem] {
        let path = folderId.map { "/me/drive/items/\(encodedPathComponent($0))/children" } ?? "/me/drive/root/children"
        return try await listAll(path: path)
            .map(browserItem(from:))
            .filter { $0.isFolder || $0.isSupportedBookFile }
            .sorted {
                if $0.isFolder != $1.isFolder { return $0.isFolder }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    func search(_ query: String) async throws -> [OneDriveBrowserItem] {
        let escaped = query.replacingOccurrences(of: "'", with: "''")
        let path = "/me/drive/root/search(q='\(escaped)')"
        return try await listAll(path: path)
            .map(browserItem(from:))
            .filter { $0.isFolder || $0.isSupportedBookFile }
    }

    func fetchLibraries() async throws -> [Library] {
        let selectedIds = connection.selectedLibraryIds ?? []
        if selectedIds.isEmpty {
            let root = try await item(path: "/me/drive/root")
            return [library(from: root)]
        }

        var libraries: [Library] = []
        for id in selectedIds {
            let selected = try await item(path: "/me/drive/items/\(encodedPathComponent(id))")
            guard selected.folder != nil else { continue }
            libraries.append(library(from: selected))
        }
        return libraries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func fetchBooks(libraryId: String) async throws -> [Book] {
        let root = try await item(path: "/me/drive/items/\(encodedPathComponent(libraryId))")
        let catalog = try await scanCatalog(root: root)
        return makeBooks(catalog: catalog, library: library(from: root))
    }

    func fetchRecentBooks(libraryId: String, limit: Int) async throws -> [Book] {
        let books = try await fetchBooks(libraryId: libraryId)
        return Array(books.sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }.prefix(limit))
    }

    func fetchCollections(libraryId: String?) async throws -> [Collection] { [] }

    func fetchSeries(libraryId: String) async throws -> [Series] { [] }

    func fetchUserMediaProgress(libraryId: String) async throws -> [UserMediaProgress] { [] }

    func fetchFullBookDetails(bookId: String, libraryId: String) async throws -> Book {
        guard var book = await AppState.shared.bookStore.book(byBookId: bookId) else {
            throw ProviderError.invalidResponse
        }
        guard book.mediaType == .audiobook else { return book }

        let playbackSession = try await startPlaybackSession(for: book)
        book.duration = playbackSession.audioTracks.totalDuration
        book.chapters = playbackSession.chapters

        if playbackSession.audioTracks.count == 1,
            let url = URL(string: playbackSession.audioTracks[0].contentUrl),
            let embedded = await MetadataLayeringManager.shared.extractEmbeddedChapters(from: url),
            !embedded.isEmpty
        {
            book.chapters = embedded
        }
        return book
    }

    func getAudioURL(for book: Book) -> URL? {
        guard let contentURL = book.audioTracks?.first?.contentUrl else { return nil }
        return URL(string: contentURL)
    }

    func chapterExtractionURL(for book: Book) -> URL? {
        getAudioURL(for: book)
    }

    func getStreamingHeaders() -> [String: String] { [:] }

    func startPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo {
        let storedTracks = book.audioTracks ?? []
        guard !storedTracks.isEmpty else { throw ProviderError.invalidResponse }

        var tracks: [AudioTrackInfo] = []
        var chapters: [Chapter] = []
        var offset: TimeInterval = 0

        for (index, stored) in storedTracks.enumerated() {
            guard let itemId = stored.filePath else { continue }
            let fresh = try await item(path: "/me/drive/items/\(encodedPathComponent(itemId))")
            guard let downloadURL = fresh.downloadURL.flatMap(URL.init(string:)) else {
                throw OneDriveError.missingDownloadURL
            }
            let duration = await mediaDuration(url: downloadURL)
            let title = stored.title ?? (fresh.name as NSString).deletingPathExtension
            tracks.append(
                AudioTrackInfo(
                    id: fresh.id,
                    index: index,
                    startOffset: offset,
                    duration: duration,
                    contentUrl: downloadURL.absoluteString,
                    mimeType: fresh.file?.mimeType ?? "audio/mpeg",
                    title: title
                )
            )
            chapters.append(
                Chapter(
                    id: fresh.id,
                    start: offset,
                    end: offset + duration,
                    title: title,
                    index: index
                )
            )
            offset += duration
        }

        guard !tracks.isEmpty else { throw ProviderError.invalidResponse }
        return PlaybackSessionInfo(sessionId: "onedrive-\(UUID().uuidString)", audioTracks: tracks, chapters: chapters)
    }

    func downloadEbook(for book: Book, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        guard book.mediaType == .ebook, let itemId = book.filePath else {
            throw OneDriveError.unsupportedItem
        }
        let remote = try await item(path: "/me/drive/items/\(encodedPathComponent(itemId))")
        guard let downloadURL = remote.downloadURL.flatMap(URL.init(string:)) else {
            throw OneDriveError.missingDownloadURL
        }

        onProgress?(0)
        let (temporaryURL, response) = try await session.download(from: downloadURL)
        try validate(response: response, data: nil)
        onProgress?(1)
        return try LocalEbookImporter.shared.cacheRemoteEbook(
            tempURL: temporaryURL,
            preferredFilename: remote.name,
            bookIdentifier: book.id
        )
    }

    private var tokenStorageKey: String {
        Self.tokenStorageKey(connectionId: connection.id)
    }

    private static func tokenStorageKey(connectionId: UUID) -> String {
        "onedrive-\(connectionId.uuidString.lowercased())"
    }

    private func library(from item: GraphItem) -> Library {
        Library(id: item.id, name: item.name, type: "onedrive", providerId: connection.id)
    }

    private func browserItem(from item: GraphItem) -> OneDriveBrowserItem {
        OneDriveBrowserItem(
            id: item.id,
            name: item.name,
            isFolder: item.folder != nil,
            size: item.size,
            modifiedAt: item.lastModifiedDateTime.flatMap(Self.date(from:))
        )
    }

    private func scanCatalog(root: GraphItem) async throws -> ScannedCatalog {
        var folders: [String: GraphItem] = [root.id: root]
        var files: [GraphItem] = []
        var pendingFolderIds = [root.id]
        var processed = 0

        while let folderId = pendingFolderIds.popLast() {
            try Task.checkCancellation()
            let children = try await listAll(path: "/me/drive/items/\(encodedPathComponent(folderId))/children")
            processed += children.count
            guard processed <= Self.maximumCatalogItems else {
                throw OneDriveError.graph("OneDrive stopped a runaway scan after \(Self.maximumCatalogItems) items.")
            }
            for child in children {
                if child.folder != nil {
                    folders[child.id] = child
                    pendingFolderIds.append(child.id)
                } else if isSupportedFile(child.name) {
                    files.append(child)
                }
            }
        }
        return ScannedCatalog(root: root, folders: folders, files: files)
    }

    private func makeBooks(catalog: ScannedCatalog, library: Library) -> [Book] {
        let audioFiles = catalog.files.filter { AudiobookFormat.from(fileExtension: fileExtension($0.name)) != nil }
        let ebookFiles = catalog.files.filter { EbookFormat.from(fileExtension: fileExtension($0.name)) != nil }
        let groupedAudio = Dictionary(grouping: audioFiles) { $0.parentReference?.id ?? catalog.root.id }
        let backendId = connection.userId ?? connection.id.uuidString
        var books: [Book] = []

        for (folderId, unsortedFiles) in groupedAudio {
            let files = unsortedFiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            guard let first = files.first else { continue }
            let folderName = catalog.folders[folderId]?.name
            let title = files.count == 1
                ? (first.name as NSString).deletingPathExtension
                : (folderName ?? library.name)
            let tracks = files.enumerated().map { index, file in
                AudioTrack(
                    id: file.id,
                    index: index,
                    title: (file.name as NSString).deletingPathExtension,
                    filePath: file.id,
                    contentUrl: file.downloadURL,
                    duration: 0,
                    startOffset: 0,
                    fileSize: file.size,
                    format: fileExtension(file.name),
                    headers: nil
                )
            }
            books.append(
                Book(
                    id: "audio:\(folderId)",
                    ratingKey: folderId,
                    title: title,
                    source: .oneDrive,
                    backendId: backendId,
                    trackIndex: 0,
                    filePath: folderId,
                    audioTracks: tracks,
                    addedAt: files.compactMap { $0.lastModifiedDateTime.flatMap(Self.date(from:)) }.max(),
                    libraryName: library.name,
                    backendName: connection.name,
                    providerId: connection.id,
                    libraryId: library.id
                )
            )
        }

        for file in ebookFiles {
            let title = (file.name as NSString).deletingPathExtension
            books.append(
                Book(
                    id: "ebook:\(file.id)",
                    ratingKey: file.id,
                    title: title,
                    source: .oneDrive,
                    backendId: backendId,
                    trackIndex: nil,
                    filePath: file.id,
                    mediaType: .ebook,
                    ebookFormat: fileExtension(file.name),
                    addedAt: file.lastModifiedDateTime.flatMap(Self.date(from:)),
                    libraryName: library.name,
                    backendName: connection.name,
                    providerId: connection.id,
                    libraryId: library.id
                )
            )
        }

        return books.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func item(path: String) async throws -> GraphItem {
        try await request(
            path: path,
            queryItems: [
                URLQueryItem(
                    name: "$select",
                    value: "id,name,size,file,folder,parentReference,lastModifiedDateTime,@microsoft.graph.downloadUrl"
                )
            ]
        )
    }

    private func listAll(path: String) async throws -> [GraphItem] {
        var nextURL = try makeURL(
            path: path,
            queryItems: [
                URLQueryItem(
                    name: "$select",
                    value: "id,name,size,file,folder,parentReference,lastModifiedDateTime,@microsoft.graph.downloadUrl"
                ),
                URLQueryItem(name: "$top", value: "200"),
            ]
        )
        var items: [GraphItem] = []

        while true {
            let page: GraphItemPage = try await request(url: nextURL)
            items.append(contentsOf: page.value)
            guard let next = page.nextLink, let url = URL(string: next) else { break }
            nextURL = url
        }
        return items
    }

    private func request<Response: Decodable>(path: String, queryItems: [URLQueryItem] = []) async throws -> Response {
        try await request(url: makeURL(path: path, queryItems: queryItems))
    }

    private func request<Response: Decodable>(url: URL, mayRefresh: Bool = true, mayRetryThrottle: Bool = true) async throws -> Response {
        guard url.scheme == Self.graphBaseURL.scheme, url.host == Self.graphBaseURL.host else {
            throw OneDriveError.invalidResponse
        }
        let validToken = try await accessToken()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(validToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode == 401, mayRefresh {
            try await refreshAuthentication()
            return try await self.request(url: url, mayRefresh: false, mayRetryThrottle: mayRetryThrottle)
        }
        if let http = response as? HTTPURLResponse, http.statusCode == 429, mayRetryThrottle {
            let seconds = min(TimeInterval(http.value(forHTTPHeaderField: "Retry-After") ?? "1") ?? 1, 30)
            try await Task.sleep(for: .seconds(seconds))
            return try await self.request(url: url, mayRefresh: mayRefresh, mayRetryThrottle: false)
        }

        try validate(response: response, data: data)
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw OneDriveError.invalidResponse
        }
    }

    private func accessToken() async throws -> String {
        if token == nil {
            token = try tokenStorage.loadToken(forProvider: tokenStorageKey)
        }
        guard let current = token else { throw OneDriveError.notAuthenticated }
        if current.isExpired {
            try await refreshAuthentication()
        }
        guard let refreshed = token else { throw OneDriveError.notAuthenticated }
        return refreshed.accessToken
    }

    private func validate(response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw OneDriveError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 { throw OneDriveError.notAuthenticated }
            if http.statusCode == 403 { throw OneDriveError.graph("This Microsoft account did not grant access to its OneDrive files.") }
            if http.statusCode == 404 { throw OneDriveError.graph("That OneDrive file or folder no longer exists.") }
            if http.statusCode == 429 { throw OneDriveError.graph("OneDrive is temporarily limiting requests. Try again shortly.") }
            let message = data.flatMap { try? JSONDecoder().decode(GraphErrorEnvelope.self, from: $0).error.message }
            throw OneDriveError.graph(message ?? "OneDrive request failed (HTTP \(http.statusCode)).")
        }
    }

    private func makeURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: Self.graphBaseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw ProviderError.invalidURL
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw ProviderError.invalidURL }
        return url
    }

    private func encodedPathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private func isSupportedFile(_ name: String) -> Bool {
        let ext = fileExtension(name)
        return AudiobookFormat.from(fileExtension: ext) != nil || EbookFormat.from(fileExtension: ext) != nil
    }

    private func fileExtension(_ name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }

    private func mediaDuration(url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    private static let graphDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func date(from value: String) -> Date? {
        graphDateFormatter.date(from: value) ?? ISO8601DateFormatter.shared.date(from: value)
    }

    private struct ScannedCatalog {
        let root: GraphItem
        let folders: [String: GraphItem]
        let files: [GraphItem]
    }

    private struct GraphDrive: Decodable {
        let id: String
        let name: String?
        let owner: GraphIdentitySet?
    }

    private struct GraphIdentitySet: Decodable {
        let user: GraphIdentity?
        let group: GraphIdentity?
    }

    private struct GraphIdentity: Decodable {
        let displayName: String?
    }

    private struct GraphItemPage: Decodable {
        let value: [GraphItem]
        let nextLink: String?

        private enum CodingKeys: String, CodingKey {
            case value
            case nextLink = "@odata.nextLink"
        }
    }

    private struct GraphItem: Decodable {
        let id: String
        let name: String
        let size: Int64?
        let file: GraphFile?
        let folder: GraphFolder?
        let parentReference: GraphParentReference?
        let lastModifiedDateTime: String?
        let downloadURL: String?

        private enum CodingKeys: String, CodingKey {
            case id, name, size, file, folder, parentReference, lastModifiedDateTime
            case downloadURL = "@microsoft.graph.downloadUrl"
        }
    }

    private struct GraphFile: Decodable {
        let mimeType: String?
    }

    private struct GraphFolder: Decodable {
        let childCount: Int?
    }

    private struct GraphParentReference: Decodable {
        let id: String?
        let driveId: String?
        let path: String?
    }

    private struct GraphErrorEnvelope: Decodable {
        let error: GraphError
    }

    private struct GraphError: Decodable {
        let code: String?
        let message: String
    }
}
