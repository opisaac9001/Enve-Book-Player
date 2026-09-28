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

    func ebookChapterIndex(forAudiobookChapter abIndex: Int, ebook: Book) -> Int? {
        let offset = ebook.linkedAudiobookChapterOffset
        let ebookIndex = abIndex - offset
        guard let chapters = ebook.chapters, ebookIndex >= 0, ebookIndex < chapters.count else { return nil }
        return ebookIndex
    }

    func audiobookTimeForEbookChapter(_ ebookChapterIndex: Int, ebook: Book) -> TimeInterval? {
        guard let audiobook = linkedAudiobook(for: ebook) else { return nil }
        // Stored library books carry no chapters; the player caches them separately.
        let chapters =
            audiobook.chapters.flatMap { $0.isEmpty ? nil : $0 }
            ?? ReaderArtifactsStore.shared.loadCachedChapters(bookId: audiobook.stableId)
            ?? ReaderArtifactsStore.shared.loadCachedChapters(bookId: audiobook.id)
            ?? []
        let abIndex = ebookChapterIndex + ebook.linkedAudiobookChapterOffset
        guard chapters.indices.contains(abIndex) else { return nil }
        return chapters[abIndex].start
    }

    #if os(iOS)
    /// The linked recording's time for a reading position: the sentence's own time when the EPUB narration is
    /// that same recording, otherwise the start of the mapped chapter.
    func audiobookTime(
        forReadingLocator locatorJSON: String?,
        chapterIndex: Int?,
        ebook: Book,
        audiobook: Book
    ) async -> TimeInterval? {
        if let locatorJSON, let audioDuration = audiobook.duration,
            let timeline = await MediaOverlayPlaybackService.shared.overlayTimeline(forLocalBook: ebook),
            let narrated = Self.narratedAudioTime(locatorJSON: locatorJSON, timeline: timeline, audioDuration: audioDuration)
        {
            return narrated
        }
        return chapterIndex.flatMap { audiobookTimeForEbookChapter($0, ebook: ebook) }
    }

    static func narratedAudioTime(
        locatorJSON: String,
        timeline: MediaOverlayTimeline,
        audioDuration: TimeInterval
    ) -> TimeInterval? {
        guard LinkedBookProgressCoordinator.narrationMatchesAudio(
            narrationDuration: timeline.totalAudioDuration,
            audioDuration: audioDuration
        ),
            let resolved = timeline.resolveEPUB3Locator(locatorJSON: locatorJSON)
        else { return nil }
        return resolved.audioTime * audioDuration / timeline.totalAudioDuration
    }
    #endif
}
