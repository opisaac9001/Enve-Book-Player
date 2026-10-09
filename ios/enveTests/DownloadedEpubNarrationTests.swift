import Foundation
import Testing

@testable import enve

@MainActor
struct DownloadedEpubNarrationTests {
    @Test func existingDownloadedEpubRepairsNarrationCapabilityWithoutAServer() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = try fixture.session()
        let file = try fixture.writeNarratedEpub(in: session.ebooks.serverEbooksRoot)
        var book = fixture.book
        book.ebookFileURL = file
        book.epub3Features = EPUB3Features(hasMediaOverlay: false, hasFixedLayout: true)
        await session.bookStore.upsertBooks([book])

        let repaired = try #require(await session.engine.library.resolveReadAloudIfUnknown(for: book))
        #expect(repaired.epub3Features?.hasMediaOverlay == true)
        #expect(repaired.currentTime == book.currentTime)
        #expect(repaired.epubLocator == book.epubLocator)
        await session.retire()
        let reopened = try fixture.session()
        #expect(await reopened.bookStore.book(uniqueId: book.uniqueId)?.epub3Features?.hasMediaOverlay == true)
        await reopened.retire()
    }

    @Test func completedDownloadPersistsNarrationAndCatalogRefreshKeepsIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = try fixture.session()
        let file = try fixture.writeNarratedEpub(in: fixture.root)
        let provider = DownloadProvider(connection: fixture.connection, book: fixture.book, file: file)
        session.registry.register(libraryProviderFactory: { _ in provider }, for: .booklore)
        session.providerConnections.connections = [fixture.connection]
        await session.bookStore.upsertBooks([fixture.book])
        let task = BookDownloadTask.create(bookId: fixture.book.downloadKey, title: fixture.book.title, source: fixture.book.source)

        try await session.downloads.downloadEbookViaProvider(task: task, book: fixture.book)
        let downloaded = try #require(await session.bookStore.book(uniqueId: fixture.book.uniqueId))
        #expect(downloaded.epub3Features?.hasMediaOverlay == true)
        let downloadedFile = try #require(downloaded.ebookFileURL)
        #expect(downloadedFile.path.hasPrefix(session.ebooks.serverEbooksRoot.path + "/"))
        #expect(FileManager.default.fileExists(atPath: downloadedFile.path))
        #expect(downloaded.epubLocator == fixture.book.epubLocator)
        #expect(downloaded.ebookProgress == fixture.book.ebookProgress)

        await session.catalog.refreshBookDetails(for: downloaded)
        let refreshed = try #require(await session.bookStore.book(uniqueId: fixture.book.uniqueId))
        #expect(refreshed.epub3Features?.hasMediaOverlay == true)
        #expect(refreshed.ebookFileURL == downloaded.ebookFileURL)
        await session.retire()
        let reopened = try fixture.session()
        #expect(await reopened.bookStore.book(uniqueId: fixture.book.uniqueId)?.epub3Features?.hasMediaOverlay == true)
        await reopened.retire()
    }

    private final class DownloadProvider: @MainActor LibraryProvider, @MainActor EbookDownloadProvider {
        var connection: ServerConnection
        let book: Book
        let file: URL
        var capabilities: ProviderCapabilities { [.downloads] }
        init(connection: ServerConnection, book: Book, file: URL) {
            self.connection = connection
            self.book = book
            self.file = file
        }
        func validateConnection() async throws -> Bool { true }
        func fetchLibraries() async throws -> [Library] { [] }
        func fetchBooks(libraryId: String) async throws -> [Book] { [] }
        func fetchRecentBooks(libraryId: String, limit: Int) async throws -> [Book] { [] }
        func fetchCollections(libraryId: String?) async throws -> [Collection] { [] }
        func fetchSeries(libraryId: String) async throws -> [Series] { [] }
        func fetchUserMediaProgress(libraryId: String) async throws -> [UserMediaProgress] { [] }
        func fetchFullBookDetails(bookId: String, libraryId: String) async throws -> Book { book }
        func getAudioURL(for book: Book) -> URL? { nil }
        func getStreamingHeaders() -> [String: String] { [:] }
        func startPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo { throw ProviderError.notImplemented }
        func updatePlaybackProgress(book: Book, sessionId: String?, currentTime: TimeInterval, isFinished: Bool, timeListened: TimeInterval) async throws {}
        func downloadEbook(for book: Book, onProgress: (@Sendable (Double) -> Void)?) async throws -> URL { file }
    }

    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let profile = FamilyProfile(id: UUID().uuidString, name: "Reader", role: .adult)
        let connection = ServerConnection(name: "Fixture", url: "https://example.invalid", type: .booklore)
        let domain = "DownloadedEpubNarrationTests.\(UUID().uuidString)"
        var book: Book {
            Book(id: "narrated", title: "Narrated EPUB", mediaType: .ebook,
                epubLocator: "local-locator", ebookProgress: 0.25,
                chapters: [Chapter(id: "one", start: 0, end: 60, title: "One")],
                currentTime: 12, isFinished: false, libraryId: "library", providerId: connection.id, source: .booklore)
        }
        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        func session() throws -> ProfileSession {
            let locations = ProfileStorageLocations(profileID: profile.id,
                documentsDirectory: root.appendingPathComponent("Documents"),
                applicationSupportDirectory: root.appendingPathComponent("Support"),
                cachesDirectory: root.appendingPathComponent("Caches"),
                legacyPlaybackStoreURL: root.appendingPathComponent("Playback.store"))
            return try ProfileSession(profile: profile, storage: locations, defaults: UserDefaults(suiteName: domain))
        }
        func writeNarratedEpub(in directory: URL) throws -> URL {
            let file = directory.appendingPathComponent("narrated.epub")
            let archive = "UEsDBBQAAAAAACa/Rl2lyDPvNgAAADYAAAATAAAARVBVQi9uYXJyYXRpb24uc21pbDxzbWlsIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy9ucy9TTUlMIj48Ym9keS8+PC9zbWlsPlBLAQIUAxQAAAAAACa/Rl2lyDPvNgAAADYAAAATAAAAAAAAAAAAAACAAQAAAABFUFVCL25hcnJhdGlvbi5zbWlsUEsFBgAAAAABAAEAQQAAAGcAAAAAAA=="
            try #require(Data(base64Encoded: archive)).write(to: file)
            return file
        }
        func remove() {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
