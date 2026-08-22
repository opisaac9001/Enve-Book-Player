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
        }
    )

    @Published public private(set) var chapters: [Chapter] = []
    @Published public private(set) var currentChapter: Chapter?

    private let currentBook: @MainActor () -> Book?
    private let updateCurrentBook: @MainActor (Book?) -> Void
    private let bookLookup: (String) async -> Book?
    private let playbackBookUpdater: (Book, [Chapter]) -> Void

    init(
        currentBook: @escaping @MainActor () -> Book?,
        updateCurrentBook: @escaping @MainActor (Book?) -> Void,
        bookLookup: @escaping (String) async -> Book?,
        playbackBookUpdater: @escaping (Book, [Chapter]) -> Void
    ) {
        self.currentBook = currentBook
        self.updateCurrentBook = updateCurrentBook
        self.bookLookup = bookLookup
        self.playbackBookUpdater = playbackBookUpdater
    }

    public func loadChapters(for book: Book) async {
        if let bookChapters = book.chapters, !bookChapters.isEmpty {
            await MainActor.run {
                self.chapters = bookChapters
            }
            return
        }

        if let cached = ReaderArtifactsStore.shared.loadCachedChapters(bookId: book.stableId)
            ?? ReaderArtifactsStore.shared.loadCachedChapters(bookId: book.id),
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
        ReaderArtifactsStore.shared.saveCachedChapters(bookId: book.stableId, chapters: newChapters)
        if book.id != book.stableId {
            ReaderArtifactsStore.shared.saveCachedChapters(bookId: book.id, chapters: newChapters)
        }
        chapters = newChapters

        if var active = currentBook(), isSameBook(active, book) {
            active.chapters = newChapters
            updateCurrentBook(active)
        }
        playbackBookUpdater(book, newChapters)
    }

    public func fetchAndCacheChaptersAfterDownload(bookId: String) async {
        if let cached = ReaderArtifactsStore.shared.loadCachedChapters(bookId: bookId), !cached.isEmpty {
            await MainActor.run {
                self.chapters = cached
            }
            return
        }

        if let book = await bookLookup(bookId),
            let bookChapters = book.chapters, !bookChapters.isEmpty
        {
            ReaderArtifactsStore.shared.saveCachedChapters(bookId: book.stableId, chapters: bookChapters)
            if book.id != book.stableId {
                ReaderArtifactsStore.shared.saveCachedChapters(bookId: book.id, chapters: bookChapters)
            }
            await MainActor.run {
                self.chapters = bookChapters
            }
        }
    }

    private func isSameBook(_ lhs: Book, _ rhs: Book) -> Bool {
        lhs.uniqueId == rhs.uniqueId || lhs.stableId == rhs.stableId || lhs.id == rhs.id
    }
}
