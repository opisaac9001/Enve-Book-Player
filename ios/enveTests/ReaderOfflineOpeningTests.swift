import Foundation
import ReadiumShared
import ReadiumZIPFoundation
import Testing
import UIKit

@testable import enve

@Suite(.serialized)
@MainActor
struct ReaderOfflineOpeningTests {
    enum ServerMode: String, CaseIterable, Sendable {
        case reachable, refused, nonresponsive, unavailable
    }

    @Test(arguments: ServerMode.allCases, [ReaderEngineKind.readium, .foliate])
    func downloadedEPUBRendersRestoresNavigatesAndCloses(_ mode: ServerMode, _ engine: ReaderEngineKind) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let fixture = try Fixture(mode: mode)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        var reader: ClassicReaderModel?
        do {
            let file = try await fixture.writeEPUB()
            var book = fixture.book(file: file)
            await fixture.session.bookStore.upsertBooks([book])
            fixture.session.appState.hotCache.insert(book)
            for opening in 0..<2 {
                let model = ClassicReaderModel(book: book, readerEngineOverride: engine,
                    providerResolver: fixture, profileSession: fixture.session)
                reader = model
                let started = ContinuousClock.now
                model.startIfNeeded()
                window.frame = scene.coordinateSpace.bounds
                try await waitUntil("reader engine ready: \(mode.rawValue), \(engine), opening \(opening)", timeout: .seconds(25)) {
                    if let adapter = model.activeReaderEngineAdapter,
                        window.rootViewController !== adapter.viewController {
                        window.rootViewController = adapter.viewController
                        window.makeKeyAndVisible()
                        window.layoutIfNeeded()
                        adapter.viewController.view.layoutIfNeeded()
                    }
                    switch model.state {
                    case .readyEPUB, .readyFoliate: return true
                    case .failed(let error): throw error
                    default: return false
                    }
                }
                let adapter = try #require(model.activeReaderEngineAdapter)
                #expect(adapter.kind == engine)
                let marker = opening == 0 ? "SECOND_CHAPTER_MARKER" : "FIRST_CHAPTER_MARKER"
                try await waitUntil("restored chapter is rendered") {
                    await adapter.currentPageText()?.contains(marker) == true
                }
                let elapsed = started.duration(to: .now)
                print("ReaderOfflineOpening mode=\(mode.rawValue) engine=\(engine) opening=\(opening) elapsed=\(elapsed)")
                #expect(elapsed < (opening == 0 ? .seconds(20) : .seconds(8)))
                #expect(adapter.viewController.view.window === window)
                #expect(adapter.viewController.view.bounds.width > 0)
                #expect(fixture.provider.assetRequests == 0)
                if opening == 0 {
                    if mode == .nonresponsive {
                        try await waitUntil("hydration request started") { fixture.provider.progressStarted > 0 }
                        #expect(fixture.provider.progressCompleted == 0)
                    }
                    await model.seek(toProgress: 0.05)
                    try await waitUntil("backward navigation rendered") {
                        await adapter.currentPageText()?.contains("FIRST_CHAPTER_MARKER") == true
                    }
                    await model.saveProgressResolvingVisibleOverlay()
                    try await waitUntil("position persisted before closing") {
                        guard let saved = await fixture.session.bookStore.book(uniqueId: book.uniqueId) else { return false }
                        return saved.epubLocator?.contains("chapter-1.xhtml") == true
                    }
                    book = try #require(await fixture.session.bookStore.book(uniqueId: book.uniqueId))
                    if mode == .nonresponsive { #expect(fixture.provider.progressCompleted == 0) }
                }
                let closeStarted = ContinuousClock.now
                await model.retire()
                #expect(closeStarted.duration(to: .now) < .seconds(2))
                window.isHidden = true
                window.rootViewController = nil
                reader = nil
            }
        } catch {
            await reader?.retire()
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
            await fixture.close()
            throw error
        }
        previousWindow?.makeKey()
        await fixture.close()
    }

