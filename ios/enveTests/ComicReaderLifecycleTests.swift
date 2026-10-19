import Foundation
import Testing

@testable import enve

@MainActor
struct ComicReaderLifecycleTests {
    @Test func explicitReadingSequenceIsScopedToItsBooksAndClearsOnAnOrdinaryOpen() async throws {
        let fixture = try OfflineAvailabilityFixture()
        let reader = fixture.session.engine.readerOpen
        let first = Book(id: "one", title: "One", source: .local, mediaType: .ebook, providerId: fixture.providerID)
        let next = Book(id: "two", title: "Two", source: .local, mediaType: .ebook, providerId: fixture.providerID)
        let sequence = [first.uniqueId, next.uniqueId]
        reader.open(first, readingSequence: sequence)
        let initial = reader.readingSequence
        #expect(initial == sequence)
        reader.open(next, readingSequence: sequence)
        let advanced = reader.readingSequence
        #expect(advanced == sequence)
        reader.open(first)
        let ordinary = reader.readingSequence
        #expect(ordinary == nil)
        reader.open(next, readingSequence: [first.uniqueId])
        let unrelated = reader.readingSequence
        #expect(unrelated == nil)
        await fixture.close()
    }

    @Test func canceledLocalOpenCannotPinAssetsAfterCleanup() async throws {
        let fixture = try OfflineAvailabilityFixture()
        let url = try fixture.session.ebooks.cacheRemoteEbook(data: Data([1]), preferredFilename: "issue.cbz", bookIdentifier: "issue")
        let book = fixture.book(id: "issue", url: url)
        let reader = ReaderPublicationSession(book: book, providerResolver: EmptyResolver(), profileSession: fixture.session)
        reader.cleanup()
        let opening = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reader.open(at: url)
        }
        await #expect(throws: CancellationError.self) { _ = try await opening.value }
        let cleared = await fixture.session.readingCache.clear()
        #expect(cleared.activeBytes == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        await fixture.close()
    }

    @Test func canceledArchiveOpenDoesNotRestartExtractionAfterClose() async throws {
        let fixture = try OfflineAvailabilityFixture()
        let url = try fixture.session.ebooks.cacheRemoteEbook(data: Data([1]), preferredFilename: "issue.cbz", bookIdentifier: "issue")
        let book = fixture.book(id: "issue", url: url)
        let reader = ReaderPagedContentController(
            book: book, providerResolver: EmptyResolver(), libraryCache: fixture.session.appState.libraryCache,
            appearanceController: ReaderAppearanceController(appearance: ClassicReaderAppearance(), persist: { _ in }),
            profileSession: fixture.session
        )
        reader.endServerPageStreamingSession()
        let opening = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await reader.openComicArchive(at: url, initialSelection: nil)
        }
        await #expect(throws: CancellationError.self) { try await opening.value }
        let cleared = await fixture.session.readingCache.clear()
        #expect(cleared.activeBytes == 0)
        let pages = fixture.session.storage.cachesDirectory.appendingPathComponent("ComicPages")
        #expect(!FileManager.default.fileExists(atPath: pages.path))
        await fixture.close()
    }

    @Test func preparedAssetStaysProtectedUntilTheReaderCloses() async throws {
        let fixture = try OfflineAvailabilityFixture()
        let url = try fixture.session.ebooks.cacheRemoteEbook(data: Data([1]), preferredFilename: "book.epub", bookIdentifier: "prepared")
        let book = fixture.book(id: "prepared", url: url)
        let cache = fixture.session.readingCache
        await cache.protect([fixture.session.ebooks.remoteReaderCacheRoot], owner: "preparation")
        cache.retainPreparation(owner: "preparation", for: book.uniqueId)
        let reader = ReaderPublicationSession(book: book, providerResolver: EmptyResolver(), profileSession: fixture.session)
        #expect(cache.claimPreparation(for: book.uniqueId) == nil)

        let resolution = await reader.resolveAsset { _ in throw ProviderError.invalidResponse }
        guard case .file(let resolved) = resolution else {
            Issue.record("The prepared local asset was not resolved")
            await fixture.close()
            return
        }
        #expect(resolved == url)
        let active = await cache.clear()
        #expect(active.activeBytes > 0)
        #expect(FileManager.default.fileExists(atPath: url.path))

        await reader.retire()
        var cleared = await cache.clear()
        for _ in 0..<100 where cleared.activeBytes > 0 {
            await Task.yield()
            cleared = await cache.clear()
        }
        #expect(cleared.activeBytes == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        await fixture.close()
    }

    private final class EmptyResolver: LibraryProviderResolving {
        func provider(for providerId: UUID) -> LibraryProvider? { nil }
        func provider(for book: Book) -> LibraryProvider? { nil }
    }
}
