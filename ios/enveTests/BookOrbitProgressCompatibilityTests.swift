import Foundation
import Testing

@testable import enve

nonisolated private final class BookOrbitCompatibilityProtocol: URLProtocol, @unchecked Sendable {
    nonisolated struct RecordedRequest {
        let method: String
        let path: String
        let body: [String: Any]
    }

    nonisolated final class Responses: @unchecked Sendable {
        private let lock = NSLock()
        private var progress: [String: [String: Any]] = [:]
        private var ratingStatus: [String: Int] = [:]
        private var recorded: [String: [RecordedRequest]] = [:]

        func install(host: String, progress: [String: Any], ratingStatus: Int) {
            lock.withLock {
                self.progress[host] = progress
                self.ratingStatus[host] = ratingStatus
                recorded[host] = []
            }
        }

        func remove(host: String) {
            lock.withLock {
                progress.removeValue(forKey: host)
                ratingStatus.removeValue(forKey: host)
                recorded.removeValue(forKey: host)
            }
        }

        func requests(host: String) -> [RecordedRequest] {
            lock.withLock { recorded[host] ?? [] }
        }

        func response(for request: URLRequest, body: Data) -> (Int, [String: Any]?) {
            lock.withLock {
                let host = request.url!.host!
                let path = request.url!.path
                recorded[host, default: []].append(RecordedRequest(
                    method: request.httpMethod ?? "GET",
                    path: path,
                    body: (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                ))
                switch path {
                case "/api/v1/libraries":
                    return (200, ["fixtureLibraries": true])
                case "/api/v1/libraries/1/books":
                    return (200, [
                        "items": [[
                            "id": 41,
                            "title": "Timestamp fixture",
                            "files": [["id": 2, "format": "epub", "role": "primary"]],
                            "readStatus": ["status": "reading", "updatedAt": "2026-10-19T03:00:00Z"],
                        ]],
                        "total": 1, "page": 0, "size": 200,
                    ])
                case "/api/v1/dashboard/widgets/currently-reading":
                    return (200, ["books": [["bookId": 41, "fileId": 2, "fileFormat": "epub", "progress": 42]]])
                case "/api/v1/books/files/2/progress":
                    return request.httpMethod == "POST" ? (204, nil) : (200, progress[host] ?? [:])
                case "/api/v1/books/bulk-set-rating":
                    let status = ratingStatus[host] ?? 204
                    return (status, status == 204 ? nil : ["message": "Forbidden"])
                default:
                    return (404, ["message": "Unexpected fixture request"])
                }
            }
        }
    }

    static let responses = Responses()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let (status, payload) = Self.responses.response(for: request, body: body)
        do {
            let data: Data
            if payload?["fixtureLibraries"] as? Bool == true {
                data = try JSONSerialization.data(withJSONObject: [["id": 1, "name": "Fixture"]])
            } else if let payload {
                data = try JSONSerialization.data(withJSONObject: payload)
            } else {
                data = Data()
            }
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
struct BookOrbitProgressCompatibilityTests {
    private static let cfi = "epubcfi(/6/8!/4/2:10)"
    private static let textDate = ISO8601Timestamp.parse("2026-10-19T01:00:00Z")!
    private static let narrationDate = ISO8601Timestamp.parse("2026-10-19T03:00:00Z")!

    @MainActor private struct Fixture {
        let host: String
        let session: URLSession
        let provider: BookOrbitProvider
        let book: Book

        init(progress: [String: Any], ratingStatus: Int = 204) {
            host = "\(UUID().uuidString.lowercased()).bookorbit.invalid"
            BookOrbitCompatibilityProtocol.responses.install(host: host, progress: progress, ratingStatus: ratingStatus)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [BookOrbitCompatibilityProtocol.self]
            session = URLSession(configuration: configuration)
            let connection = ServerConnection(name: "Fixture", url: "https://\(host)", type: .bookOrbit, token: "fixture-token")
            provider = BookOrbitProvider(connection: connection, session: session)
            book = Book(id: "41", title: "Fixture", source: .bookOrbit, audioFileIno: "2", mediaType: .ebook, providerId: connection.id, libraryId: "1")
        }

        var requests: [BookOrbitCompatibilityProtocol.RecordedRequest] {
            BookOrbitCompatibilityProtocol.responses.requests(host: host)
        }

        func close() {
            session.invalidateAndCancel()
            BookOrbitCompatibilityProtocol.responses.remove(host: host)
        }
    }

    @Test func textClockWinsOverNewerNarrationAndStatusClocks() async throws {
        let fixture = Fixture(progress: [
            "percentage": 42, "cfi": Self.cfi,
            "updatedAt": "2026-10-19T03:00:00Z",
            "textUpdatedAt": "2026-10-19T01:00:00Z",
            "narrationUpdatedAt": "2026-10-19T03:00:00Z",
        ])
        defer { fixture.close() }

        let direct = try #require(await fixture.provider.fetchEbookProgress(for: fixture.book))
        let continued = try await fixture.provider.fetchUserMediaProgress(libraryId: "1")
        let activity = try await fixture.provider.fetchActivitySnapshot()

        #expect(direct.updatedAt == Self.textDate)
        #expect(continued.first?.lastUpdate == Self.textDate)
        #expect(activity.first?.updatedAt == Self.textDate)
        #expect(EpubLocationBridge.epubCFI(from: direct.locator) == Self.cfi)
    }

    @Test func legacyProgressUsesItsExistingClock() async throws {
        let fixture = Fixture(progress: ["percentage": 42, "cfi": Self.cfi, "updatedAt": "2026-10-19T01:00:00Z"])
        defer { fixture.close() }

        let progress = try #require(await fixture.provider.fetchEbookProgress(for: fixture.book))

        #expect(progress.updatedAt == Self.textDate)
    }

    @Test func narrationWithoutATextClockDoesNotRestampText() async throws {
        let fixture = Fixture(progress: [
            "percentage": 42, "cfi": Self.cfi, "textUpdatedAt": NSNull(),
            "updatedAt": "2026-10-19T03:00:00Z", "narrationUpdatedAt": "2026-10-19T03:00:00Z",
        ])
        defer { fixture.close() }

        let direct = try #require(await fixture.provider.fetchEbookProgress(for: fixture.book))
        let continued = try await fixture.provider.fetchUserMediaProgress(libraryId: "1")
        let activity = try await fixture.provider.fetchActivitySnapshot()

        #expect(direct.updatedAt == nil)
        #expect(continued.first?.lastUpdate == .distantPast)
        #expect(activity.first?.updatedAt == .distantPast)
    }

    @Test func exactAnchorAtTheServerLimitIsUploadedWithoutTruncation() async throws {
        let fixture = Fixture(progress: [:])
        defer { fixture.close() }
        let cfi = Self.anchor(length: 2_000)
        let locator = EpubLocationBridge.readiumLocator(href: "chapter.xhtml", epubCFI: cfi, fraction: 0.42, sourceEngine: .foliate)

        try await fixture.provider.updateEbookProgress(for: fixture.book, progress: 0.42, epubLocator: locator)

        #expect(fixture.requests.count == 1)
        #expect(fixture.requests.first?.body["cfi"] as? String == cfi)
    }

    @Test func oversizedAnchorsFailBeforeTransportAndKeepTheirLocalCheckpoint() async throws {
        let fixture = Fixture(progress: [:])
        defer { fixture.close() }
        for cfi in [Self.anchor(length: 2_001), "epubcfi(/6/8!/4/2[\(String(repeating: "e\u{0301}", count: 1_000))]:1)"] {
            var book = fixture.book
            book.epubLocator = EpubLocationBridge.readiumLocator(href: "chapter.xhtml", epubCFI: cfi, fraction: 0.42, sourceEngine: .foliate)
            book.ebookProgress = 0.42
            do {
                try await fixture.provider.updateEbookProgress(for: book, progress: 0.42, epubLocator: book.epubLocator)
                Issue.record("Expected a nonretryable progress validation failure")
            } catch let error as ProgressValidationError {
                #expect(!error.localizedDescription.isEmpty)
            }
            #expect(EpubLocationBridge.epubCFI(from: book.epubLocator) == cfi)
            #expect(book.ebookProgress == 0.42)
        }
        #expect(fixture.requests.isEmpty)
    }

    @Test func personalRatingUsesTheDedicatedRouteAndKeepsPermissionFailures() async throws {
        for status in [204, 403] {
            let fixture = Fixture(progress: [:], ratingStatus: status)
            defer { fixture.close() }
            do {
                try await fixture.provider.updatePersonalRating(for: fixture.book, rating: 4)
                #expect(status == 204)
            } catch {
                #expect(status == 403)
                #expect(error.localizedDescription.contains("HTTP 403"))
            }
            #expect(fixture.requests.count == 1)
            #expect(fixture.requests.first?.path == "/api/v1/books/bulk-set-rating")
            #expect(fixture.requests.first?.method == "POST")
            #expect(fixture.requests.first?.body["bookIds"] as? [Int] == [41])
            #expect(fixture.requests.first?.body["rating"] as? Int == 4)
        }
    }

    private static func anchor(length: Int) -> String {
        let prefix = "epubcfi(/6/8!/4/2["
        let suffix = "]:1)"
        return prefix + String(repeating: "x", count: length - prefix.count - suffix.count) + suffix
    }
}
