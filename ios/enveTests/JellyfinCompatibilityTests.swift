import Foundation
import Testing

@testable import enve

private final class JellyfinCompatibilityStub: JellyfinProvider, @unchecked Sendable {
    var requests: [URLRequest] = []
    var responses: [(Int, String)] = []
    var status = 200
    var views = #"{"Items":[{"Id":"library","Name":"Fixture","Type":"CollectionFolder","CollectionType":"books"}],"TotalRecordCount":1}"#
    var items = #"{"Items":[{"Id":"book","Name":"Fixture","Type":"AudioBook","IsFolder":false}],"TotalRecordCount":1}"#
    var detail: String?
    var audioChildren = #"{"Items":[],"TotalRecordCount":0}"#

    override func performDataTask(for request: URLRequest, retryCount: Int = 3) async throws -> (Data, URLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        if !responses.isEmpty {
            let (status, body) = responses.removeFirst()
            return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
        }
        let body: String
        if url.path.hasSuffix("/Users/user") {
            body = #"{"Id":"user"}"#
        } else if url.path.hasSuffix("/Views") {
            body = views
        } else if url.path.hasSuffix("/Items") {
            let types = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "IncludeItemTypes" }?.value
            body = types == "Audio" ? audioChildren : items
        } else {
            body = detail ?? items
        }
        return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
    }
}

