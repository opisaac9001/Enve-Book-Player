import Foundation
import Testing

@testable import enve

@MainActor
final class ServerPageStreamingCacheTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ServerPageStreamingCacheTests-\(UUID().uuidString)", isDirectory: true)
    private let defaultsName = "ServerPageStreamingCacheTests.\(UUID().uuidString)"
    private var caches: URL { root.appendingPathComponent("Caches", isDirectory: true) }

    deinit {
        try? FileManager.default.removeItem(at: root)
        UserDefaults().removePersistentDomain(forName: defaultsName)
    }

    @Test(arguments: [ComicPageLoadingMode.onDemand, .sessionCache])
    func pagesAreReusedAfterTheReaderCloses(mode: ComicPageLoadingMode) async throws {
        let provider = FakePageServer(pageCount: 3)
        let (service, _) = makeService(byteLimit: 1_000_000)
        let book = makeBook(provider)

        for page in try await service.streamedPages(for: book, provider: provider, mode: mode) {
            _ = try await service.pageData(at: page)
        }
        service.endSession(for: book)
        #expect(pageFiles() == ["00000.page", "00001.page", "00002.page"])

        for page in try await service.streamedPages(for: book, provider: provider, mode: mode) {
            #expect(try await service.pageData(at: page) == provider.payload)
        }
        service.endSession(for: book)

        #expect(provider.requests.sorted() == [1, 2, 3])
    }

    @Test func duplicatePageRequestsShareOneServerRequest() async throws {
        let provider = FakePageServer(pageCount: 5, holdsResponses: true)
        let (service, _) = makeService(byteLimit: 1_000_000)
        let book = makeBook(provider)
        let page = try await service.streamedPages(for: book, provider: provider, mode: .onDemand)[2]
        defer { service.endSession(for: book) }

        async let first = service.pageData(at: page)
        async let second = service.pageData(at: page)
        #expect(await waitUntil { provider.heldCount == 1 })
        provider.releaseAll()

        #expect(try await first == second)
        #expect(provider.requests == [3])
    }

    @Test func pageIndexesBeyondThePageCountFailWithoutAServerRequest() async throws {
        let provider = FakePageServer(pageCount: 3)
        let (service, _) = makeService(byteLimit: 1_000_000)
        let book = makeBook(provider)
        let streamID = try #require(try await service.streamedPages(for: book, provider: provider, mode: .onDemand).first?.host)
        defer { service.endSession(for: book) }

        let outOfRange = try #require(URL(string: "enve-comic-page://\(streamID)/3"))
        await #expect(throws: ServerPageStreamingService.StreamingError.self) {
            _ = try await service.pageData(at: outOfRange)
        }
        await service.preparePageWindow(around: outOfRange)

        #expect(provider.requests.isEmpty)
    }

    @Test func aResponseArrivingAfterTheReaderClosesIsNotWritten() async throws {
        let provider = FakePageServer(pageCount: 3, holdsResponses: true)
        let (service, _) = makeService(byteLimit: 1_000_000)
        let book = makeBook(provider)
        let page = try await service.streamedPages(for: book, provider: provider, mode: .onDemand)[0]

        let pending = Task { try await service.pageData(at: page) }
        #expect(await waitUntil { provider.heldCount == 1 })
        service.endSession(for: book)
        provider.releaseAll()

        await #expect(throws: (any Error).self) { _ = try await pending.value }
        #expect(pageFiles().isEmpty)
    }

    @Test func clearingDuringARequestKeepsThePageFromBeingRecreated() async throws {
        let provider = FakePageServer(pageCount: 3, holdsResponses: true)
        let (service, cache) = makeService(byteLimit: 1_000_000)
        let book = makeBook(provider)
        let page = try await service.streamedPages(for: book, provider: provider, mode: .onDemand)[0]
        defer { service.endSession(for: book) }

        let pending = Task { try await service.pageData(at: page) }
        #expect(await waitUntil { provider.heldCount == 1 })
        _ = await cache.clear()
        provider.releaseAll()

        #expect(try await pending.value == provider.payload)
        #expect(pageFiles().isEmpty)
    }

    @Test func aRetiredRequestCompletingLateLeavesTheReopenedRequestInCharge() async throws {
        let provider = FakePageServer(pageCount: 3, holdsResponses: true)
        let (service, _) = makeService(byteLimit: 1_000_000)
        let book = makeBook(provider)

        let oldPage = try await service.streamedPages(for: book, provider: provider, mode: .onDemand)[0]
        let old = Task { try await service.pageData(at: oldPage) }
        #expect(await waitUntil { provider.heldCount == 1 })
        service.endSession(for: book)

        let newPage = try await service.streamedPages(for: book, provider: provider, mode: .onDemand)[0]
        defer { service.endSession(for: book) }
        let current = Task { try await service.pageData(at: newPage) }
        #expect(await waitUntil { provider.heldCount == 2 })

        provider.releaseOldest()
        await #expect(throws: (any Error).self) { _ = try await old.value }
        #expect(pageFiles().isEmpty)

        let joined = Task { try await service.pageData(at: newPage) }
        #expect(!(await waitUntil(attempts: 30) { provider.requests.count > 2 }))
        provider.releaseAll()

        #expect(try await current.value == joined.value)
        #expect(provider.requests == [1, 1])
        #expect(pageFiles() == ["00000.page"])
    }

    @Test func sessionPrefetchStopsAtTheCacheBudget() async throws {
        let provider = FakePageServer(pageCount: 40, pageBytes: 1_000)
        let (service, _) = makeService(byteLimit: 5_500)
        let book = makeBook(provider)

        let pages = try await service.streamedPages(for: book, provider: provider, mode: .sessionCache)
        defer { service.endSession(for: book) }
        await service.preparePageWindow(around: pages[0])
        await waitUntilStable { provider.requests.count }

        // The protected window leaves room for one prefetched page.
        let files = pageFiles()
        #expect(files.count == 5)
        #expect((0...3).allSatisfy { files.contains(String(format: "%05d.page", $0)) })
        #expect(pageBytes() <= 5_500)
        #expect(provider.requests.count <= 4 + 4)
    }

    @Test func theCurrentWindowIsKeptWhileEarlierPagesOfALargeIssueAreEvicted() async throws {
        let provider = FakePageServer(pageCount: 30, pageBytes: 1_000)
        let (service, cache) = makeService(byteLimit: 7_500)
        let book = makeBook(provider)
        let pages = try await service.streamedPages(for: book, provider: provider, mode: .onDemand)
        defer { service.endSession(for: book) }

        await service.preparePageWindow(around: pages[3])
        await service.preparePageWindow(around: pages[20])
        await cache.trim()

        let files = pageFiles()
        #expect((17...23).allSatisfy { files.contains(String(format: "%05d.page", $0)) })
        #expect(files.count == 7)
        #expect(pageBytes() <= 7_500)
    }

    @Test func emptyAndNonImageResponsesAreNotCached() async throws {
        let provider = FakePageServer(pageCount: 2)
        let (service, _) = makeService(byteLimit: 1_000_000)
        let book = makeBook(provider)
        let pages = try await service.streamedPages(for: book, provider: provider, mode: .onDemand)
        defer { service.endSession(for: book) }

        provider.payload = Data("<html>Server error</html>".utf8)
        await #expect(throws: ServerPageStreamingService.StreamingError.self) {
            _ = try await service.pageData(at: pages[0])
        }
        provider.payload = Data()
        await #expect(throws: ServerPageStreamingService.StreamingError.self) {
            _ = try await service.pageData(at: pages[1])
        }

        #expect(pageFiles().isEmpty)
    }

    private func makeService(byteLimit: Int64) -> (ServerPageStreamingService, ReadingCacheStore) {
        let cache = ReadingCacheStore(
            cachesDirectory: caches, defaults: UserDefaults(suiteName: defaultsName)!, byteLimit: byteLimit)
        return (ServerPageStreamingService(cachesDirectory: caches, cache: cache), cache)
    }

    private func makeBook(_ provider: FakePageServer) -> Book {
        Book(id: "issue7", title: "Issue", source: .komga, mediaType: .ebook,
             ebookFormat: "cbz", providerId: provider.connection.id, libraryId: "comics")
    }

    private func pageURLs() -> [URL] {
        let streamed = caches.appendingPathComponent("StreamedPages", isDirectory: true)
        let enumerator = FileManager.default.enumerator(at: streamed, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "page" }
    }

    private func pageFiles() -> [String] {
        pageURLs().map(\.lastPathComponent).sorted()
    }

    private func pageBytes() -> Int {
        pageURLs().reduce(0) { $0 + ((try? Data(contentsOf: $1).count) ?? 0) }
    }

    private func waitUntil(attempts: Int = 500, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func waitUntilStable(_ value: () -> Int) async {
        var last = value()
        var unchanged = 0
        var attempts = 0
        while unchanged < 30, attempts < 500 {
            attempts += 1
            try? await Task.sleep(for: .milliseconds(10))
            let current = value()
            unchanged = current == last ? unchanged + 1 : 0
            last = current
        }
    }
}

