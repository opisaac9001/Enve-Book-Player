import Foundation
import Logging

@MainActor
final class EbookLinkStore {
    static let shared = EbookLinkStore()

    private let library: LibraryBookCache
    private let repository: any ReaderArtifactRepository
    private let books: any BookQuerying

    init(
        library: LibraryBookCache = AppState.shared.libraryCache,
        repository: any ReaderArtifactRepository = AppState.shared.bookStore,
        books: any BookQuerying = AppState.shared.bookStore
    ) {
        self.library = library
        self.repository = repository
        self.books = books
    }

    @discardableResult
    func saveLinks() -> Task<Void, Never>? {
        let links = library.books.compactMap { book -> (ebookStableId: String, audiobookStableId: String, chapterOffset: Int)? in
            guard book.mediaType == .ebook,
                let linked = book.linkedAudiobookStableId,
                !linked.isEmpty
            else { return nil }
            return (ebookStableId: book.stableId, audiobookStableId: linked, chapterOffset: book.linkedAudiobookChapterOffset)
        }
        guard !links.isEmpty else { return nil }
        let repository = repository
        return Task { await repository.importLegacyLinks(links) }
    }

    func reapplyLinks() async {
        let stored = await repository.allLinks()
        guard !stored.isEmpty else { return }

        let candidateAudiobookIds = Set(stored.map(\.audiobookStableId))
        let validAudiobookIds = await books.existingAudiobookStableIds(from: candidateAudiobookIds)
        let cleaned = stored.filter { validAudiobookIds.contains($0.audiobookStableId) }
        if cleaned.count != stored.count {
            await repository.importLegacyLinks(cleaned)
        }

        var applied = 0
        for link in cleaned {
            guard let index = library.stableIdIndex[link.ebookStableId], library.books.indices.contains(index) else { continue }
            let book = library.books[index]
            let needsUpdate =
                book.linkedAudiobookStableId != link.audiobookStableId
                || book.linkedAudiobookChapterOffset != link.chapterOffset
            guard needsUpdate else { continue }
            library.books[index].linkedAudiobookStableId = link.audiobookStableId
            library.books[index].linkedAudiobookChapterOffset = link.chapterOffset
            applied += 1
        }
        if applied > 0 {
            AppLogger.general.info("Restored \(applied) ebook-audiobook link(s) from BookStore")
        }
    }
}
