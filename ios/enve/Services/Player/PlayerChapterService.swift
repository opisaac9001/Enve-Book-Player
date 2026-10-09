import Combine
import Foundation
import Logging

public final class PlayerChapterService: ObservableObject {
    static let shared = PlayerChapterService(
        currentBook: { AppState.shared.currentBook },
        updateCurrentBook: { AppState.shared.currentBook = $0 },
        bookLookup: { bookId in await AppState.shared.bookStore.book(byAnyId: bookId) },
        playbackBookUpdater: { book, chapters in
            ActivePlayback.composition.bookMetadataUpdater.updateChapters(chapters, for: book)
        },
        serverBookLookup: { book in
            guard NetworkPolicyService.shared.isConnected else { return nil }
            return await EnveEngine.shared.library.refreshDetails(for: book)
        }
    )

    @Published public private(set) var chapters: [Chapter] = []
    @Published public private(set) var currentChapter: Chapter?

    private let readerArtifacts: ReaderArtifactsStore
    private let metadataStorage: MetadataStorage
    private let currentBook: @MainActor () -> Book?
    private let updateCurrentBook: @MainActor (Book?) -> Void
    private let bookLookup: (String) async -> Book?
    private let playbackBookUpdater: (Book, [Chapter]) -> Void
    private let serverBookLookup: @MainActor (Book) async -> Book?

    init(
        currentBook: @escaping @MainActor () -> Book?,
        updateCurrentBook: @escaping @MainActor (Book?) -> Void,
        bookLookup: @escaping (String) async -> Book?,
        playbackBookUpdater: @escaping (Book, [Chapter]) -> Void,
        serverBookLookup: @escaping @MainActor (Book) async -> Book?,
        readerArtifacts: ReaderArtifactsStore = .shared, metadataStorage: MetadataStorage = .shared
    ) {
        self.readerArtifacts = readerArtifacts
        self.metadataStorage = metadataStorage
        self.currentBook = currentBook
        self.updateCurrentBook = updateCurrentBook
        self.bookLookup = bookLookup
        self.playbackBookUpdater = playbackBookUpdater
        self.serverBookLookup = serverBookLookup
    }

    public func loadChapters(for book: Book) async {
        if let bookChapters = book.chapters, !bookChapters.isEmpty {
            await MainActor.run {
                self.chapters = bookChapters
            }
            return
        }

        if let cached = readerArtifacts.loadCachedAudioChapters(for: book),
            !cached.isEmpty
        {
            AppLogger.player.debug(
                "Loaded \(cached.count) cached chapters bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
            )
            await MainActor.run {
                self.chapters = cached
            }
            return
        }

        AppLogger.player.debug(
            "No cached chapters bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
        )
    }

    public func updateCurrentChapter(at position: TimeInterval) {
        guard !chapters.isEmpty else { return }

        let foundChapter = chapters.last { position >= $0.startTime }
        if foundChapter?.id != currentChapter?.id {
            currentChapter = foundChapter
        }
    }

    public func applyChapters(_ newChapters: [Chapter], for book: Book) {
        guard !newChapters.isEmpty else { return }
        readerArtifacts.saveCachedChapters(bookId: book.stableId, chapters: newChapters)
        if book.id != book.stableId {
            readerArtifacts.saveCachedChapters(bookId: book.id, chapters: newChapters)
        }
        chapters = newChapters

        if var active = currentBook(), isSameBook(active, book) {
            active.chapters = newChapters
            updateCurrentBook(active)
        }
        playbackBookUpdater(book, newChapters)
    }

    // Library lists and stored book records carry no chapters, so a download must save them for offline play.
    public func fetchAndCacheChaptersAfterDownload(bookId: String) async {
        guard let book = await bookLookup(bookId),
            readerArtifacts.loadCachedAudioChapters(for: book) == nil
        else { return }

        if AudiobookPlaybackPolicy.chaptersNeedRefresh(for: book) {
            await refreshChaptersFromServer(for: book)
        } else {
            await ChapterMetadataCache.cache(book, readerArtifacts: readerArtifacts, metadataStorage: metadataStorage)
        }
    }

    @discardableResult
    public func refreshChaptersFromServer(for book: Book) async -> Bool {
        guard let serverChapters = await serverBookLookup(book)?.chapters, !serverChapters.isEmpty else {
            return false
        }
        var updated = book
        updated.chapters = serverChapters
        await ChapterMetadataCache.cache(updated, readerArtifacts: readerArtifacts, metadataStorage: metadataStorage)
        if let active = currentBook(), isSameBook(active, book) {
            applyChapters(serverChapters, for: book)
        }
        return true
    }

    private func isSameBook(_ lhs: Book, _ rhs: Book) -> Bool {
        lhs.uniqueId == rhs.uniqueId || lhs.stableId == rhs.stableId || lhs.id == rhs.id
    }
}
