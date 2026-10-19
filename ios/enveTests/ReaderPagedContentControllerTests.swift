import Foundation
import Testing
import UIKit

@testable import enve

@MainActor
final class ReaderPagedContentControllerTests {
    private let fixture: OfflineAvailabilityFixture

    init() throws { fixture = try OfflineAvailabilityFixture() }
    deinit {
        let captured = fixture
        Task { @MainActor in await captured.close() }
    }

    @Test func serverFormatReplacesAStaleCachedFormatBeforeOpening() async throws {
        let provider = PagesProvider(format: "cbz", pageCount: 3)
        let reader = makeReader(provider: provider, cachedFormat: "epub")
        defer { reader.endServerPageStreamingSession() }

        #expect(!reader.isComicBook)
        await reader.refreshServerFormatIfNeeded()
        #expect(reader.isComicBook)
        #expect(try await reader.openServerStreamedComicIfAvailable())
        #expect(reader.comicPages.count == 3)
    }

    @Test func streamedPagesUseComicBehaviorEvenWithoutAnArchiveFormat() async throws {
        let provider = PagesProvider(format: "pdf", pageCount: 3)
        let reader = makeReader(provider: provider, cachedFormat: "pdf")
        defer { reader.endServerPageStreamingSession() }

        #expect(!reader.isComicBook)
        #expect(try await reader.openServerStreamedComicIfAvailable())
        #expect(reader.isComicBook)
    }

    @Test func aReflowableEPUBWithoutPagesKeepsItsBookReader() async throws {
        let provider = PagesProvider(format: "epub", pageCount: 0)
        let reader = makeReader(provider: provider, cachedFormat: nil)
        await reader.refreshServerFormatIfNeeded()

        #expect(!(try await reader.openServerStreamedComicIfAvailable()))
        #expect(!reader.isComicBook)
        #expect(reader.comicPages.isEmpty)
    }

    @Test func theSeriesDirectionAppliesUntilTheReaderPicksOneForTheBook() async throws {
        let provider = PagesProvider(format: "cbz", pageCount: 3, direction: .rightToLeft)
        let reader = makeReader(provider: provider, cachedFormat: "cbz", bookID: "direction-\(UUID().uuidString)")
        defer {
            reader.setComicDirectionOverride(nil)
            reader.endServerPageStreamingSession()
        }

        #expect(try await reader.openServerStreamedComicIfAvailable())
        await waitForDirection(reader)
        #expect({ reader.effectiveComicLayout == .rightToLeft }())
        #expect({ reader.isRightToLeftPageProgression }())

        reader.setComicDirectionOverride(.leftToRight)
        #expect(reader.effectiveComicLayout == .leftToRight)
        #expect(reader.autoComicLayout == .rightToLeft)

        reader.setComicDirectionOverride(nil)
        #expect(reader.comicDirectionOverride == nil)
        await waitForDirection(reader)
        #expect({ reader.effectiveComicLayout == .rightToLeft }())
    }

    @Test func detectedSeriesDirectionSurvivesReopening() async throws {
        let provider = PagesProvider(format: "cbz", pageCount: 3, direction: .rightToLeft)
        let bookID = "cached-direction-\(UUID().uuidString)"
        let reader = makeReader(provider: provider, cachedFormat: "cbz", bookID: bookID)
        let book = Book(id: bookID, title: "Issue", source: .komga, mediaType: .ebook,
            ebookFormat: "cbz", providerId: provider.connection.id, libraryId: "comics")
        defer {
            reader.endServerPageStreamingSession()
            fixture.session.comicReadingDirections.setProviderDirection(nil, forBookID: book.stableId)
        }
        #expect(try await reader.openServerStreamedComicIfAvailable())
        await waitForDirection(reader)
        #expect({ fixture.session.comicReadingDirections.providerDirection(forBookID: book.stableId) == .rightToLeft }())
        provider.failDirection = true
        let reopened = makeReader(provider: provider, cachedFormat: "cbz", bookID: bookID)
        defer { reopened.endServerPageStreamingSession() }
        #expect(reopened.effectiveComicLayout == .rightToLeft)
        #expect(try await reopened.openServerStreamedComicIfAvailable())
        #expect(reopened.isRightToLeftPageProgression)
        reopened.setComicDirectionOverride(.leftToRight)
        #expect(reopened.effectiveComicLayout == .leftToRight)
        reopened.setComicDirectionOverride(nil)
        #expect(reopened.effectiveComicLayout == .rightToLeft)
    }