    @Test(arguments: ServerMode.allCases)
    func localAssetResolutionNeverRequestsTheProvider(_ mode: ServerMode) async throws {
        let fixture = try Fixture(mode: mode)
        do {
            let session = ReaderPublicationSession(book: fixture.book(file: try await fixture.writeEPUB()),
                providerResolver: fixture, profileSession: fixture.session)
            let started = ContinuousClock.now
            let resolution = await session.resolveAsset { _ in Issue.record("Cached EPUB attempted streaming") }
            if case .file(let url) = resolution { #expect(FileManager.default.fileExists(atPath: url.path)) }
            else { Issue.record("Cached EPUB did not resolve to its local file") }
            #expect(started.duration(to: .now) < .seconds(2))
            #expect(fixture.provider.assetRequests == 0)
            await session.retire()
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    private func waitUntil(_ description: String, timeout: Duration = .seconds(8), _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw OpeningError.deadline(description)
    }

    private enum OpeningError: Error { case deadline(String) }

    private final class Fixture: LibraryProviderResolving {
        let root: URL
        let defaults: UserDefaults
        let domain = "ReaderOfflineOpeningTests.\(UUID().uuidString)"
        let session: ProfileSession
        let provider: Provider

        init(mode: ServerMode) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defaults = try #require(UserDefaults(suiteName: domain))
            let profile = FamilyProfile(id: UUID().uuidString, name: "Offline fixture", role: .adult)
            let locations = ProfileStorageLocations(profileID: profile.id,
                documentsDirectory: root.appendingPathComponent("Documents"),
                applicationSupportDirectory: root.appendingPathComponent("Support"),
                cachesDirectory: root.appendingPathComponent("Caches"))
            ProfileServerSyncPreferences(defaults: defaults, isOwner: false).isEnabled = true
            session = try ProfileSession(profile: profile, storage: locations, defaults: defaults)
            provider = Provider(mode: mode)
        }

        func provider(for providerId: UUID) -> LibraryProvider? { provider }
        func provider(for book: Book) -> LibraryProvider? { provider }

        func book(file: URL) -> Book {
            Book(id: "offline-opening", title: "Offline EPUB", mediaType: .ebook,
                ebookFormat: "epub",
                epubLocator: #"{"href":"chapter-2.xhtml","type":"application/xhtml+xml","locations":{"progression":0,"totalProgression":0.5}}"#,
                ebookProgress: 0.5, ebookFileURL: file, lastUpdate: .now, libraryId: "fixture",
                providerId: provider.connection.id, source: .kavita)
        }

        func writeEPUB() async throws -> URL {
            let contents = root.appendingPathComponent("contents")
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
            let files = [
                "mimetype": "application/epub+zip",
                "META-INF/container.xml": #"<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#,
                "package.opf": #"<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">offline-fixture</dc:identifier><dc:title>Offline fixture</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">2026-10-29T00:00:00Z</meta></metadata><manifest><item id="one" href="chapter-1.xhtml" media-type="application/xhtml+xml"/><item id="two" href="chapter-2.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>"#,
                "nav.xhtml": #"<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="chapter-1.xhtml">One</a></li><li><a href="chapter-2.xhtml">Two</a></li></ol></nav></body></html>"#,
                "chapter-1.xhtml": chapter("FIRST_CHAPTER_MARKER"),
                "chapter-2.xhtml": chapter("SECOND_CHAPTER_MARKER"),
            ]
            for (name, value) in files { try Data(value.utf8).write(to: contents.appendingPathComponent(name)) }
            let file = session.ebooks.serverEbooksRoot.appendingPathComponent("fixture.epub")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await FileManager.default.zipItem(at: contents, to: file, shouldKeepParent: false)
            return file
        }

        private func chapter(_ marker: String) -> String {
            let paragraphs = (0..<80).map { "<p id='p\($0)'>\(marker) paragraph \($0). A synthetic chapter for reader opening and restoration.</p>" }.joined()
            return "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>\(marker)</title></head><body>\(paragraphs)</body></html>"
        }

        func close() async {
            await session.retire()
            defaults.removePersistentDomain(forName: domain)
            if let preferencesDomain = session.storage.preferencesDomain { defaults.removePersistentDomain(forName: preferencesDomain) }
            try? FileManager.default.removeItem(at: root)
        }
    }

    private final class Provider: LibraryProvider, EbookProgressPulling, EbookDownloadProvider {
        var connection = ServerConnection(name: "Synthetic offline fixture", url: "https://example.invalid", type: .kavita)
        var capabilities: ProviderCapabilities { [.downloads, .ebookProgressPull] }
        let mode: ServerMode
        var assetRequests = 0
        var progressStarted = 0
        var progressCompleted = 0
        init(mode: ServerMode) { self.mode = mode }
        func validateConnection() async throws -> Bool { true }
        func fetchLibraries() async throws -> [Library] { [] }
        func fetchBooks(libraryId: String) async throws -> [Book] { [] }
        func fetchRecentBooks(libraryId: String, limit: Int) async throws -> [Book] { [] }
        func fetchCollections(libraryId: String?) async throws -> [Collection] { [] }
        func fetchSeries(libraryId: String) async throws -> [Series] { [] }
        func fetchUserMediaProgress(libraryId: String) async throws -> [UserMediaProgress] { [] }
        func fetchFullBookDetails(bookId: String, libraryId: String) async throws -> Book {
            assetRequests += 1
            throw URLError(.resourceUnavailable)
        }
        func downloadEbook(for book: Book, onProgress: (@Sendable (Double) -> Void)?) async throws -> URL {
            assetRequests += 1
            throw URLError(.resourceUnavailable)
        }
        func fetchEbookProgress(for book: Book) async throws -> (progress: Double, locator: String?, updatedAt: Date?, isFinished: Bool)? {
            progressStarted += 1
            switch mode {
            case .reachable: progressCompleted += 1; return nil
            case .refused: throw URLError(.cannotConnectToHost)
            case .unavailable: throw URLError(.notConnectedToInternet)
            case .nonresponsive: try await Task.sleep(for: .seconds(60)); return nil
            }
        }
        func fetchEbookProgressState(for book: Book) async throws -> ProviderEbookProgress? { nil }
    }
}
