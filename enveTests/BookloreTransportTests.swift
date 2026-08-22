import Foundation
import Testing

@testable import enve

struct BookloreTransportTests {
    @Test func requestBuilderAppliesBearerAndCustomHeaders() throws {
        let connection = ServerConnection(
            name: "fixture",
            url: "books.example.test/",
            type: .booklore,
            token: "header.payload.signature",
            customHeaders: ["X-Custom": "value"]
        )
        let request = try BookloreTransport(connection: connection).makeRequest(
            connection: connection,
            path: "/api/books",
            queryItems: [URLQueryItem(name: "page", value: "2")]
        )
        #expect(request.url?.absoluteString == "http://books.example.test/api/books?page=2")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer header.payload.signature")
        #expect(request.value(forHTTPHeaderField: "X-Custom") == "value")
    }

    @Test func unauthenticatedRequestDropsOnlyAuthorizationHeader() throws {
        let connection = ServerConnection(
            name: "fixture",
            url: "https://books.example.test",
            type: .booklore,
            customHeaders: ["Authorization": "private", "CF-Access-Client-Id": "client"]
        )
        let request = try BookloreTransport(connection: connection).makeRequest(
            connection: connection,
            path: "/api/auth/login",
            method: "POST",
            body: Data(),
            contentType: "application/json",
            includeAuth: false
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "client")
        #expect(request.httpMethod == "POST")
    }

    @Test func basicFallbackIsExplicit() throws {
        let connection = ServerConnection(
            name: "fixture",
            url: "https://books.example.test",
            type: .booklore,
            username: "reader",
            password: "secret"
        )
        let request = try BookloreTransport(connection: connection).makeRequest(
            connection: connection,
            path: "/api/ping",
            allowBasicFallback: true
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic cmVhZGVyOnNlY3JldA==")
    }
}
