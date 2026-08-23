import Combine
import Foundation
import Logging

enum PlaybackQueuePolicy {
    static func playAllCandidates(_ books: [Book]) -> [Book] {
        var seen = Set<String>()
        let playable = books.filter {
            $0.mediaType != .ebook && seen.insert($0.uniqueId).inserted
        }
        let unfinished = playable.filter { !isFinished($0) }
        return unfinished.isEmpty ? playable : unfinished
    }

    static func isFinished(_ book: Book) -> Bool {
        if book.isCompleted { return true }
        guard let status = book.serverReadStatus?.uppercased() else { return false }
        return status == "READ" || status == "COMPLETED" || status == "FINISHED"
    }
}

@MainActor
@Observable
final class PlaybackQueueCoordinator {
    let store: PlaybackQueueStore

    @ObservationIgnored private let appState: AppState
    @ObservationIgnored private let progressStore: UserProgressStore
    @ObservationIgnored private let playback: any PlaybackControlling
    @ObservationIgnored private let playbackStarter: any BookPlaybackStarting
    @ObservationIgnored private let linkedProgress: LinkedBookProgressCoordinator
    @ObservationIgnored private var eventSubscription: AnyCancellable?
    @ObservationIgnored private var completedBookID: String?
    @ObservationIgnored private var handledTerminalBookIDs = Set<String>()
    @ObservationIgnored private var failureAdvanceTask: Task<Void, Never>?
    @ObservationIgnored private var startPlaybackTask: Task<Void, Never>?
    @ObservationIgnored private var startRequestID: UUID?

    init(
        appState: AppState = .shared,
        progressStore: UserProgressStore = .shared,
        playback: any PlaybackControlling = ActivePlayback.composition.controller,
        playbackEvents: any PlaybackEventPublishing = ActivePlayback.composition.eventPublisher,
        playbackStarter: any BookPlaybackStarting = ActivePlayback.composition.bookStarter,
        linkedProgress: LinkedBookProgressCoordinator = .shared,
        store: PlaybackQueueStore = .shared
    ) {
        self.appState = appState
        self.progressStore = progressStore
        self.playback = playback
        self.playbackStarter = playbackStarter
        self.linkedProgress = linkedProgress
        self.store = store

        eventSubscription = playbackEvents.playbackEvents.sink { [weak self] event in
            switch event {
            case .completed(let book): self?.playbackDidComplete(book)
            case .failed(let book): self?.playbackDidFail(book)
            }
        }
    }

    var entries: [PlaybackQueueEntry] { store.entries }

    @discardableResult
    func playAll(_ books: [Book], groupKey: String? = nil) -> Bool {
        let candidates = PlaybackQueuePolicy.playAllCandidates(books)
        guard let first = candidates.first else { return false }

        store.replace(with: Array(candidates.dropFirst()), origin: .playAll, groupKey: groupKey)
        start(first, presentPlayer: true)
        return true
    }

    func playManually(_ book: Book, presentPlayer: Bool) {
        if book.mediaType != .ebook,
            currentBook?.uniqueId != book.uniqueId
        {
            store.clear()
            completedBookID = nil
        }
        beginPlayback(book, presentPlayer: presentPlayer, resetIfFinished: false)
    }

    func prepareForManualReadAloud(_ book: Book) {
        startPlaybackTask?.cancel()
        startPlaybackTask = nil
        startRequestID = nil
        if currentBook?.uniqueId != book.uniqueId {
            store.clear()
            completedBookID = nil
        }
    }

    func addNext(_ book: Book) {
        guard book.mediaType != .ebook else { return }
        if hasActivePlayback {
            guard currentBook?.uniqueId != book.uniqueId else { return }
            store.addNext(book)
        } else {
            store.remove(bookID: book.uniqueId)
            start(book, presentPlayer: true)
        }
    }

    func addLast(_ book: Book) {
        guard book.mediaType != .ebook else { return }
        if hasActivePlayback {
            guard currentBook?.uniqueId != book.uniqueId else { return }
            store.addLast(book)
        } else {
            store.remove(bookID: book.uniqueId)
            start(book, presentPlayer: true)
        }
    }

    func addLast(_ books: [Book], groupKey: String? = nil) {
        var seen = Set<String>()
        let candidates = books.filter {
            $0.mediaType != .ebook && seen.insert($0.uniqueId).inserted
        }
        guard !candidates.isEmpty else { return }

        if hasActivePlayback {
            let currentID = currentBook?.uniqueId
            for book in candidates where book.uniqueId != currentID {
                store.addLast(book, groupKey: groupKey)
            }
        } else {
            let first = candidates[0]
            store.replace(with: Array(candidates.dropFirst()), origin: .manual, groupKey: groupKey)
            start(first, presentPlayer: true)
        }
    }

