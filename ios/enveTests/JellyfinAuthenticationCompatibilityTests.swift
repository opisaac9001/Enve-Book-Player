import Foundation
import Testing

@testable import enve

private final class JellyfinAuthenticationCompatibilityStub: JellyfinProvider, @unchecked Sendable {
    var requests: [URLRequest] = []
    var status = 200
    var views = #"{"Items":[{"Id":"library","Name":"Fixture","Type":"CollectionFolder","CollectionType":"books"}],"TotalRecordCount":1}"#
    var items = #"{"Items":[{"Id":"book","Name":"Fixture","Type":"AudioBook","IsFolder":false}],"TotalRecordCount":1}"#

    override func performDataTask(for request: URLRequest, retryCount: Int = 3) async throws -> (Data, URLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        let body = url.path.hasSuffix("/Views")
            ? views
            : items
        return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
    }
}

@MainActor
struct JellyfinAuthenticationCompatibilityTests {
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
                #expect(!error.localizedDescription.contains("private response"))
                #expect(!error.localizedDescription.contains("address"))
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

    private func makeProvider(base: String = "https://fixture.example.invalid") -> JellyfinAuthenticationCompatibilityStub {
        JellyfinAuthenticationCompatibilityStub(connection: ServerConnection(
            name: "Fixture", url: base, type: .jellyfin, token: "fixture-token", userId: "user"
        ))
    }
}
