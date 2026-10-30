import Foundation
import Testing
import UIKit

@testable import enve

@MainActor
struct Azw3ReaderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENVE_AZW3_FIXTURE_BASE64"] != nil))
    func grimmoryAndLocalAzw3OpenWithoutConversionAndRestoreInFoliate() async throws {
        let encoded = try #require(ProcessInfo.processInfo.environment["ENVE_AZW3_FIXTURE_BASE64"])
        let data = try #require(Data(base64Encoded: encoded))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        for source in [Book.BookSource.booklore, .local] {
            let fixture = try OfflineAvailabilityFixture()
            let id = "azw3-\(UUID().uuidString)"
            let fileURL = try fixture.session.ebooks.cacheRemoteEbook(
                data: data, preferredFilename: "fixture.azw3", bookIdentifier: id
            )
            var book = fixture.book(id: id, source: source, url: fileURL)
            book.ebookProgress = 0.25
            book.epubLocator = #"{"href":"OEBPS/chapter_0000.xhtml","type":"application/xhtml+xml","locations":{"totalProgression":0.25}}"#
            var model: ClassicReaderModel?
            var readerWindow: UIWindow?
            do {
                for opening in 0..<2 {
                    let reader = ClassicReaderModel(
                        book: book, readerEngineOverride: .readium,
                        providerResolver: NoProviders(), profileSession: fixture.session
                    )
                    model = reader
                    reader.startIfNeeded()
                    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
                    while case .loading = reader.state, ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard case .readyFoliate(let adapter) = reader.state else {
                        if case .failed(let error) = reader.state { throw error }
                        Issue.record("AZW3 did not open directly in Foliate")
                        break
                    }
                    let window = UIWindow(windowScene: scene)
                    window.frame = scene.coordinateSpace.bounds
                    window.rootViewController = adapter
                    window.makeKeyAndVisible()
                    readerWindow = window
                    window.layoutIfNeeded()
                    adapter.view.layoutIfNeeded()
                    let initialDeadline = ContinuousClock.now.advanced(by: .seconds(5))
                    while adapter.currentLocatorJSON == nil, ContinuousClock.now < initialDeadline {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    #expect(adapter.view.bounds.width > 0 && adapter.view.bounds.height > 0)
                    #expect(reader.activeReaderEngineKind == .foliate)
                    #expect(reader.readerEngineSelection.fallbackReason == nil)
                    if opening == 0 {
                        await reader.seek(toProgress: 0.5)
                        let relocationDeadline = ContinuousClock.now.advanced(by: .seconds(5))
                        while (EpubLocationBridge.extractGrimmoryLocation(from: adapter.currentLocatorJSON).progression ?? 0) < 0.2,
                            ContinuousClock.now < relocationDeadline {
                            try await Task.sleep(for: .milliseconds(100))
                        }
                        let locator: String = try #require(await adapter.flushPosition())
                        book.epubLocator = locator
                        #expect(EpubLocationBridge.sourceEngine(from: locator) == .foliate)
                        let savedProgress: Double = try #require(EpubLocationBridge.extractGrimmoryLocation(from: locator).progression)
                        #expect(savedProgress >= 0.2)
                    } else {
                        let relocationDeadline = ContinuousClock.now.advanced(by: .seconds(5))
                        while (EpubLocationBridge.extractGrimmoryLocation(from: adapter.currentLocatorJSON).progression ?? 0) < 0.2,
                            ContinuousClock.now < relocationDeadline {
                            try await Task.sleep(for: .milliseconds(100))
                        }
                        let locator: String = try #require(await adapter.flushPosition())
                        let restored: Double = try #require(EpubLocationBridge.extractGrimmoryLocation(from: locator).progression)
                        #expect(restored >= 0.2)
                    }
                    let files = FileManager.default.enumerator(at: fixture.root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
                    #expect(!files.contains { $0.pathExtension == "epub" })
                    await reader.retire()
                    model = nil
                    window.isHidden = true
                    window.rootViewController = nil
                    readerWindow = nil
                    previousWindow?.makeKey()
                }
            } catch {
                readerWindow?.isHidden = true
                readerWindow?.rootViewController = nil
                previousWindow?.makeKey()
                await model?.retire()
                await fixture.close()
                throw error
            }
            await model?.retire()
            await fixture.close()
        }
    }

    private final class NoProviders: LibraryProviderResolving {
        func provider(for providerId: UUID) -> LibraryProvider? { nil }
        func provider(for book: Book) -> LibraryProvider? { nil }
    }
}
