import Foundation
import Testing

@testable import enve

nonisolated private final class OneDriveGraphProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
            request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access"
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
            return
        }

        if url.path == "/forbidden" {
            respond(status: 403, payload: ["error": ["code": "accessDenied", "message": "Access denied"]])
            return
        }

        let payload: Any
        switch url.path {
        case "/v1.0/me/drive":
            payload = [
                "id": "drive-id",
                "name": "Sample OneDrive",
                "driveType": "personal",
                "owner": ["user": ["displayName": "Sample User"]],
            ]
        case "/v1.0/me/drive/root":
            payload = folder(id: "root-id", name: "OneDrive")
        case "/v1.0/me/drive/items/library":
            payload = folder(id: "library", name: "Books")
        case "/v1.0/me/drive/items/library/children":
            payload = [
                "value": [
                    folder(id: "audio-folder", name: "The Audiobook", parentId: "library"),
                    file(id: "ebook", name: "Novel.epub", mime: "application/epub+zip", parentId: "library"),
                    file(id: "ignored", name: "notes.txt", mime: "text/plain", parentId: "library"),
                ],
                "@odata.nextLink": "https://graph.microsoft.com/v1.0/test-next-page",
            ]
        case "/v1.0/test-next-page":
            payload = ["value": []]
        case "/v1.0/me/drive/items/audio-folder/children":
            payload = [
                "value": [
                    file(id: "track-2", name: "02 Closing.mp3", mime: "audio/mpeg", parentId: "audio-folder"),
                    file(id: "track-1", name: "01 Opening.mp3", mime: "audio/mpeg", parentId: "audio-folder"),
                ]
            ]
        case "/v1.0/me/drive/items/unsafe/children":
            payload = [
                "value": [],
                "@odata.nextLink": "https://example.invalid/collect-token",
            ]
        case "/v1.0/me/drive/root/search(q='novel')":
            payload = [
                "value": [
                    file(id: "ebook", name: "Novel.epub", mime: "application/epub+zip", parentId: "library"),
                    file(id: "ignored", name: "notes.txt", mime: "text/plain", parentId: "library"),
                ]
            ]
        case "/v1.0/me/drive/items/track-1":
            payload = file(id: "track-1", name: "01 Opening.mp3", mime: "audio/mpeg", parentId: "audio-folder")
        case "/v1.0/me/drive/items/track-2":
            payload = file(id: "track-2", name: "02 Closing.mp3", mime: "audio/mpeg", parentId: "audio-folder")
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        respond(status: 200, payload: payload)
    }

    override func stopLoading() {}

    private func respond(status: Int, payload: Any) {
        guard let url = request.url else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private func folder(id: String, name: String, parentId: String? = nil) -> [String: Any] {
        var result: [String: Any] = ["id": id, "name": name, "folder": ["childCount": 1]]
        if let parentId { result["parentReference"] = ["id": parentId, "driveId": "drive-id"] }
        return result
    }

    private func file(id: String, name: String, mime: String, parentId: String) -> [String: Any] {
        [
            "id": id,
            "name": name,
            "size": 1_024,
            "file": ["mimeType": mime],
            "parentReference": ["id": parentId, "driveId": "drive-id"],
            "lastModifiedDateTime": "2026-09-26T12:34:56Z",
            "@microsoft.graph.downloadUrl": "https://download.invalid/\(id)",
        ]
    }
}

@MainActor
@Suite(.serialized)
struct OneDriveProviderTests {
    @Test func browsesFoldersAndFiltersUnsupportedFilesAcrossPages() async throws {
        let (provider, session) = makeProvider()
        defer { session.invalidateAndCancel() }

        let account = try await provider.fetchAccount()
        #expect(account.driveId == "drive-id")
        #expect(account.displayName == "Sample User")

        let items = try await provider.listBrowserItems(folderId: "library")
        #expect(items.map(\.name) == ["The Audiobook", "Novel.epub"])
        #expect(items.first?.isFolder == true)
    }

    @Test func mapsSelectedFoldersIntoAudiobooksAndEbooksWithStableItemIds() async throws {
        let (provider, session) = makeProvider()
        defer { session.invalidateAndCancel() }

        let libraries = try await provider.fetchLibraries()
        #expect(libraries.map(\.id) == ["library"])
        #expect(libraries.map(\.name) == ["Books"])

        let books = try await provider.fetchBooks(libraryId: "library")
        #expect(books.count == 2)
        let audiobook = try #require(books.first { $0.mediaType == .audiobook })
        let ebook = try #require(books.first { $0.mediaType == .ebook })
        #expect(audiobook.title == "The Audiobook")
        #expect(audiobook.audioTracks?.map(\.filePath) == ["track-1", "track-2"])
        #expect(audiobook.source == .oneDrive)
        #expect(audiobook.stableId == "onedrive:drive-id:audio:audio-folder")
        #expect(ebook.title == "Novel")
        #expect(ebook.filePath == "ebook")
        #expect(ebook.ebookFormat == "epub")
    }

    @Test func searchesTheDriveAndFiltersUnsupportedResults() async throws {
        let (provider, session) = makeProvider()
        defer { session.invalidateAndCancel() }

        let results = try await provider.search("novel")
        #expect(results.map(\.name) == ["Novel.epub"])
    }

    @Test func refusesCrossOriginPaginationLinksBeforeSendingTheBearerToken() async throws {
        let (provider, session) = makeProvider()
        defer { session.invalidateAndCancel() }

        await #expect(throws: OneDriveError.self) {
            _ = try await provider.listBrowserItems(folderId: "unsafe")
        }
    }

    @Test func declaresReadOnlyOAuthAndHonestCapabilities() {
        let config = OAuthConfig.oneDrive()
        #expect(config.clientSecret == nil)
        #expect(config.usePKCE)
        #expect(config.scopes.contains("Files.Read"))
        #expect(config.scopes.contains("offline_access"))
        #expect(!config.scopes.contains("Files.ReadWrite"))

        let (provider, session) = makeProvider()
        defer { session.invalidateAndCancel() }
        #expect(provider.capabilities == [.fullImport, .downloads])
        #expect(provider.syncCapability == .none)
    }

    private func makeProvider() -> (OneDriveProvider, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OneDriveGraphProtocol.self]
        let session = URLSession(configuration: configuration)
        let token = OAuthToken(
            accessToken: "fixture-access",
            refreshToken: "fixture-refresh",
            expiresIn: 3_600,
            tokenType: "Bearer",
            scope: "Files.Read",
            issuedAt: Date()
        )
        let connection = ServerConnection(
            name: "OneDrive",
            url: "https://graph.microsoft.com/v1.0",
            type: .oneDrive,
            userId: "drive-id",
            isConnected: true,
            selectedLibraryIds: ["library"],
            authMode: .sso
        )
        return (OneDriveProvider(connection: connection, session: session, initialToken: token), session)
    }
}
