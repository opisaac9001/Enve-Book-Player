import Foundation
import Testing

@testable import enve

@MainActor
struct BookloreReadingSessionClientTests {
    @Test func ebookSessionEncodesProgressAndPageLocations() async throws {
        var capturedRequest: URLRequest?
        let now = Date(timeIntervalSince1970: 1_000)
        let client = Self.makeClient(now: now) { request in
            capturedRequest = request
            return (Data(), Self.response(for: request, statusCode: 201))
        }
        let book = Self.book(id: "42", mediaType: .ebook)

        try await client.uploadEbookSession(
            for: book,
            bookId: 42,
            startDate: now.addingTimeInterval(-10),
            startProgress: 0.1,
            endProgress: 0.4,
            locator: "{\"page\":40}"
        )

        let request = try #require(capturedRequest)
        #expect(request.url?.path == "/api/v1/reading-sessions")
        #expect(request.httpMethod == "POST")
        let root = try Self.jsonBody(from: request)
        #expect(root["bookId"] as? Int == 42)
        #expect(root["bookType"] as? String == "EPUB")
        #expect(root["durationSeconds"] as? Int == 10)
        #expect(root["startProgress"] as? Double == 10)
        #expect(root["endProgress"] as? Double == 40)
        #expect(root["progressDelta"] as? Double == 30)
        #expect(root["startLocation"] as? String == "10")
        #expect(root["endLocation"] as? String == "40")
    }

    @Test func shortEbookSessionDoesNotIssueRequest() async throws {
        var requestCount = 0
        let now = Date(timeIntervalSince1970: 1_000)
        let client = Self.makeClient(now: now) { request in
            requestCount += 1
            return (Data(), Self.response(for: request, statusCode: 201))
        }

        try await client.uploadEbookSession(
            for: Self.book(id: "42", mediaType: .ebook),
            bookId: 42,
            startDate: now.addingTimeInterval(-4),
            startProgress: 0.1,
            endProgress: 0.2,
            locator: nil
        )

        #expect(requestCount == 0)
    }

    @Test func audiobookSessionEncodesListeningWindow() async throws {
        var capturedRequest: URLRequest?
        let now = Date(timeIntervalSince1970: 1_000)
        let client = Self.makeClient(now: now) { request in
            capturedRequest = request
            return (Data(), Self.response(for: request, statusCode: 200))
        }

        try await client.uploadAudiobookSession(
            for: Self.book(id: "42", mediaType: .audiobook),
            bookId: 42,
            currentTime: 40,
            duration: 100,
            timeListened: 10
        )

        let request = try #require(capturedRequest)
        let root = try Self.jsonBody(from: request)
        #expect(root["bookType"] as? String == "AUDIOBOOK")
        #expect(root["durationSeconds"] as? Int == 10)
        #expect(root["durationFormatted"] as? String == "10s")
        #expect(root["startProgress"] as? Double == 30)
        #expect(root["endProgress"] as? Double == 40)
        #expect(root["progressDelta"] as? Double == 10)
        #expect(root["startLocation"] as? String == "30000")
        #expect(root["endLocation"] as? String == "40000")
    }

    @Test func fetchedSessionsAreSortedAndLimitedAcrossBooks() async {
        var requestedSizes: [String?] = []
        let client = Self.makeClient(now: .distantPast) { request in
            requestedSizes.append(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "size" })?.value
            )
            let bookId = Int(request.url!.lastPathComponent)!
            let startTime = bookId == 1
                ? "2026-08-20T12:00:00Z"
                : "2026-08-21T12:00:00Z"
            let data = Data(
                "{\"content\":[{\"bookId\":\(bookId),\"startTime\":\"\(startTime)\"}]}".utf8
            )
            return (data, Self.response(for: request, statusCode: 200))
        }

        let sessions = await client.fetchSessions(bookIds: [1, 2], limit: 1)

        #expect(requestedSizes == ["1", "1"])
        #expect(sessions.map { $0.bookId } == [2])
    }

    private static func makeClient(
        now: Date,
        perform: @escaping BookloreReadingSessionClient.AuthorizedRequest
    ) -> BookloreReadingSessionClient {
        BookloreReadingSessionClient(
            makeRequest: { path in
                URLRequest(url: URL(string: "https://example.invalid\(path)")!)
            },
            performAuthorizedRequest: perform,
            now: { now }
        )
    }

    private static func book(id: String, mediaType: AppMediaType) -> Book {
        Book(
            id: id,
            title: "Reading Session Fixture",
            source: .booklore,
            mediaType: mediaType,
            providerId: UUID(),
            libraryId: "tests"
        )
    }

    private static func response(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private static func jsonBody(from request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
