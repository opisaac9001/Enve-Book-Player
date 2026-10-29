import Foundation
import Testing

@testable import enve

nonisolated private final class HardcoverRequestProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String] = []
    nonisolated(unsafe) private static var bodies: [Data] = []

    static func reset(_ responses: [String]) {
        lock.withLock {
            self.responses = responses
            bodies = []
        }
    }

    static func requests() throws -> [[String: Any]] {
        try lock.withLock { try bodies.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let responseBody = Self.lock.withLock {
            Self.bodies.append(body)
            return Self.responses.isEmpty ? nil : Self.responses.removeFirst()
        }
        guard let responseBody else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(responseBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
@Suite(.serialized)
struct HardcoverRequestTests {
    private func client(_ responses: [String]) -> (HardcoverService, URLSession) {
        HardcoverRequestProtocol.reset(responses)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HardcoverRequestProtocol.self]
        let session = URLSession(configuration: configuration)
        return (HardcoverService(session: session, pacer: HardcoverRequestPacer(minimumInterval: 0), tokenProvider: { "fixture-token" }), session)
    }

    @Test func identifierLookupUsesVariablesAndPreservesEdition() async throws {
        let (service, session) = client([#"{"data":{"editions":[{"id":91,"book_id":12,"isbn_13":"9780306406157","pages":200,"book":{"id":12,"title":"Fixture"}}]}}"#])
        defer { session.invalidateAndCancel() }
        let edition = try await service.findEdition(identifiers: HardcoverIdentifiers(isbn: "978-0-306-40615-7", asin: nil))
        #expect(edition?.id == 91)
        let request = try #require(HardcoverRequestProtocol.requests().first)
        let variables = try #require(request["variables"] as? [String: Any])
        let filter = try #require(variables["where"] as? [String: Any])
        #expect((filter["_or"] as? [[String: Any]])?.count == 1)
        #expect((request["query"] as? String)?.contains("$where") == true)
    }

    @Test func offlineCompletionSendsOriginalDateAndTimestamp() async throws {
        let (service, session) = client([#"{"data":{"insert_user_book_read":{"error":null,"user_book_read":{"id":71}}}}"#])
        defer { session.invalidateAndCancel() }
        _ = try await service.upsertReadingProgress(userBookId: 12, existingReadId: nil,
            progressPages: 200, isFinished: true, editionId: 91,
            eventDate: "2026-10-01", startDate: "2026-09-28", actionAt: Date(timeIntervalSince1970: 0))
        let request = try #require(HardcoverRequestProtocol.requests().first)
        let variables = try #require(request["variables"] as? [String: Any])
        let read = try #require(variables["read"] as? [String: Any])
        #expect(read["finished_at"] as? String == "2026-10-01")
        #expect(read["started_at"] as? String == "2026-09-28")
        #expect(read["action_at"] as? String == "1970-01-01T00:00:00Z")
    }

    @Test func insertingAudioProgressUsesDocumentedInputAndPreservesSeconds() async throws {
        let (service, session) = client([#"{"data":{"insert_user_book_read":{"error":null,"user_book_read":{"id":71}}}}"#])
        defer { session.invalidateAndCancel() }
        let id = try await service.upsertReadingProgress(userBookId: 12, existingReadId: nil,
            progressPages: 0, progressSeconds: 420, isFinished: false, editionId: 9)
        #expect(id == 71)
        let request = try #require(HardcoverRequestProtocol.requests().first)
        #expect((request["query"] as? String)?.contains("user_book_read: $read") == true)
        let variables = try #require(request["variables"] as? [String: Any])
        let read = try #require(variables["read"] as? [String: Any])
        #expect(read["progress_seconds"] as? Int == 420)
        #expect(read["progress_pages"] == nil)
        #expect(read["edition_id"] as? Int == 9)
        #expect(read["finished_at"] == nil)
    }

    @Test func existingReadIsUpdatedWithoutInsertingAnother() async throws {
        let (service, session) = client([#"{"data":{"update_user_book_read":{"error":null,"user_book_read":{"id":71,"progress_pages":88}}}}"#])
        defer { session.invalidateAndCancel() }
        _ = try await service.upsertReadingProgress(userBookId: 12, existingReadId: 71,
            progressPages: 88, isFinished: true, editionId: 9)
        let request = try #require(HardcoverRequestProtocol.requests().first)
        let query = try #require(request["query"] as? String)
        #expect(query.contains("update_user_book_read(id: 71"))
        #expect(query.contains("finished_at:"))
        #expect(!query.contains("insert_user_book_read"))
    }

    @Test func nestedReadFailureIsPropagated() async throws {
        let (service, session) = client([#"{"data":{"insert_user_book_read":{"error":"Rejected","user_book_read":null}}}"#])
        defer { session.invalidateAndCancel() }
        await #expect(throws: HardcoverError.self) {
            try await service.createReadingSession(userBookId: 12)
        }
    }

    @Test func existingLibraryEntryIsLookedUpByBookInsteadOfRecentShelfLimit() async throws {
        let (service, session) = client([#"{"data":{"me":[{"user_books":[{"id":42,"book_id":9001,"status_id":1}]}]}}"#])
        defer { session.invalidateAndCancel() }
        #expect(try await service.addBookToLibrary(bookId: 9001) == 42)
        let requests = try HardcoverRequestProtocol.requests()
        #expect(requests.count == 1)
        #expect((requests[0]["query"] as? String)?.contains("book_id: {_eq: 9001}") == true)
    }

    @Test func goalUpdatePreservesConditionsAndPrivacy() async throws {
        let (service, session) = client([
            #"{"data":{"me":[{"goals":[{"id":3,"goal":20,"metric":"book","start_date":"2026-01-01","end_date":"2026-12-31","description":"My goal","conditions":{"readingFormatId":2},"privacy_setting_id":3,"progress":7}]}]}}"#,
            #"{"data":{"result":{"id":3,"errors":[]}}}"#
        ])
        defer { session.invalidateAndCancel() }
        try await service.setReadingGoal(target: 30)
        let requests = try HardcoverRequestProtocol.requests()
        #expect((requests[0]["query"] as? String)?.contains("metric: {_eq: \"book\"}") == true)
        #expect((requests[1]["query"] as? String)?.contains("update_goal(id: $id, object: $goal)") == true)
        let variables = try #require(requests[1]["variables"] as? [String: Any])
        let goal = try #require(variables["goal"] as? [String: Any])
        #expect(goal["goal"] as? Int == 30)
        #expect(goal["privacy_setting_id"] as? Int == 3)
        #expect(goal["description"] as? String == "My goal")
        #expect((goal["conditions"] as? [String: Int])?["readingFormatId"] == 2)
    }

    @Test func goalCreationAndNestedErrorsUseCurrentAPI() async throws {
        let (service, session) = client([
            #"{"data":{"me":[{"goals":[]}]}}"#,
            #"{"data":{"result":{"id":null,"errors":["Not permitted"]}}}"#
        ])
        defer { session.invalidateAndCancel() }
        await #expect(throws: HardcoverError.self) { try await service.setReadingGoal(target: 12) }
        let requests = try HardcoverRequestProtocol.requests()
        #expect((requests[1]["query"] as? String)?.contains("insert_goal(object: $goal)") == true)
    }

    @Test func reviewPreservesQuotesAndNewlinesAsVariables() async throws {
        let (service, session) = client([#"{"data":{"update_user_book":{"error":null,"user_book":{"id":42}}}}"#])
        defer { session.invalidateAndCancel() }
        let review = "A \"quote\"\nAnother paragraph"
        try await service.reviewBook(userBookId: 42, reviewText: review)
        let request = try #require(HardcoverRequestProtocol.requests().first)
        let variables = try #require(request["variables"] as? [String: Any])
        #expect((variables["review"] as? [String: String])?["review_markdown"] == review)
    }

    @Test func changedAccountCancelsQueuedSyncBeforeSending() async throws {
        let (service, session) = client([])
        defer { session.invalidateAndCancel() }
        await #expect(throws: CancellationError.self) {
            try await HardcoverService.$syncToken.withValue("previous-token") {
                try await service.createReadingSession(userBookId: 12)
            }
        }
        #expect(try HardcoverRequestProtocol.requests().isEmpty)
    }

    @Test func automaticMatchingRejectsAmbiguousAndPartialTitles() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let book = try decoder.decode(HardcoverBook.self, from: Data(#"{"id":1,"title":"Dune","cached_contributors":"Frank Herbert"}"#.utf8))
        #expect(HardcoverSyncService.bestMatch(title: "DUNE", author: "Frank Herbert", results: [book])?.id == 1)
        #expect(HardcoverSyncService.bestMatch(title: "Dune Messiah", author: "Frank Herbert", results: [book]) == nil)
        #expect(HardcoverSyncService.bestMatch(title: "Dune", author: nil, results: [book]) == nil)
        #expect(HardcoverSyncService.bestMatch(title: "Dune", author: "Frank Herbert", results: [book, book]) == nil)
        #expect(HardcoverSyncService.bestMatch(title: "沙丘", author: "Frank Herbert", results: [book]) == nil)
    }

    @Test func legacyShelfDisplaysAudioProgress() async throws {
        let (service, session) = client([#"{"data":{"me":[{"user_books":[{"id":42,"book_id":1,"status_id":2,"book":{"id":1,"title":"Dune"},"edition":{"id":9,"audio_seconds":1000},"user_book_reads":[{"id":71,"progress_seconds":500}]}]}]}}"#])
        defer { session.invalidateAndCancel() }
        let books = try await service.getUserBooks()
        #expect(books.first?.progressFraction == 0.5)
    }

    @Test func pausedAndIgnoredStatusesArePreserved() {
        #expect(HardcoverReadingStatus(rawValue: 4)?.displayName == "Paused")
        #expect(HardcoverReadingStatus(rawValue: 6)?.displayName == "Ignored")
    }

    @Test func currentReadEditionControlsDisplayedProgress() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let book = try decoder.decode(HardcoverUserBook.self, from: Data(#"{"id":42,"book_id":1,"status_id":2,"edition":{"id":9,"audio_seconds":1000},"user_book_reads":[{"id":71,"progress_seconds":500,"edition":{"id":10,"audio_seconds":2000}}]}"#.utf8))
        #expect(book.progress == 0.25)
    }

    @Test func shelfProgressUsesAudioAndCompletedReads() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let book = try decoder.decode(HardcoverUserBook.self, from: Data(#"{"id":42,"book_id":1,"status_id":2,"edition":{"id":9,"audio_seconds":1000},"user_book_reads":[{"id":71,"progress_pages":0,"progress_seconds":500}]}"#.utf8))
        #expect(book.progress == 0.5)
        let finished = try decoder.decode(HardcoverUserBook.self, from: Data(#"{"id":42,"book_id":1,"status_id":3,"user_book_reads":[{"id":71,"finished_at":"2026-10-27"}]}"#.utf8))
        #expect(finished.progress == 1)
    }
}
