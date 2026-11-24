import Foundation
import Testing

@testable import enve

nonisolated private final class BookOrbitWidgetProtocol: URLProtocol, @unchecked Sendable {
    nonisolated struct Reply {
        let status: Int
        let json: String
    }

    nonisolated final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String: [Reply]] = [:]
        private var requests: [String: [URLRequest]] = [:]

        func install(_ replies: [Reply], host: String) {
            lock.withLock { self.replies[host] = replies; requests[host] = [] }
        }

        func remove(_ host: String) {
            lock.withLock { replies.removeValue(forKey: host); requests.removeValue(forKey: host) }
        }

        func recorded(_ host: String) -> [URLRequest] {
            lock.withLock { requests[host] ?? [] }
        }

        func next(_ request: URLRequest) -> Reply {
            lock.withLock {
                let host = request.url!.host!
                requests[host, default: []].append(request)
                guard replies[host]?.isEmpty == false else { return Reply(status: 500, json: "{}") }
                return replies[host]!.removeFirst()
            }
        }
    }

    static let store = Store()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            recorded.httpBody = data
        }
        let reply = Self.store.next(recorded)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
struct BookOrbitWidgetTests {
    private struct Fixture {
        let host = UUID().uuidString.lowercased() + ".bookorbit.invalid"
        let session: URLSession
        let provider: BookOrbitProvider

        init(_ replies: [BookOrbitWidgetProtocol.Reply]) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [BookOrbitWidgetProtocol.self]
            session = URLSession(configuration: configuration)
            provider = BookOrbitProvider(connection: ServerConnection(
                name: "Fixture", url: "https://\(host)", type: .bookOrbit, token: "fixture-token"
            ), session: session)
            BookOrbitWidgetProtocol.store.install(replies, host: host)
        }

        var requests: [URLRequest] { BookOrbitWidgetProtocol.store.recorded(host) }

