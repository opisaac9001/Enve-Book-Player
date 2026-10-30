import Foundation
import Testing

@testable import enve

nonisolated private final class CloudDriveProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == "/oauth2/token" || url.path == "/token" {
            respond(["access_token": "renewed", "expires_in": 3600, "token_type": "Bearer"])
            return
        }
        let auth = request.value(forHTTPHeaderField: "Authorization")
        guard auth == "Bearer fixture" || auth == "Bearer renewed" else {
            respond([:], status: 401)
            return
        }
        if url.host == "www.googleapis.com" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if query.contains(where: { $0.name == "pageToken" }) {
                respond(["files": [["id": "pdf", "name": "Guide.pdf", "mimeType": "application/pdf"]]])
            } else {
                respond([
                    "files": [
                        ["id": "folder", "name": "Books", "mimeType": "application/vnd.google-apps.folder"],
                        ["id": "epub", "name": "Novel.epub", "mimeType": "application/octet-stream"],
                        ["id": "audio", "name": "Story.m4b", "mimeType": "application/octet-stream"],
                        ["id": "ignored", "name": "notes.txt", "mimeType": "text/plain"],
                    ],
                    "nextPageToken": "next",
                ])
            }
            return
        }
        switch url.path {
        case "/2/files/list_folder":
            respond(["entries": [entry("folder", "Books", folder: true), entry("audio", "Story.m4b")], "cursor": "next", "has_more": true])
        case "/2/files/list_folder/continue":
            respond(["entries": [entry("ebook", "Novel.epub"), entry("ignored", "notes.txt")], "cursor": "end", "has_more": false])
        case "/2/files/search_v2":
            respond(["matches": [["metadata": [".tag": "metadata", "metadata": entry("ebook", "Novel.epub")]]], "has_more": false])
        case "/2/files/get_temporary_link":
            respond(["link": "https://dl.dropboxusercontent.com/example/book.epub"])
        default:
            respond([:], status: 404)
        }
    }

    private func entry(_ id: String, _ name: String, folder: Bool = false) -> [String: Any] {
        [".tag": folder ? "folder" : "file", "id": id, "name": name, "path_display": "/Books/\(name)", "size": 20]
    }

    private func respond(_ body: [String: Any], status: Int = 200) {
        let data = try! JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
struct CloudDriveImportTests {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudDriveProtocol.self]
        return URLSession(configuration: config)
    }

    private func credentials(provider: String, expired: Bool = false) throws -> SecureTokenStorage {
        let storage = SecureTokenStorage(profileID: UUID().uuidString)
        try storage.saveToken(OAuthToken(
            accessToken: "fixture", refreshToken: "fixture-refresh", expiresIn: expired ? -1 : 3600,
            tokenType: "Bearer", scope: nil, issuedAt: Date()
        ), forProvider: provider)
        return storage
    }

    @Test func driveListsAllPagesAndKeepsEbooksWithGenericMIME() async throws {
        let storage = try credentials(provider: "google-drive")
        defer { try? storage.clearAll() }
        let provider = GoogleDriveProvider(tokenStorage: storage, session: session())
        #expect(provider.authenticationState == .authenticated)
        let items = try await provider.listRoot()
        #expect(Set(items.map(\.id)) == ["folder", "epub", "audio", "pdf"])
        let resolved = try await provider.resolveFile(try #require(items.first { $0.id == "epub" }))
        #expect(resolved.requiresAuthHeader)
        #expect(resolved.authHeaderValue == "Bearer fixture")
        #expect(resolved.streamURL?.path == "/drive/v3/files/epub")
    }

    @Test func driveEscapesQuerySyntax() {
        #expect(GoogleDriveProvider.escapeQueryLiteral("Sam's \\ books") == "Sam\\'s \\\\ books")
    }

    @Test func driveRenewsAnExpiredSavedConnection() async throws {
        let storage = try credentials(provider: "google-drive", expired: true)
        defer { try? storage.clearAll() }
        let session = session()
        let provider = GoogleDriveProvider(oauthManager: OAuthManager(session: session), tokenStorage: storage, session: session)
        #expect(provider.authenticationState == .tokenExpired)
        _ = try await provider.listRoot()
        #expect(provider.authenticationState == .authenticated)
        #expect(try storage.loadToken(forProvider: "google-drive")?.refreshToken == "fixture-refresh")
    }

    @Test func dropboxListsFoldersAndAllFilePages() async throws {
        let storage = try credentials(provider: "dropbox")
        defer { try? storage.clearAll() }
        let provider = DropboxProvider(tokenStorage: storage, session: session())
        #expect(provider.authenticationState == .authenticated)
        let items = try await provider.listRoot()
        #expect(Set(items.map(\.id)) == ["folder", "audio", "ebook"])
        #expect(items.first?.isFolder == true)
        let results = try await provider.search("Novel")
        #expect(results.map(\.name) == ["Novel.epub"])
        let resolved = try await provider.resolveFile(try #require(results.first))
        #expect(resolved.streamURL?.host == "dl.dropboxusercontent.com")
        #expect(!resolved.requiresAuthHeader)
        #expect(resolved.authHeaderValue == nil)
        try await provider.signOut()
        #expect(provider.authenticationState == .notAuthenticated)
        #expect(try storage.loadToken(forProvider: "dropbox") == nil)
    }

    @Test func dropboxRenewsExpiredTokenAndPreservesRefreshCredential() async throws {
        let storage = try credentials(provider: "dropbox", expired: true)
        defer { try? storage.clearAll() }
        let session = session()
        let provider = DropboxProvider(oauthManager: OAuthManager(session: session), tokenStorage: storage, session: session)
        _ = try await provider.listRoot()
        #expect(provider.authenticationState == .authenticated)
        #expect(try storage.loadToken(forProvider: "dropbox")?.refreshToken == "fixture-refresh")
    }

    @Test func providerCredentialsAreIsolated() async throws {
        let first = try credentials(provider: "dropbox")
        let second = SecureTokenStorage(profileID: UUID().uuidString)
        defer { try? first.clearAll(); try? second.clearAll() }
        #expect(DropboxProvider(tokenStorage: first).authenticationState == .authenticated)
        #expect(DropboxProvider(tokenStorage: second).authenticationState == .notAuthenticated)
    }

    @Test func oauthUsesProviderSpecificOfflineAccess() {
        #expect(OAuthConfig.dropbox().authorizationParameters["token_access_type"] == "offline")
        #expect(OAuthConfig.dropbox().authorizationParameters["access_type"] == nil)
        #expect(OAuthConfig.googleDrive().authorizationParameters["access_type"] == "offline")
        #expect(OAuthConfig.googleDrive().clientSecret == nil)
    }

    @Test func supportedFilesUseExtensionWhenMIMEIsGeneric() {
        #expect(item("audio", "Story.m4b").isSupportedBookFile)
        #expect(item("ebook", "Novel.epub").isSupportedBookFile)
        #expect(item("pdf", "Manual.pdf").isSupportedBookFile)
        #expect(!item("text", "Notes.txt").isSupportedBookFile)
    }

    @Test func stagingKeepsAudioTracksTogetherAndDoesNotMergeSeparateFolders() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let file = source.appendingPathComponent("fixture")
        try Data("fixture".utf8).write(to: file)
        let provider = LocalCloudFixture(file: file)
        let stage = try await CloudBookDownloadService().stage(
            items: [item("1", "01.mp3", parent: "first"), item("2", "02.mp3", parent: "first"), item("3", "01.mp3", parent: "second")],
            provider: provider, progress: { _, _ in }
        )
        defer { stage.remove() }
        #expect(stage.urls.count == 3)
        #expect(stage.urls[0].deletingLastPathComponent() == stage.urls[1].deletingLastPathComponent())
        #expect(stage.urls[0].deletingLastPathComponent() != stage.urls[2].deletingLastPathComponent())
        #expect(try Data(contentsOf: stage.urls[0]) == Data("fixture".utf8))
    }

    @Test func clearingAnUnsubmittedSearchClearsTheField() {
        let model = SourcesCloudDriveModel(
            title: "Fixture", provider: LocalCloudFixture(file: URL(fileURLWithPath: "/unused")),
            downloader: CloudBookDownloadService()
        )
        model.searchText = "unfinished query"
        model.clearSearch()
        #expect(model.searchText.isEmpty)
    }

    @Test func separateImportsDoNotCombineTracksFromTheSameFolder() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("fixture".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let stage = try await CloudBookDownloadService().stage(
            items: [item("1", "01.mp3", parent: "same"), item("2", "02.mp3", parent: "same")],
            provider: LocalCloudFixture(file: source), preserveFolderGrouping: false, progress: { _, _ in }
        )
        defer { stage.remove() }
        #expect(stage.urls[0].deletingLastPathComponent() != stage.urls[1].deletingLastPathComponent())
    }

    private func item(_ id: String, _ name: String, parent: String? = nil) -> RemoteItem {
        RemoteItem(id: id, name: name, isFolder: false, size: nil, mimeType: "application/octet-stream", modifiedDate: nil, pathHint: nil, parentId: parent)
    }
}

@MainActor
private final class LocalCloudFixture: BookSourceProvider {
    let id = "fixture"
    let displayName = "Fixture"
    let iconName = "folder"
    let capabilities: SourceCapabilities = []
    let authenticationState: AuthenticationState = .authenticated
    let file: URL
    init(file: URL) { self.file = file }
    func authenticate() async throws {}
    func refreshAuthentication() async throws {}
    func signOut() async throws {}
    func listRoot() async throws -> [RemoteItem] { [] }
    func listFolder(_ itemId: String) async throws -> [RemoteItem] { [] }
    func search(_ query: String) async throws -> [RemoteItem] { [] }
    func getMetadata(_ item: RemoteItem) async throws -> SourceBookMetadata? { nil }
    func resolveFile(_ item: RemoteItem) async throws -> ResolvedFile {
        ResolvedFile(localURL: file, streamURL: nil, expiresAt: nil, requiresAuthHeader: false, authHeaderValue: nil, contentLength: nil)
    }
}
