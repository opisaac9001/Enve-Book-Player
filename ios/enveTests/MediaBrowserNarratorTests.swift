import Foundation
import Testing

@testable import enve

// Trimmed from the lab "Narrated Regression" fixture (AlbumArtist "Enve Test Author", composer tag "Nora Narrator").
nonisolated private let jellyfinAudiobookPage = #"""
{"Items":[{"Name":"Narrated Regression","Id":"75272fbf2473a3a94d7d9580d20656c5","RunTimeTicks":600000000,"IsFolder":false,
"ParentId":"80612dc44eef8c2cce264db3ad51f778","Type":"AudioBook",
"People":[{"Name":"Nora Narrator","Id":"36b8f6851f86cfebf19a5b22edab5e6c","Role":"","Type":"Composer"}],
"UserData":{"PlaybackPositionTicks":0,"PlayCount":0,"IsFavorite":false,"Played":false},
"Artists":["Enve Test Author"],"ArtistItems":[{"Name":"Enve Test Author","Id":"5750d0cbf908f672686f43a2d714e25e"}],
"Album":"Narrated Regression","AlbumArtist":"Enve Test Author",
"AlbumArtists":[{"Name":"Enve Test Author","Id":"5750d0cbf908f672686f43a2d714e25e"}],
"ImageTags":{},"MediaType":"Audio"}],"TotalRecordCount":1}
"""#

nonisolated private let embyMusicAlbumPage = #"""
{"Items":[{"Name":"Narrated Regression","Id":"149","RunTimeTicks":600000000,"IsFolder":true,"Type":"MusicAlbum",
"UserData":{"PlaybackPositionTicks":0,"PlayCount":0,"IsFavorite":false,"Played":false},
"Artists":["Enve Test Author"],"ArtistItems":[{"Name":"Enve Test Author","Id":"148"}],
"Composers":[{"Name":"Nora Narrator","Id":"151"}],
"AlbumArtist":"Enve Test Author","AlbumArtists":[{"Name":"Enve Test Author","Id":"148"}],"ImageTags":{}}],
"TotalRecordCount":1}
"""#

private final class JellyfinCatalogStub: JellyfinProvider, @unchecked Sendable {
    var requests: [URLRequest] = []

    override func performDataTask(for request: URLRequest, retryCount: Int = 3) async throws -> (Data, URLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        return (Data(jellyfinAudiobookPage.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
}

nonisolated private final class EmbyCatalogProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestedFields: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let fields = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "Fields" }?.value
        Self.requestedFields.append(fields ?? "")
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(embyMusicAlbumPage.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
struct MediaBrowserNarratorTests {
    @Test func jellyfinNarratorComesFromComposerPerson() async throws {
        let provider = JellyfinCatalogStub(connection: ServerConnection(
            name: "Fixture", url: "https://jellyfin.example.invalid", type: .jellyfin, token: "fixture", userId: "user"
        ))
        let books = try await provider.fetchBooks(libraryId: "1b4a4fff275e3e309300c7caa9d253bf")
        let book = try #require(books.first)
        #expect(book.author == "Enve Test Author")
        #expect(book.narrator == "Nora Narrator")
        let fields = try #require(provider.requests.first?.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "Fields" }?.value
        })
        #expect(fields.split(separator: ",").contains("People"))
    }

    @Test func embyNarratorComesFromComposers() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EmbyCatalogProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        EmbyCatalogProtocol.requestedFields = []
        let provider = EmbyProvider(
            connection: ServerConnection(name: "Fixture", url: "https://emby.example.invalid", type: .emby, token: "fixture", userId: "user"),
            session: session
        )
        let books = try await provider.fetchBooks(libraryId: "3")
        let book = try #require(books.first)
        #expect(book.author == "Enve Test Author")
        #expect(book.narrator == "Nora Narrator")
        #expect(EmbyCatalogProtocol.requestedFields.first?.split(separator: ",").contains("Composers") == true)
    }
}