        func close() {
            session.invalidateAndCancel()
            BookOrbitWidgetProtocol.store.remove(host)
        }
    }

    private static func batch(_ type: String, data: String) -> BookOrbitWidgetProtocol.Reply {
        .init(status: 200, json: "{\"items\":[{\"type\":\"\(type)\",\"data\":\(data),\"failed\":false}]}")
    }

    @Test func allRestrictedWidgetsUseAuthenticatedBatchRequests() async throws {
        let types = ["currently-reading", "reading-streak", "reading-goal", "year-projection", "monthly-challenge", "highlight-of-the-day"]
        let fixture = Fixture([
            Self.batch(types[0], data: "{\"books\":[{\"bookId\":41,\"progress\":42}]}"),
            Self.batch(types[1], data: "{\"currentStreak\":3,\"longestStreak\":7,\"lastSevenDays\":[true]}"),
            Self.batch(types[2], data: "{\"goalBooks\":12,\"completedBooks\":3,\"year\":2026}"),
            Self.batch(types[3], data: "{\"projectedBooks\":20,\"projectedPages\":1000,\"projectedHours\":30,\"booksCompletedYtd\":3,\"daysRemaining\":40,\"trend\":\"steady\"}"),
            Self.batch(types[4], data: "{\"challengeType\":\"books\",\"title\":\"Read\",\"description\":\"Read books\",\"progress\":1,\"target\":2,\"completed\":false,\"month\":11,\"year\":2026}"),
            Self.batch(types[5], data: "{\"text\":\"Highlight\",\"bookId\":41,\"createdAt\":\"2026-11-20T01:00:00Z\"}"),
        ])
        defer { fixture.close() }

        let progress = try await fixture.provider.fetchUserMediaProgress(libraryId: "1")
        #expect(progress.first?.libraryItemId == "41")
        #expect(progress.first?.progress == 0.42)
        #expect(try await fixture.provider.fetchReadingStreakWidget().currentStreak == 3)
        #expect(try await fixture.provider.fetchReadingGoalWidget().completedBooks == 3)
        #expect(try await fixture.provider.fetchYearProjectionWidget().projectedBooks == 20)
        #expect(try await fixture.provider.fetchMonthlyChallengeWidget().target == 2)
        let highlight = try #require(await fixture.provider.fetchHighlightOfTheDayWidget())
        #expect(highlight.text == "Highlight")
        #expect(highlight.createdAt == ISO8601Timestamp.parse("2026-11-20T01:00:00Z"))
        #expect(fixture.requests.count == types.count)
        for (request, type) in zip(fixture.requests, types) {
            #expect(request.url?.path == "/api/v1/dashboard/widgets/batch")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
            let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: [String]]
            #expect(body == ["widgets": [type]])
        }
    }

    @Test(arguments: [404, 405]) func olderServersFallBackToIndividualWidgets(status: Int) async throws {
        let fixture = Fixture([
            .init(status: status, json: "{}"),
            .init(status: 200, json: "{\"books\":[{\"bookId\":41,\"progress\":42}]}"),
            .init(status: status, json: "{}"),
            .init(status: 200, json: "null"),
        ])
        defer { fixture.close() }
        #expect(try await fixture.provider.fetchUserMediaProgress(libraryId: "1").first?.progress == 0.42)
        #expect(try await fixture.provider.fetchHighlightOfTheDayWidget() == nil)
        #expect(fixture.requests.map { $0.url!.lastPathComponent } == ["batch", "currently-reading", "batch", "highlight-of-the-day"])
        #expect(fixture.requests.map(\.httpMethod) == ["POST", "GET", "POST", "GET"])
    }

    @Test(arguments: [403, 429, 500]) func serverFailuresDoNotTryRestrictedRoutes(status: Int) async {
        let fixture = Fixture([.init(status: status, json: "{\"message\":\"Server refused request\"}")])
        defer { fixture.close() }
        await #expect(throws: (any Error).self) {
            _ = try await fixture.provider.fetchUserMediaProgress(libraryId: "1")
        }
        #expect(fixture.requests.count == 1)
    }

    @Test(arguments: [
        "{\"items\":[{\"type\":\"currently-reading\",\"data\":null,\"failed\":true}]}",
        "{\"items\":[]}",
        "{\"items\":[{\"type\":\"wrong-widget\",\"data\":{\"books\":[]},\"failed\":false}]}",
        "{\"items\":[{\"type\":\"currently-reading\",\"data\":null,\"failed\":false}]}",
        "{\"items\":[{\"type\":\"currently-reading\",\"data\":{\"books\":[]}}]}",
    ]) func invalidBatchDoesNotBecomeAnEmptyCachedProgressList(json: String) async throws {
        let fixture = Fixture([
            .init(status: 200, json: json),
            Self.batch("currently-reading", data: "{\"books\":[{\"bookId\":41,\"progress\":42}]}"),
        ])
        defer { fixture.close() }
        await #expect(throws: (any Error).self) {
            _ = try await fixture.provider.fetchUserMediaProgress(libraryId: "1")
        }
        let retry = try await fixture.provider.fetchUserMediaProgress(libraryId: "1")
        #expect(retry.first?.progress == 0.42)
        #expect(fixture.requests.count == 2)
    }

    @Test func nullHighlightIsEmptyButFailedHighlightThrows() async throws {
        let fixture = Fixture([
            Self.batch("highlight-of-the-day", data: "null"),
            .init(status: 200, json: "{\"items\":[{\"type\":\"highlight-of-the-day\",\"data\":null,\"failed\":true}]}"),
        ])
        defer { fixture.close() }
        #expect(try await fixture.provider.fetchHighlightOfTheDayWidget() == nil)
        await #expect(throws: (any Error).self) {
            _ = try await fixture.provider.fetchHighlightOfTheDayWidget()
        }
    }

    @Test func insightsRetainsPreviousCardAndReportsRefreshFailure() async {
        let model = BookOrbitInsightsModel()
        let previous = BookOrbitProvider.ReadingGoalWidget(goalBooks: 12, completedBooks: 3, year: 2026)
        let retained = await model.loadWidget(previous: previous) {
            throw ProviderError.serverError("Fixture failure")
        }
        #expect(retained?.completedBooks == 3)
        #expect(model.widgetError?.contains("Fixture failure") == true)
    }

    @Test func olderServersMayOmitOptionalInsightsWithoutAnError() async {
        let model = BookOrbitInsightsModel()
        let result: BookOrbitProvider.ReadingGoalWidget? = await model.loadWidget(previous: nil) {
            throw BookOrbitProvider.FeatureError.unavailable
        }
        #expect(result == nil)
        #expect(model.widgetError == nil)
    }
}