@MainActor
struct JellyfinCompatibilityTests {
    @Test(arguments: ["https://fixture.example.invalid", "https://fixture.example.invalid/jellyfin", "https://fixture.example.invalid/jellyfin/"])
    func catalogAndHeaderlessMediaUseSupportedAuthentication(base: String) async throws {
        let provider = makeProvider(base: base)
        #expect(try await provider.validateConnection())
        #expect(try await provider.fetchLibraries().count == 1)
        let books = try await provider.fetchBooks(libraryId: "library")
        let book = try #require(books.first)
        let prefix = base.contains("/jellyfin") ? "/jellyfin" : ""
        #expect(provider.requests.map { $0.url!.path } == ["\(prefix)/Users/user", "\(prefix)/Users/user/Views", "\(prefix)/Users/user/Items"])
        for request in provider.requests {
            let auth = try #require(request.value(forHTTPHeaderField: "Authorization"))
            #expect(auth.hasPrefix("MediaBrowser "))
            #expect(auth.contains("Token=\"fixture-token\""))
            #expect(!request.url!.absoluteString.contains("fixture-token"))
        }
        let url = try #require(provider.getAudioURL(for: book))
        #expect(url.path == "\(prefix)/Audio/book/stream")
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.first { $0.name == "ApiKey" }?.value == "fixture-token")
        #expect(!query.contains { $0.name == "api_key" })
        #expect(provider.getStreamingHeaders()["Authorization"]?.contains("Token=\"fixture-token\"") == true)
    }

    @Test func expiredSessionRenewsOnceWithTheSavedPassword() async throws {
        let provider = makeProvider()
        provider.connection.username = "reader"
        provider.connection.password = "fixture-password"
        provider.connection.customHeaders = ["X-Proxy-Route": "books"]
        provider.responses = [(401, ""), (200, #"{"AccessToken":"fresh","User":{"Id":"user"}}"#)]
        #expect(try await provider.validateConnection())
        #expect(provider.connection.token == "fresh")
        #expect(provider.requests.map { $0.url?.path } == ["/Users/user", "/Users/AuthenticateByName"])
        #expect(provider.requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Proxy-Route") == "books" })
        let data = try #require(provider.requests.last?.httpBody)
        #expect(try JSONDecoder().decode([String: String].self, from: data)["Pw"] == "fixture-password")
    }

    @Test func validationDoesNotSwitchAccountsOrSubmitAnAPIKeyAsAPassword() async throws {
        let provider = makeProvider()
        provider.connection.userId = nil
        provider.connection.username = "reader"
        provider.responses = [(200, #"{"Id":"someone-else","Name":"another user"}"#)]
        #expect(try await !provider.validateConnection())
        #expect(provider.connection.userId == nil)
        provider.responses = [(401, "")]
        #expect(try await !provider.validateConnection())
        #expect(provider.requests.map { $0.url?.path } == ["/Users/Me", "/Users/Me"])
    }

    @Test func temporaryServerFailureDoesNotTriggerPasswordLogin() async throws {
        let provider = makeProvider()
        provider.connection.username = "reader"
        provider.connection.password = "fixture-password"
        provider.responses = [(503, "")]
        #expect(try await !provider.validateConnection())
        #expect(provider.requests.count == 1)
    }

    @Test(arguments: [400, 401, 403, 500])
    func libraryAndItemsHTTPFailuresRemainErrors(status: Int) async throws {
        let provider = makeProvider()
        provider.status = status
        provider.items = "<html>private response with token and address</html>"
        for operation in [0, 1] {
            do {
                if operation == 0 { _ = try await provider.fetchLibraries() }
                else { _ = try await provider.fetchBooks(libraryId: "library") }
                Issue.record("HTTP failure was accepted as a catalog")
            } catch {
                if status == 401 {
                    guard case ProviderError.unauthorized = error else {
                        Issue.record("Expected an authentication error")
                        continue
                    }
                } else {
                    #expect((error as? JellyfinResponseError)?.statusCode == status)
                }
                let failure = LibraryRefreshFailure(providerId: provider.connection.id, libraryId: nil, error: error)
                #expect(failure.statusCode == status)
                #expect(!failure.message.contains("private response"))
                #expect(!failure.message.contains("address"))
            }
        }
    }

    @Test func validEmptyIsAcceptedButMissingOrMalformedItemsAreErrors() async throws {
        let provider = makeProvider()
        provider.items = #"{"Items":[],"TotalRecordCount":0}"#
        #expect(try await provider.fetchBooks(libraryId: "library").isEmpty)
        for body in ["", "{broken", #"{"TotalRecordCount":0}"#] {
            provider.items = body
            await #expect(throws: (any Error).self) { _ = try await provider.fetchBooks(libraryId: "library") }
        }
    }

    @Test func rejectedViewsAreErrorsAndValidEmptyViewsAreAccepted() async throws {
        let provider = makeProvider()
        provider.views = #"{"Items":[{"Id":"broken-view"}],"TotalRecordCount":1}"#
        await #expect(throws: (any Error).self) { _ = try await provider.fetchLibraries() }
        provider.views = #"{"Items":[],"TotalRecordCount":0}"#
        #expect(try await provider.fetchLibraries().isEmpty)
    }

    @Test func coversPreferModernTokenOverStoredPasswordAndLegacyCustomHeaders() {
        var connection = ServerConnection(name: "Fixture", url: "https://fixture.example.invalid/jellyfin",
            type: .jellyfin, username: "fixture-user", password: "fixture-password", token: "fixture-token")
        connection.authMode = .usernamePassword
        connection.customHeaders = ["authorization": "stale", "X-Emby-Token": "stale", "X-Proxy-Custom": "preserved"]
        let headers = CachedAsyncCoverImage.authHeaders(for: connection)
        #expect(headers["Authorization"]?.hasPrefix("MediaBrowser ") == true)
        #expect(headers["Authorization"]?.contains("Token=\"fixture-token\"") == true)
        #expect(headers["X-Proxy-Custom"] == "preserved")
        #expect(!headers.keys.contains { $0.lowercased().hasPrefix("x-emby-") || $0 == "authorization" })
    }

    @Test func failurePresentationIsSafeAndScoped() {
        let id = UUID()
        let failure = LibraryRefreshFailure(providerId: id, libraryId: "one",
            error: ProviderError.serverError("https://private.invalid?ApiKey=credential response-body"))
        #expect(failure.statusCode == nil)
        #expect(!failure.message.contains("credential"))
        #expect(!failure.message.contains("private.invalid"))
        #expect(failure.matches(.all))
        #expect(failure.matches(.connection(id)))
        #expect(failure.matches(.library(providerId: id, libraryId: "one")))
        #expect(!failure.matches(.library(providerId: id, libraryId: "two")))
        #expect(!failure.matches(.connection(UUID())))
        #expect(!failure.matches(.device))
    }

    @Test func ebookAuthorsFallBackToAuthorPeopleWhenArtistFieldsAreBlank() async throws {
        let provider = makeProvider()
        provider.items = #"""
            {"Items":[{"Id":"ebook","Name":"Ancillary Justice","Type":"Book","IsFolder":false,"AlbumArtist":" ",
            "People":[{"Name":"Ann Leckie","Type":"Author"},{"Name":"  ","Type":"Author"},{"Name":"Ann Leckie","Type":"Author"},
            {"Name":"Second Writer","Type":"Author"},{"Name":"An Editor","Type":"Editor"}]}],"TotalRecordCount":1}
            """#
        let book = try #require(try await provider.fetchBooks(libraryId: "library").first)
        #expect(book.mediaType == .ebook)
        #expect(book.author == "Ann Leckie, Second Writer")

        provider.items = #"{"Items":[{"Id":"ebook","Name":"Untitled","Type":"Book","People":[{"Name":"","Type":"Author"}]}],"TotalRecordCount":1}"#
        #expect(try await provider.fetchBooks(libraryId: "library").first?.author == "Unknown Author")
    }

    @Test func audiobookArtistFieldsStillTakePrecedenceOverAuthorPeople() async throws {
        let provider = makeProvider()
        provider.items = #"""
            {"Items":[{"Id":"book","Name":"Fixture","Type":"AudioBook","AlbumArtist":"Album Author",
            "People":[{"Name":"Person Author","Type":"Author"},{"Name":"Narrator","Type":"Composer"}]}],"TotalRecordCount":1}
            """#
        let book = try #require(try await provider.fetchBooks(libraryId: "library").first)
        #expect(book.author == "Album Author")
        #expect(book.narrator == "Narrator")
    }

    @Test func ebookDetailsSkipAudioChildAndStreamProbing() async throws {
        let provider = makeProvider()
        provider.detail = #"""
            {"Id":"ebook","Name":"Ancillary Justice","Type":"Book","IsFolder":false,"RunTimeTicks":0,
            "People":[{"Name":"Ann Leckie","Type":"Author"}]}
            """#
        let book = try await provider.fetchFullBookDetails(bookId: "ebook", libraryId: "library")
        #expect(book.mediaType == .ebook)
        #expect(book.author == "Ann Leckie")
        #expect((book.chapters ?? []).isEmpty)
        #expect(provider.requests.map { $0.url!.path } == ["/Users/user/Items/ebook"])
        #expect(!provider.requests.contains { $0.url!.path.contains("/Audio/") })
    }

    @Test func multiFileAudiobookDetailsStillMapChildTracksToChapters() async throws {
        let provider = makeProvider()
        provider.detail = #"{"Id":"book","Name":"Fixture","Type":"AudioBook","IsFolder":true}"#
        provider.audioChildren = #"""
            {"Items":[{"Id":"t1","Name":"Part 1","Type":"Audio","RunTimeTicks":600000000},
            {"Id":"t2","Name":"Part 2","Type":"Audio","RunTimeTicks":300000000}],"TotalRecordCount":2}
            """#
        let book = try await provider.fetchFullBookDetails(bookId: "book", libraryId: "library")
        #expect(book.mediaType == .audiobook)
        #expect(book.chapters?.map(\.id) == ["t1", "t2"])
        #expect(book.duration == 90)
    }

    @Test(arguments: [
        ("books", LibraryType.books), ("Books", .books), ("audiobooks", .audiobooks),
        ("movies", .movies), ("tvshows", .tvshows), ("music", .music), (nil, .mixed),
    ] as [(String?, LibraryType)])
    func serviceMapsCollectionTypesToLibraryTypes(collectionType: String?, expected: LibraryType) {
        #expect(JellyfinService.libraryType(forCollectionType: collectionType) == expected)
    }

    private func makeProvider(base: String = "https://fixture.example.invalid") -> JellyfinCompatibilityStub {
        JellyfinCompatibilityStub(connection: ServerConnection(
            name: "Fixture", url: base, type: .jellyfin, token: "fixture-token", userId: "user"
        ))
    }
}
