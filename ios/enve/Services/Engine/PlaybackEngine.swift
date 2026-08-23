import Foundation

@MainActor
@Observable
final class PlaybackEngine {
    private let appState: AppState
    private let playbackController: any PlaybackControlling
    private let readerOpen: ReaderOpenCoordinator
    private let linkedProgress: LinkedBookProgressCoordinator
    private let readAloudPlayback: AlignedReadAloudSessionCoordinator
    @ObservationIgnored private var readAloudPlayTask: Task<Void, Never>?
    let queue: PlaybackQueueCoordinator

    init(
        appState: AppState = .shared,
        playbackController: any PlaybackControlling = ActivePlayback.composition.controller,
        playbackEvents: any PlaybackEventPublishing = ActivePlayback.composition.eventPublisher,
        readerOpen: ReaderOpenCoordinator = .shared,
        linkedProgress: LinkedBookProgressCoordinator = .shared,
        readAloudPlayback: AlignedReadAloudSessionCoordinator = .shared,
        queueStore: PlaybackQueueStore = .shared
    ) {
        self.appState = appState
        self.playbackController = playbackController
        self.readerOpen = readerOpen
        self.linkedProgress = linkedProgress
        self.readAloudPlayback = readAloudPlayback
        self.queue = PlaybackQueueCoordinator(
            appState: appState,
            playback: playbackController,
            playbackEvents: playbackEvents,
            linkedProgress: linkedProgress,
            store: queueStore
        )
    }

    var currentBook: Book? {
        playbackController.snapshot.currentBook ?? appState.currentBook ?? PlayerViewModel.shared.currentBook
    }

    var currentChapter: Chapter? {
        PlayerViewModel.shared.currentChapter
    }

    func play(_ book: Book, presentPlayer: Bool = true) {
        if book.hasEPUB3MediaOverlay {
            playAlignedReadAloud(book, presentPlayer: presentPlayer)
            return
        }
        if book.mediaType == .ebook {
            readerOpen.open(book)
            return
        }
        queue.playManually(book, presentPlayer: presentPlayer)
    }

    func playAlignedReadAloud(_ book: Book, presentPlayer: Bool = true) {
        queue.prepareForManualReadAloud(book)
        readAloudPlayTask?.cancel()
        readAloudPlayTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.linkedProgress.reconcilePair(for: book)
            guard !Task.isCancelled else { return }
            let playable = self.appState.bookInMemory(uniqueId: book.uniqueId) ?? book
            self.readAloudPlayback.play(playable, presentPlayer: presentPlayer)
            self.readAloudPlayTask = nil
        }
    }

    @discardableResult
    func playAll(_ books: [Book], groupKey: String? = nil) -> Bool {
        queue.playAll(books, groupKey: groupKey)
    }

    func addNext(_ book: Book) {
        queue.addNext(book)
    }

    func addLast(_ book: Book) {
        queue.addLast(book)
    }

    func addLast(_ books: [Book], groupKey: String? = nil) {
        queue.addLast(books, groupKey: groupKey)
    }

    func playQueued(bookID: String) {
        queue.playQueued(bookID: bookID)
    }

    func removeQueued(bookID: String) {
        queue.remove(bookID: bookID)
    }

    func moveQueued(bookID: String, by delta: Int) {
        queue.move(bookID: bookID, by: delta)
    }

    func moveQueued(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        queue.move(fromOffsets: offsets, toOffset: destination)
    }

    func clearQueue() {
        queue.clear()
    }

    func dismissPlayer() {
        if appState.presentation.isPlayerPresented {
            appState.presentation.isPlayerPresented = false
        }
    }

    func openEbook(_ book: Book) {
        readerOpen.open(book)
    }

    func presentReader(for book: Book) {
        readerOpen.open(book)
    }

    func presentReaderAfterDismissingPlayer(for book: Book) {
        dismissPlayer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.presentReader(for: book)
        }
    }

    func restoreLastPlayedIntoMantelIfAvailable() -> Bool {
        if appState.currentBook != nil { return true }
        guard let restored = PlayerViewModel.shared.currentBook else { return false }
        appState.currentBook = restored
        return true
    }

    func openDebugRouteBook(_ book: Book) {
        #if DEBUG
        if book.hasEPUB3MediaOverlay,
            ProcessInfo.processInfo.arguments.contains("--exercise-listen")
        {
            playAlignedReadAloud(book, presentPlayer: false)
            return
        }
        #endif
        if book.mediaType == .ebook {
            presentReader(for: book)
        } else {
            play(book)
        }
    }

    func playChapter(_ chapter: Chapter, in book: Book) {
        if playbackController.snapshot.currentBook?.stableId == book.stableId,
            playbackController.snapshot.isLoaded
        {
            playbackController.seek(to: chapter.start)
            appState.presentation.isPlayerPresented = true
            return
        }

        play(book)
        Task {
            for _ in 0..<20 {
                if playbackController.snapshot.currentBook?.stableId == book.stableId,
                    !playbackController.snapshot.isLoading
                {
                    break
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            guard playbackController.snapshot.currentBook?.stableId == book.stableId else { return }
            playbackController.seek(to: chapter.start)
        }
    }

    func isLive(_ book: Book) -> Bool {
        playbackController.snapshot.currentBook?.stableId == book.stableId
            && playbackController.snapshot.isLoaded
    }

    func position(for book: Book) -> TimeInterval {
        isLive(book) ? playbackController.snapshot.position : book.currentTime
    }

    func duration(for book: Book) -> TimeInterval? {
        isLive(book) ? playbackController.snapshot.duration : book.duration
    }

    var currentDurationFallback: TimeInterval {
        currentBook?.duration ?? 0
    }

    var currentChapters: [Chapter] {
        currentBook?.chapters ?? []
    }

    func progressFraction(for book: Book) -> Double {
        if book.mediaType == .ebook {
            return book.canonicalEbookProgress
        }
        guard let duration = duration(for: book), duration > 0 else { return 0 }
        return min(max(position(for: book) / duration, 0), 1)
    }
}