    @Test func streamedImagesLoadThroughTheOwningReaderSession() async throws {
        let provider = PagesProvider(format: "cbz", pageCount: 3)
        let reader = makeReader(provider: provider, cachedFormat: "cbz", bookID: UUID().uuidString)
        defer { reader.endServerPageStreamingSession() }
        #expect(try await reader.openServerStreamedComicIfAvailable())
        let page = try #require(reader.comicPages.first)
        #expect(try await reader.comicPageData(at: page) == provider.imageData)
        reader.endServerPageStreamingSession()
        await #expect(throws: (any Error).self) {
            _ = try await reader.comicPageData(at: page)
        }
    }

    @Test func knownComicDoesNotFetchFullDetailsOrWaitForDirection() async throws {
        let provider = PagesProvider(format: "cbz", pageCount: 3, direction: .rightToLeft)
        provider.suspendDirection = true
        let reader = makeReader(provider: provider, cachedFormat: "cbz", bookID: UUID().uuidString)
        defer { reader.endServerPageStreamingSession() }
        await reader.refreshServerFormatIfNeeded()
        #expect(try await reader.openServerStreamedComicIfAvailable())
        #expect(provider.detailFetchCount == 0)
        #expect(reader.comicPages.count == 3)
        #expect(provider.directionFetchCount <= 1)
    }

    @Test func streamFailureIsReportedWithoutAnArchiveFallback() async throws {
        let provider = PagesProvider(format: "cbz", pageCount: 3)
        provider.failPageCount = true
        let reader = makeReader(provider: provider, cachedFormat: "cbz", bookID: UUID().uuidString)
        defer { reader.endServerPageStreamingSession() }
        await #expect(throws: ProviderError.self) {
            _ = try await reader.openServerStreamedComicIfAvailable()
        }
        #expect(reader.comicPages.isEmpty)
        #expect(provider.detailFetchCount == 0)
    }

    private func waitForDirection(_ reader: ReaderPagedContentController) async {
        for _ in 0..<200 where reader.effectiveComicLayout != .rightToLeft {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeReader(provider: PagesProvider, cachedFormat: String?, bookID: String = "issue") -> ReaderPagedContentController {
        ReaderPagedContentController(
            book: Book(id: bookID, title: "Issue", source: .komga, mediaType: .ebook,
                       ebookFormat: cachedFormat, providerId: provider.connection.id, libraryId: "comics"),
            providerResolver: Resolver(provider: provider),
            libraryCache: LibraryBookCache(),
            appearanceController: ReaderAppearanceController(appearance: ClassicReaderAppearance(), persist: { _ in }),
            profileSession: fixture.session
        )
    }

    private final class Resolver: LibraryProviderResolving {
        let provider: PagesProvider
        init(provider: PagesProvider) { self.provider = provider }
        func provider(for providerId: UUID) -> LibraryProvider? { provider }
        func provider(for book: Book) -> LibraryProvider? { provider }
    }

    private final class PagesProvider: @MainActor LibraryProvider, @MainActor ServerPageProvider,
        @MainActor ComicReadingDirectionProvider
    {
        var connection = ServerConnection(name: "Comics", url: "https://comics.example", type: .komga)
        var capabilities: ProviderCapabilities { [.serverPageStreaming] }
        let format: String
        let pageCount: Int
        let direction: ComicReadingDirection?
        var failDirection = false
        var suspendDirection = false
        var failPageCount = false
        var detailFetchCount = 0
        var directionFetchCount = 0
        var imageData: Data {
            UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).pngData { _ in }
        }

        init(format: String, pageCount: Int, direction: ComicReadingDirection? = nil) {
            self.format = format
            self.pageCount = pageCount
            self.direction = direction
        }

        func validateConnection() async throws -> Bool { true }
        func fetchLibraries() async throws -> [Library] { [] }
        func fetchBooks(libraryId: String) async throws -> [Book] { [] }
        func fetchRecentBooks(libraryId: String, limit: Int) async throws -> [Book] { [] }
        func fetchCollections(libraryId: String?) async throws -> [Collection] { [] }
        func fetchSeries(libraryId: String) async throws -> [Series] { [] }
        func fetchUserMediaProgress(libraryId: String) async throws -> [UserMediaProgress] { [] }
        func fetchFullBookDetails(bookId: String, libraryId: String) async throws -> Book {
            detailFetchCount += 1
            return Book(id: bookId, title: "Issue", source: .komga, mediaType: .ebook,
                 ebookFormat: format, providerId: connection.id, libraryId: libraryId)
        }
        func fetchPageCount(for book: Book) async throws -> Int {
            if failPageCount { throw ProviderError.invalidResponse }
            return pageCount
        }
        func canStreamPages(for book: Book) -> Bool { book.isComic || book.ebookFormat == "pdf" }
        func fetchPage(_ pageNumber: Int, for book: Book) async throws -> Data { imageData }
        func fetchComicReadingDirection(for book: Book) async throws -> ComicReadingDirection? {
            directionFetchCount += 1
            if suspendDirection { try await Task.sleep(for: .seconds(30)) }
            if failDirection { throw ProviderError.invalidResponse }
            return direction
        }
    }
}