// Held responses ignore cancellation to model a provider that finishes retired requests.
@MainActor
private final class FakePageServer: @MainActor ServerPageProvider {
    var connection = ServerConnection(name: "Comics", url: "https://comics.example", type: .komga)
    var capabilities: ProviderCapabilities { [.serverPageStreaming] }
    let pageCount: Int
    var payload: Data
    let holdsResponses: Bool
    private(set) var requests: [Int] = []
    private var held: [CheckedContinuation<Void, Never>] = []

    init(pageCount: Int, pageBytes: Int = 200, holdsResponses: Bool = false) {
        self.pageCount = pageCount
        self.holdsResponses = holdsResponses
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
        payload = png + Data(count: max(0, pageBytes - png.count))
    }

    var heldCount: Int { held.count }

    func validateConnection() async throws -> Bool { true }
    func fetchPageCount(for book: Book) async throws -> Int { pageCount }

    func fetchPage(_ pageNumber: Int, for book: Book) async throws -> Data {
        requests.append(pageNumber)
        let response = payload
        if holdsResponses {
            await withCheckedContinuation { held.append($0) }
        }
        return response
    }

    func releaseOldest() {
        guard !held.isEmpty else { return }
        held.removeFirst().resume()
    }

    func releaseAll() {
        let continuations = held
        held.removeAll()
        continuations.forEach { $0.resume() }
    }
}
