import Foundation
import Testing

@testable import enve

/// Scripted replies for BookOrbit wire tests, keyed by a per-fixture reserved `.invalid` host.
nonisolated final class BookOrbitFixtureProtocol: URLProtocol, @unchecked Sendable {
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
struct BookOrbitFixtureServer {
    let host = UUID().uuidString.lowercased() + ".bookorbit.invalid"
    let session: URLSession
    let provider: BookOrbitProvider
    let pendingEdits: PendingBookEditStore
    private let suiteName = "bookorbit-fixture-\(UUID().uuidString)"

    init(_ replies: [BookOrbitFixtureProtocol.Reply], username: String = "fixture-reader") {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BookOrbitFixtureProtocol.self]
        session = URLSession(configuration: configuration)
        pendingEdits = PendingBookEditStore(defaults: UserDefaults(suiteName: suiteName)!)
        provider = BookOrbitProvider(
            connection: ServerConnection(
                name: "Fixture", url: "https://\(host)", type: .bookOrbit, username: username, token: "fixture-token"
            ),
            session: session,
            pendingEdits: pendingEdits
        )
        BookOrbitFixtureProtocol.store.install(replies, host: host)
    }

    var requests: [URLRequest] { BookOrbitFixtureProtocol.store.recorded(host) }

    func jsonBody(_ index: Int) throws -> [String: Any] {
        let body = try #require(requests[index].httpBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    func close() {
        session.invalidateAndCancel()
        BookOrbitFixtureProtocol.store.remove(host)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}
