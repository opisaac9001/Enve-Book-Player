import Foundation
import struct ReadiumShared.Locator
import Testing

@testable import enve

nonisolated private final class BookOrbitEpubProtocol: URLProtocol, @unchecked Sendable {
    static let cfi = "epubcfi(/6/8!/4/2:10)"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let payload: [String: Any]
        switch url.path {
        case "/api/v1/dashboard/widgets/currently-reading":
            payload = ["books": [["bookId": 1, "fileId": 2, "fileFormat": "epub", "progress": 42]]]
        case "/api/v1/books/1":
            payload = ["id": 1, "title": "CFI fixture", "files": [["id": 2, "format": "epub", "role": "primary"]]]
        case "/api/v1/books/files/2/progress":
            if request.httpMethod == "POST" {
                var data = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 1024)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        guard count > 0 else { break }
                        data.append(contentsOf: buffer.prefix(count))
                    }
                }
                let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                guard body?["cfi"] as? String == Self.cfi,
                      body?["percentage"] as? Double == 42 else {
                    client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                    return
                }
            }
            payload = ["percentage": 42, "cfi": Self.cfi, "updatedAt": "2026-09-14T12:00:00.000Z"]
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
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
struct BookOrbitEpubProgressTests {
    @Test func exactPositionSurvivesProviderContinueReadingAndUpload() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BookOrbitEpubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let provider = BookOrbitProvider(connection: ServerConnection(
            name: "Fixture", url: "https://bookorbit.invalid", type: .bookOrbit, token: "fixture-token"
        ), session: session)
        let book = try await provider.fetchFullBookDetails(bookId: "1", libraryId: "1")
        let remote = try #require(await provider.fetchEbookProgress(for: book))
        let locator = try #require(remote.locator)
        #expect((try? Locator(jsonString: locator)) == nil)
        let bridgePosition = try #require(EpubBridgePosition(readiumLocatorJSON: locator))
        #expect(bridgePosition.epubCFI == BookOrbitEpubProtocol.cfi)
        #expect(EpubLocationBridge.canStoreAlongsidePercentageSync(locator))
        #expect(EpubLocationBridge.epubCFI(from: locator) == BookOrbitEpubProtocol.cfi)
        #expect(EpubLocationBridge.sourceEngine(from: locator) == .foliate)
        try await provider.updateEbookProgress(for: book, progress: remote.progress, epubLocator: locator)
        let entries = try await provider.fetchUserMediaProgress(libraryId: "1")
        let cached = try #require(entries.first)
        #expect(EpubLocationBridge.epubCFI(from: cached.epubLocator) == BookOrbitEpubProtocol.cfi)
        let decoded = try JSONDecoder().decode(UserMediaProgress.self, from: JSONEncoder().encode(cached))
        #expect(decoded.epubLocator == cached.epubLocator)
    }

    @Test func newerExactPositionsBypassPercentageAndClockTieThresholds() {
        let earlier = EpubLocationBridge.readiumLocator(href: nil, epubCFI: "epubcfi(/6/8!/4/2:10)", fraction: 0.5, sourceEngine: .foliate)
        let later = EpubLocationBridge.readiumLocator(href: nil, epubCFI: "epubcfi(/6/8!/4/2:20)", fraction: 0.5, sourceEngine: .foliate)
        let oldDate = Date(timeIntervalSince1970: 100)
        let newDate = oldDate.addingTimeInterval(0.1)
        for percentage in [0.5, 0.499, 0.2, 0] {
            #expect(ProgressConflictResolver.resolve(
                localPosition: 0.5, localDate: oldDate, serverPosition: percentage, serverDate: newDate,
                protectsAgainstBackwardProgress: true, localLocator: earlier, serverLocator: later
            ) == .pull)
            #expect(ProgressConflictResolver.resolve(
                localPosition: percentage, localDate: newDate, serverPosition: 0.5, serverDate: oldDate,
                protectsAgainstBackwardProgress: true, localLocator: later, serverLocator: earlier
            ) == .push)
        }
        for date in [oldDate, .distantPast] {
            #expect(ProgressConflictResolver.resolve(
                localPosition: 0.5, localDate: date, serverPosition: 0.5, serverDate: oldDate,
                localLocator: earlier, serverLocator: later
            ) == .none)
        }
    }
}
