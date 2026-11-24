import Foundation
import Testing

@testable import enve

nonisolated private final class ReadwiseProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var body = ""
        var headers: [String: String] = [:]
        var stall = false
    }
    struct Recorded: Sendable { let request: URLRequest; let body: Data }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [Reply] = []
    nonisolated(unsafe) private static var recorded: [Recorded] = []

    static func reset(_ replies: [Reply]) { lock.withLock { self.replies = replies; recorded = [] } }
    static var requests: [Recorded] { lock.withLock { recorded } }
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
        let reply = Self.lock.withLock {
            Self.recorded.append(Recorded(request: request, body: body))
            return Self.replies.isEmpty ? nil : Self.replies.removeFirst()
        }
        guard let reply else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        if reply.stall { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
@Suite(.serialized)
struct ReadwiseExportTests {
    private struct Fixture {
        let suite: String
        let defaults: UserDefaults
        let keychain: SharedKeychainStore
        let session: URLSession
        let service: ReadwiseExportService

        init(_ replies: [ReadwiseProtocol.Reply]) throws {
            ReadwiseProtocol.reset(replies)
            suite = "readwise-test-" + UUID().uuidString
            defaults = try #require(UserDefaults(suiteName: suite))
            keychain = SharedKeychainStore(profileID: UUID().uuidString)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ReadwiseProtocol.self]
            session = URLSession(configuration: configuration)
            service = ReadwiseExportService(keychain: keychain, defaults: defaults, client: ReadwiseClient(session: session, minimumRequestInterval: .zero))
        }
        func cleanUp() {
            service.retire()
            try? keychain.clearProfileCredentials()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private var book: Book {
        var book = Book(id: "test-book", title: "Test Book", author: "Test Author", source: .local, backendId: "fixture")
        book.thumb = "https://private.example/cover?token=never-send"
        return book
    }
    private func annotation(_ id: String = "first", text: String = "A test passage.") -> ReaderAnnotation {
        ReaderAnnotation(id: id, bookId: book.stableId, position: id == "first" ? 0.2 : 0.8, text: text, note: "My note", chapterTitle: "Chapter One", createdAt: Date(timeIntervalSince1970: 100))
    }
    private let created = #"[{"id":10,"modified_highlights":[101]}]"#

    @Test func sendsMetadataWithoutPrivateURLsAndUpdatesExistingNotes() async throws {
        let fixture = try Fixture([.init(status: 204), .init(body: created), .init(body: "{}")])
        defer { fixture.cleanUp() }
        await fixture.service.connect(token: "fixture-token")
        #expect(fixture.service.isConnected)
        var item = annotation()
        await fixture.service.send(book: book, annotations: [item])
        #expect(fixture.service.lastError == nil)
        #expect(fixture.service.sentCount == 1)
        let saved = try #require(fixture.defaults.data(forKey: "readwise.exportReceipts"))
        let receipts = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect(receipts.count == 1)
        let posted = try #require(ReadwiseProtocol.requests.first { $0.request.httpMethod == "POST" })
        #expect(posted.request.value(forHTTPHeaderField: "Authorization") == "Token fixture-token")
        let object = try #require(JSONSerialization.jsonObject(with: posted.body) as? [String: Any])
        let highlight = try #require((object["highlights"] as? [[String: Any]])?.first)
        #expect(highlight["title"] as? String == "Test Book")
        #expect(highlight["note"] as? String == "My note\n\nChapter: Chapter One")
        #expect(highlight["location_type"] as? String == "order")
        #expect(highlight["image_url"] == nil && highlight["source_url"] == nil)
        #expect(!String(decoding: posted.body, as: UTF8.self).contains("private.example"))

        let reopened = ReadwiseExportService(keychain: fixture.keychain, defaults: fixture.defaults, client: ReadwiseClient(session: fixture.session, minimumRequestInterval: .zero))
        await reopened.send(book: book, annotations: [item])
        #expect(ReadwiseProtocol.requests.count == 2)
        #expect(reopened.sentCount == 0)
        item.note = "Edited note"
        await reopened.send(book: book, annotations: [item])
        let updated = try #require(ReadwiseProtocol.requests.last)
        #expect(updated.request.httpMethod == "PATCH")
        #expect(updated.request.url?.absoluteString == "https://readwise.io/api/v2/highlights/101/")
        #expect(reopened.lastError == nil)
        let body = try #require(JSONSerialization.jsonObject(with: updated.body) as? [String: Any])
        #expect((body["note"] as? String)?.hasPrefix("Edited note") == true)
        #expect(!String(describing: fixture.defaults.dictionaryRepresentation()).contains("fixture-token"))
    }

    @Test func partialFailureResumesWithoutResendingConfirmedHighlights() async throws {
        let fixture = try Fixture([
            .init(status: 204), .init(body: created), .init(status: 429, headers: ["Retry-After": "12"]),
            .init(body: #"[{"id":10,"modified_highlights":[102]}]"#),
        ])
        defer { fixture.cleanUp() }
        await fixture.service.connect(token: "fixture-token")
        let annotations = [annotation(), annotation("second", text: "Another passage.")]
        await fixture.service.send(book: book, annotations: annotations)
        #expect(fixture.service.sentCount == 1)
        #expect(fixture.service.lastError?.contains("12 seconds") == true)
        await fixture.service.send(book: book, annotations: annotations)
        #expect(fixture.service.lastError == nil)
        #expect(fixture.service.totalCount == 1)
        #expect(fixture.service.sentCount == 1)
        #expect(ReadwiseProtocol.requests.count == 4)
    }

    @Test func lostResponseRetryFindsExistingHighlightAndUpdatesItsNote() async throws {
        let fixture = try Fixture([
            .init(status: 204), .init(body: #"[{"id":10,"modified_highlights":[]}]"#),
            .init(body: #"{"results":[{"id":101,"text":"A test passage."}],"next":null}"#), .init(body: "{}"),
        ])
        defer { fixture.cleanUp() }
        await fixture.service.connect(token: "fixture-token")
        await fixture.service.send(book: book, annotations: [annotation()])
        #expect(fixture.service.lastError == nil)
        #expect(ReadwiseProtocol.requests.map { $0.request.httpMethod } == ["GET", "POST", "GET", "PATCH"])
        #expect(ReadwiseProtocol.requests.last?.request.url?.absoluteString == "https://readwise.io/api/v2/highlights/101/")
    }

    @Test func rejectedAuthenticationIsNotSavedAndDisconnectDoesNotDeleteRemoteData() async throws {
        let fixture = try Fixture([.init(status: 401), .init(status: 204)])
        defer { fixture.cleanUp() }
        await fixture.service.connect(token: "invalid-fixture-token")
        #expect(!fixture.service.isConnected)
        #expect(fixture.service.lastError != nil)
        await fixture.service.connect(token: "fixture-token")
        #expect(fixture.service.isConnected)
        fixture.service.disconnect()
        #expect(!fixture.service.isConnected)
        #expect(ReadwiseProtocol.requests.count == 2)
        let other = ReadwiseExportService(keychain: SharedKeychainStore(profileID: UUID().uuidString), defaults: fixture.defaults)
        #expect(!other.isConnected)
        other.retire()
    }

    @Test func retiringCancelsPendingAuthenticationAndPreventsLateCredentialSave() async throws {
        let fixture = try Fixture([.init(stall: true)])
        defer { fixture.cleanUp() }
        let task = Task { await fixture.service.connect(token: "fixture-token") }
        for _ in 0..<100 where ReadwiseProtocol.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(ReadwiseProtocol.requests.count == 1)
        fixture.service.retire()
        await task.value
        #expect(!fixture.service.isConnected)
        #expect(!fixture.service.isWorking)
        await fixture.service.send(book: book, annotations: [annotation()])
        #expect(ReadwiseProtocol.requests.count == 1)
    }

    @Test func rejectsOversizedHighlightsBeforeSendingAnything() async throws {
        let fixture = try Fixture([.init(status: 204)])
        defer { fixture.cleanUp() }
        await fixture.service.connect(token: "fixture-token")
        await fixture.service.send(book: book, annotations: [annotation(), annotation("second", text: String(repeating: "x", count: 8192))])
        #expect(fixture.service.lastError?.contains("exceeds Readwise's limit") == true)
        #expect(ReadwiseProtocol.requests.count == 1)
    }

    @Test func excludesRemotePlaceholdersAndPreservesUnicodeText() throws {
        var placeholder = annotation("placeholder")
        placeholder.isRemotePlaceholder = true
        let value = "日本語 café \u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}\nSecond line"
        let mapped = try ReadwiseExportService.highlights(book: book, annotations: [placeholder, annotation("blank", text: " \n "), annotation(text: value)])
        #expect(mapped.count == 1)
        #expect(mapped.first?.1.text == value)
        #expect(mapped.first?.1.location == 200_000)
    }
}
