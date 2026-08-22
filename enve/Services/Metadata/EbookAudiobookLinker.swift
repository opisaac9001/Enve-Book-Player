import Foundation
import Logging

@MainActor
final class EbookAudiobookLinker {
    static let shared = EbookAudiobookLinker()

    private let libraryCache: LibraryBookCache
    private let bookRepository: BookStoreRepository

    private init(
        libraryCache: LibraryBookCache = AppState.shared.libraryCache,
        bookRepository: BookStoreRepository = AppState.shared.bookStore
    ) {
        self.libraryCache = libraryCache
        self.bookRepository = bookRepository
    }

    private var ebookToAudiobookCache: [String: Book] = [:]
    private var audiobookToEbookCache: [String: Book] = [:]
    private(set) var cacheGeneration: Int = 0
    private var lastCacheFingerprint: Int = 0

    func invalidateCache() {
        ebookToAudiobookCache.removeAll()
        audiobookToEbookCache.removeAll()
        lastCacheFingerprint = .min
        cacheGeneration += 1
    }

    func rebuildCacheIfNeeded() async {
        let ebooks = await self.bookRepository.firstBooks(mediaType: "ebook", limit: 5000)
        let audiobooks = await self.bookRepository.firstBooks(mediaType: "audiobook", limit: 5000)
        var hasher = Hasher()
        hasher.combine(ebooks.count + audiobooks.count)
        for book in ebooks {
            hasher.combine(book.stableId)
            hasher.combine(book.linkedAudiobookStableId)
        }
        let fingerprint = hasher.finalize()
        guard fingerprint != lastCacheFingerprint || ebookToAudiobookCache.isEmpty else { return }
        lastCacheFingerprint = fingerprint

        var e2a: [String: Book] = [:]
        var a2e: [String: Book] = [:]
        let audiobooksByStableId = Dictionary(
            audiobooks.map { ($0.stableId, $0) },
            uniquingKeysWith: { _, new in new }
        )

        for book in ebooks {
            if let linkedId = book.linkedAudiobookStableId,
                let linked = audiobooksByStableId[linkedId]
            {
                e2a[book.stableId] = linked
                a2e[linked.stableId] = book
            }
        }

        ebookToAudiobookCache = e2a
        audiobookToEbookCache = a2e
        cacheGeneration += 1
    }

    func hasLinkedAudiobook(for ebook: Book) -> Bool {
        guard ebook.mediaType == .ebook else { return false }
        if ebook.linkedAudiobookStableId != nil { return true }
        if ebookToAudiobookCache[ebook.stableId] != nil { return true }
        return linkedAudiobook(for: ebook) != nil
    }

    func hasLinkedEbook(for audiobook: Book) -> Bool {
        guard audiobook.mediaType == .audiobook else { return false }
        if audiobookToEbookCache[audiobook.stableId] != nil { return true }
        return linkedEbook(for: audiobook) != nil
    }

    func linkedEbook(for audiobook: Book) -> Book? {
        guard audiobook.mediaType == .audiobook else { return nil }

        return audiobookToEbookCache[audiobook.stableId]
    }

    func linkedAudiobook(for ebook: Book) -> Book? {
        guard ebook.mediaType == .ebook else { return nil }

        if let cached = ebookToAudiobookCache[ebook.stableId] {
            return cached
        }

        if let linkedId = ebook.linkedAudiobookStableId,
            let linked = self.libraryCache.bookInMemory(stableId: linkedId),
            linked.mediaType == .audiobook
        {
            ebookToAudiobookCache[ebook.stableId] = linked
            audiobookToEbookCache[linked.stableId] = ebook
            return linked
        }

        return nil
    }

    func linkedAudiobookAsync(for ebook: Book) async -> Book? {
        if let sync = linkedAudiobook(for: ebook) { return sync }
        guard let abStableId = await self.bookRepository.linkedAudiobookStableId(forEbookStableId: ebook.stableId) else { return nil }
        guard let linked = await self.bookRepository.book(stableId: abStableId),
            linked.mediaType == .audiobook
        else { return nil }
        ebookToAudiobookCache[ebook.stableId] = linked
        audiobookToEbookCache[linked.stableId] = ebook
        return linked
    }

    func linkedEbookAsync(for audiobook: Book) async -> Book? {
        if let sync = linkedEbook(for: audiobook) { return sync }
        guard let ebStableId = await self.bookRepository.linkedEbookStableId(forAudiobookStableId: audiobook.stableId) else {
            return nil
        }
        guard let linked = await self.bookRepository.book(stableId: ebStableId),
            linked.mediaType == .ebook
        else { return nil }
        audiobookToEbookCache[audiobook.stableId] = linked
        ebookToAudiobookCache[linked.stableId] = audiobook
        return linked
    }

    func currentAudiobookChapterIndex(for audiobook: Book) -> Int? {
        guard let chapters = audiobook.chapters, !chapters.isEmpty else { return nil }
        let currentTime = audiobook.currentTime
        for (i, chapter) in chapters.enumerated().reversed() {
            if currentTime >= chapter.start {
                return i
            }
        }
        return 0
    }

    func ebookChapterIndex(forAudiobookChapter abIndex: Int, ebook: Book) -> Int? {
        let offset = ebook.linkedAudiobookChapterOffset
        let ebookIndex = abIndex - offset
        guard let chapters = ebook.chapters, ebookIndex >= 0, ebookIndex < chapters.count else { return nil }
        return ebookIndex
    }

    func audiobookChapterIndex(forEbookChapter ebIndex: Int, ebook: Book) -> Int? {
        guard let audiobook = linkedAudiobook(for: ebook) else { return nil }
        let offset = ebook.linkedAudiobookChapterOffset
        let abIndex = ebIndex + offset
        guard let chapters = audiobook.chapters, abIndex >= 0, abIndex < chapters.count else { return nil }
        return abIndex
    }

    func audiobookTimeForEbookChapter(_ ebookChapterIndex: Int, ebook: Book) -> TimeInterval? {
        guard let audiobook = linkedAudiobook(for: ebook),
            let abIndex = audiobookChapterIndex(forEbookChapter: ebookChapterIndex, ebook: ebook),
            let chapters = audiobook.chapters,
            abIndex < chapters.count
        else { return nil }
        return chapters[abIndex].start
    }

    func persistResolvedLink(ebookStableId: String, audiobookStableId: String, offset: Int) {
        guard let current = self.libraryCache.bookInMemory(stableId: ebookStableId),
            current.mediaType == .ebook
        else {
            return
        }

        let needsUpdate =
            current.linkedAudiobookStableId != audiobookStableId
            || current.linkedAudiobookChapterOffset != offset
        if needsUpdate {
            self.libraryCache.mutateBook(stableId: ebookStableId) {
                $0.linkedAudiobookStableId = audiobookStableId
                $0.linkedAudiobookChapterOffset = offset
            }
            EbookLinkStore.shared.saveLinks()
        }
        invalidateCache()

        Task(priority: .utility) {
            await self.bookRepository.upsertLink(
                ebookStableId: ebookStableId,
                audiobookStableId: audiobookStableId,
                chapterOffset: offset
            )
        }
    }
}
