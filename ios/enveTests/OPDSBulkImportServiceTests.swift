import Foundation
import Testing

@testable import enve

@MainActor
struct OPDSBulkImportServiceTests {
    @Test func retirementJoinsDownloadsAndDoesNotPublishACollection() async throws {
        let suite = "opds-bulk-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let collections = UserCollectionStore(defaults: defaults)
        let connection = ServerConnection(name: "Catalog", url: "https://catalog.invalid", type: .opds)
        let provider = SuspendedOPDSProvider(connection: connection)
        let service = OPDSBulkImportService(providers: StubProviderMaker(provider: provider), collections: collections)
        let book = Book(id: "publication", title: "Publication", mediaType: .ebook, source: .opds)
        var importing: Task<Void, Never>?
        await withCheckedContinuation { started in
            provider.onStart = { started.resume() }
            importing = Task { await service.importBooks([book], from: connection, collectionName: "Reading") }
        }
        await service.retire()
        await importing?.value
        #expect(provider.didFinish)
        #expect(!service.isRunning)
        #expect(collections.collections.isEmpty)
        await service.importBooks([book], from: connection, collectionName: "Retired")
        #expect(provider.downloadCount == 1)
    }
}

@MainActor
private final class SuspendedOPDSProvider: OPDSProvider, @unchecked Sendable {
    var onStart: (() -> Void)?
    private(set) var didFinish = false
    private(set) var downloadCount = 0

    override func downloadEbook(for book: Book, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        downloadCount += 1
        defer { didFinish = true }
        onStart?()
        try await Task.sleep(nanoseconds: 60_000_000_000)
        throw CancellationError()
    }
}
