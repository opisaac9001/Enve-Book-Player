import Foundation
import Testing

@testable import enve

@MainActor
struct ReaderPagedContentControllerTests {
    @Test func serverFormatReplacesAStaleCachedFormatBeforeOpening() async {
        let provider = PagesProvider(format: "cbz", pageCount: 3)
        let reader = makeReader(provider: provider, cachedFormat: "epub")
        defer { reader.endServerPageStreamingSession() }

        #expect(!reader.isComicBook)
        await reader.refreshServerFormatIfNeeded()
        #expect(reader.isComicBook)
        #expect(await reader.openServerStreamedComicIfAvailable())
        #expect(reader.comicPages.count == 3)
    }

    @Test func streamedPagesUseComicBehaviorEvenWithoutAnArchiveFormat() async {
        let provider = PagesProvider(format: "pdf", pageCount: 3)
        let reader = makeReader(provider: provider, cachedFormat: "pdf")
        defer { reader.endServerPageStreamingSession() }

        #expect(!reader.isComicBook)
        #expect(await reader.openServerStreamedComicIfAvailable())
        #expect(reader.isComicBook)
    }

    @Test func aReflowableEPUBWithoutPagesKeepsItsBookReader() async {
        let provider = PagesProvider(format: "epub", pageCount: 0)
        let reader = makeReader(provider: provider, cachedFormat: nil)
        await reader.refreshServerFormatIfNeeded()

        #expect(!(await reader.openServerStreamedComicIfAvailable()))
        #expect(!reader.isComicBook)
        #expect(reader.comicPages.isEmpty)
    }

    private func makeReader(provider: PagesProvider, cachedFormat: String?) -> ReaderPagedContentController {
        ReaderPagedContentController(
            book: Book(id: "issue", title: "Issue", source: .komga, mediaType: .ebook,
                       ebookFormat: cachedFormat, providerId: provider.connection.id, libraryId: "comics"),
            providerResolver: Resolver(provider: provider),
            libraryCache: LibraryBookCache(),
            appearanceController: ReaderAppearanceController(appearance: ClassicReaderAppearance(), persist: { _ in })
        )
    }

    private final class Resolver: LibraryProviderResolving {
        let provider: PagesProvider
        init(provider: PagesProvider) { self.provider = provider }
        func provider(for providerId: UUID) -> LibraryProvider? { provider }
        func provider(for book: Book) -> LibraryProvider? { provider }
    }

    private final class PagesProvider: @MainActor LibraryProvider, @MainActor ServerPageProvider {
        var connection = ServerConnection(name: "Comics", url: "https://comics.example", type: .komga)
        var capabilities: ProviderCapabilities { [.serverPageStreaming] }
        let format: String
        let pageCount: Int

        init(format: String, pageCount: Int) {
            self.format = format
            self.pageCount = pageCount
        }

        func validateConnection() async throws -> Bool { true }
        func fetchLibraries() async throws -> [Library] { [] }
        func fetchBooks(libraryId: String) async throws -> [Book] { [] }
        func fetchRecentBooks(libraryId: String, limit: Int) async throws -> [Book] { [] }
        func fetchCollections(libraryId: String?) async throws -> [Collection] { [] }
        func fetchSeries(libraryId: String) async throws -> [Series] { [] }
        func fetchUserMediaProgress(libraryId: String) async throws -> [UserMediaProgress] { [] }
        func fetchFullBookDetails(bookId: String, libraryId: String) async throws -> Book {
            Book(id: bookId, title: "Issue", source: .komga, mediaType: .ebook,
                 ebookFormat: format, providerId: connection.id, libraryId: libraryId)
        }
        func fetchPageCount(for book: Book) async throws -> Int { pageCount }
        func fetchPage(_ pageNumber: Int, for book: Book) async throws -> Data { Data() }
    }
}