    func playQueued(bookID: String) {
        guard let selected = store.entries.first(where: { $0.id == bookID }) else { return }
        let previous = currentBook
        store.remove(bookID: bookID)
        if let previous,
            previous.uniqueId != selected.book.uniqueId,
            !PlaybackQueuePolicy.isFinished(previous)
        {
            store.addNext(previous)
        }
        start(selected.book, presentPlayer: appState.presentation.isPlayerPresented)
    }

    func remove(bookID: String) {
        store.remove(bookID: bookID)
    }

    func move(bookID: String, by delta: Int) {
        store.move(bookID: bookID, by: delta)
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        store.move(fromOffsets: offsets, toOffset: destination)
    }

    func clear() {
        store.clear()
    }

    private var currentBook: Book? { playback.snapshot.currentBook }

    private var hasActivePlayback: Bool {
        let snapshot = playback.snapshot
        guard let current = snapshot.currentBook else { return false }
        if completedBookID == current.uniqueId { return false }
        return snapshot.isLoaded || snapshot.isLoading
    }

    private func playbackDidComplete(_ book: Book) {
        guard currentBook?.uniqueId == book.uniqueId,
            handledTerminalBookIDs.insert(book.uniqueId).inserted
        else { return }
        completedBookID = book.uniqueId
        let preferences = LibraryDisplayPreferencesStore.shared.loadPreferences()
        guard preferences.continuousPlaybackEnabled else { return }
        if startNextQueued(preservingPlayerPresentation: true) { return }
        guard preferences.autoPlayNextInSeries else { return }
        Task { @MainActor [weak self] in
            await self?.startNextInSeries(after: book)
        }
    }

    private func startNextInSeries(after book: Book) async {
        guard let seriesName = book.seriesInfo?.name else { return }
        let seriesBooks = await appState.bookStore.books(inSeries: seriesName)
        guard let next = SeriesAutoAdvancePolicy.nextBook(after: book, in: seriesBooks) else { return }

        guard currentBook == nil || currentBook?.uniqueId == book.uniqueId else { return }
        AppLogger.player.info("Series auto-advance: playing next in \(seriesName)")
        start(next, presentPlayer: appState.presentation.isPlayerPresented)
    }

    private func playbackDidFail(_ book: Book) {
        guard currentBook?.uniqueId == book.uniqueId,
            handledTerminalBookIDs.insert(book.uniqueId).inserted,
            !store.entries.isEmpty
        else { return }
        failureAdvanceTask?.cancel()
        failureAdvanceTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.currentBook?.uniqueId == book.uniqueId else { return }
            self.startNextQueued(preservingPlayerPresentation: true)
        }
    }

    @discardableResult
    private func startNextQueued(preservingPlayerPresentation: Bool) -> Bool {
        guard let next = store.takeNext() else { return false }
        start(
            next.book,
            presentPlayer: preservingPlayerPresentation && appState.presentation.isPlayerPresented
        )
        return true
    }

    private func start(_ book: Book, presentPlayer: Bool) {
        failureAdvanceTask?.cancel()
        failureAdvanceTask = nil
        completedBookID = nil

        beginPlayback(book, presentPlayer: presentPlayer, resetIfFinished: true)
    }

    private func beginPlayback(
        _ book: Book,
        presentPlayer: Bool,
        resetIfFinished: Bool
    ) {
        handledTerminalBookIDs.remove(book.uniqueId)
        startPlaybackTask?.cancel()
        let requestID = UUID()
        startRequestID = requestID
        startPlaybackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.linkedProgress.reconcilePair(for: book)
            guard !Task.isCancelled, self.startRequestID == requestID else { return }

            var playable = self.appState.bookInMemory(uniqueId: book.uniqueId) ?? book
            if self.appState.bookInMemory(uniqueId: book.uniqueId) == nil,
                let stored = await self.appState.bookStore.book(uniqueId: book.uniqueId)
            {
                playable = stored
            }
            if resetIfFinished, PlaybackQueuePolicy.isFinished(playable) {
                self.progressStore.resetToBeginning(for: playable)
                let observedAt = Date()
                await self.linkedProgress.resetPair(from: playable, observedAt: observedAt)
                guard !Task.isCancelled, self.startRequestID == requestID else { return }
                playable.currentTime = 0
                playable.isFinished = false
                playable.serverReadStatus = nil
                playable.lastUpdate = observedAt
            }
            self.playbackStarter.play(playable, presentPlayer: presentPlayer)
            self.startPlaybackTask = nil
            self.startRequestID = nil
        }
    }
}
