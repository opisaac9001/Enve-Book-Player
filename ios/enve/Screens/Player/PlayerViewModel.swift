import Combine
import Foundation
import Logging

#if os(iOS)
import UIKit
#endif

public struct ProgressConflict {
    public let localProgress: TimeInterval
    public let remoteProgress: TimeInterval
    public let remoteName: String
    public let onChooseLocal: () -> Void
    public let onChooseRemote: () -> Void
    public let autoAcceptRemote: Bool

    public init(
        localProgress: TimeInterval,
        remoteProgress: TimeInterval,
        remoteName: String,
        onChooseLocal: @escaping () -> Void,
        onChooseRemote: @escaping () -> Void,
        autoAcceptRemote: Bool = false
    ) {
        self.localProgress = localProgress
        self.remoteProgress = remoteProgress
        self.remoteName = remoteName
        self.onChooseLocal = onChooseLocal
        self.onChooseRemote = onChooseRemote
        self.autoAcceptRemote = autoAcceptRemote
    }
}

@MainActor
protocol PlayerLibraryCaching: AnyObject {
    var currentBook: Book? { get set }

    func ensureBookInMemory(_ book: Book)
    func indexInMemory(stableId: String) -> Int?

    @discardableResult
    func mutateBook(stableId: String, _ transform: (inout Book) -> Void) -> Book?

    @discardableResult
    func mutateBook(uniqueId: String, _ transform: (inout Book) -> Void) -> Book?
}

extension AppState: PlayerLibraryCaching {}

@Observable
public class PlayerViewModel {
    public static let shared: PlayerViewModel = {
        let appState = AppState.shared
        return PlayerViewModel(
            providerConnections: appState.providerConnections,
            bookQuerying: appState.bookStore,
            readerArtifacts: appState.bookStore,
            libraryCache: appState
        )
    }()

    var currentBook: Book? {
        playbackSnapshot.currentBook ?? restoredBook
    }

    @ObservationIgnored private(set) var currentBookWasRestored = false
    var isPlaying: Bool { playbackSnapshot.isPlaying }
    var progress: TimeInterval {
        playbackSnapshot.currentBook == nil ? restoredProgress : playbackSnapshot.position
    }
    var duration: TimeInterval {
        playbackSnapshot.currentBook == nil ? restoredDuration : playbackSnapshot.duration
    }
    var chapters: [Chapter] = []
    var currentChapter: Chapter?
    var playbackConflict: PlaybackProgressConflict?

    private var playbackSnapshot: PlaybackSnapshot
    private var restoredBook: Book?
    private var restoredProgress: TimeInterval = 0
    private var restoredDuration: TimeInterval = 0

    @ObservationIgnored private let isPlayingSubject: CurrentValueSubject<Bool, Never>
    @ObservationIgnored private let progressSubject: CurrentValueSubject<TimeInterval, Never>
    @ObservationIgnored private let preferencesSubject: CurrentValueSubject<UserPreferences, Never>

    var nextChapterInList: Chapter? {
        guard let current = currentChapter,
            let index = chapters.firstIndex(where: { $0.id == current.id }),
            index < chapters.count - 1
        else {
            return nil
        }
        return chapters[index + 1]
    }
    var sleepTimer: Date?
    var sleepTimerRemainingSeconds: TimeInterval = 0
    var isFadingOut = false
    var bookmarks: [Bookmark] = []
    var preferences: UserPreferences {
        didSet { preferencesSubject.send(preferences) }
    }

    var playbackSpeed: Double {
        playbackSnapshot.playbackSpeed
    }
    var isPlaybackLoaded: Bool { playbackSnapshot.isLoaded }
    var supportsIndependentPitch: Bool { false }
    var supportsMonoMix: Bool { monoMixController != nil }
    var supportsStereoBalance: Bool { stereoBalanceController != nil }
    var supportsNoiseReduction: Bool { false }
    var supportsBinauralAudio: Bool { false }
    var error: Error?
    var isLoading: Bool { playbackSnapshot.isLoading }

    @ObservationIgnored private let playbackController: any PlaybackControlling
    @ObservationIgnored private let bookStarter: any BookPlaybackStarting
    @ObservationIgnored private let restorationPreparer: (any RestoredPlaybackPreparing)?
    @ObservationIgnored private let audioProcessingController: any PlaybackAudioProcessingControlling
    @ObservationIgnored private let monoMixController: (any PlaybackMonoMixControlling)?
    @ObservationIgnored private let stereoBalanceController: (any PlaybackStereoBalanceControlling)?
    @ObservationIgnored private let conflictResolver: (any PlaybackConflictResolving)?
    @ObservationIgnored private let storageService: StorageService
    @ObservationIgnored private let providerConnections: any ProviderConnectionAccessing
    @ObservationIgnored private let bookQuerying: any BookQuerying
    @ObservationIgnored private let readerArtifacts: any ReaderArtifactRepository
    @ObservationIgnored private let libraryCache: any PlayerLibraryCaching
    @ObservationIgnored private let streamResolver: PlayerStreamURLResolver

    @ObservationIgnored private let progressService: PlayerProgressService
    @ObservationIgnored private let bookmarkService: PlayerBookmarkService
    @ObservationIgnored private lazy var sleepTimerService: PlayerSleepTimerService = {
        PlayerSleepTimerService(
            onTimerFinished: { [weak self] _ in
                self?.sleepTimerChapterTargetPosition = nil
                self?.cancelChapterSleepTimerTask()
                self?.resetSleepTimerFade()
                self?.recordSleepTimerFiredPosition()
                self?.pause()
            },
            onFadeProgress: { [weak self] remaining in
                self?.applySleepTimerFade(remainingSeconds: remaining)
            },
            onFadeReset: { [weak self] in
                self?.resetSleepTimerFade()
            }
        )
    }()
    @ObservationIgnored private let chapterService: PlayerChapterService
    @ObservationIgnored private let sessionService: PlayerSessionService

    @ObservationIgnored private var cancellables = Set<AnyCancellable>()

    @ObservationIgnored private var sleepTimerChapterTargetPosition: TimeInterval?
    @ObservationIgnored private var sleepTimerChapterFadeOut: Bool = false
    @ObservationIgnored private var chapterSleepTimerTask: Task<Void, Never>?
    @ObservationIgnored private var lifecycleObservers: [AnyCancellable] = []

    @ObservationIgnored private var lastAllBooksPublishTime: Date = .distantPast
    @ObservationIgnored private var remoteSyncTask: Task<Void, Never>?

    private func diagnosticBookID(_ book: Book) -> String {
        DiagnosticLogSanitizer.identifier(for: book.stableId)
    }

    @ObservationIgnored private var absSessionSyncTimer: Timer?
    @ObservationIgnored private var lastPlaybackResumedAt: Date?
    @ObservationIgnored private var hardcoverSyncTimer: Timer?
    @ObservationIgnored private var lastHardcoverSyncProgress: Double = -1
    private var sleepTimerBaseVolume: Double?

    init(
        playbackComposition: PlaybackComposition = ActivePlayback.composition,
        storageService: StorageService = StorageService(),
        providerConnections: any ProviderConnectionAccessing,
        bookQuerying: any BookQuerying,
        readerArtifacts: any ReaderArtifactRepository,
        libraryCache: any PlayerLibraryCaching,
        streamResolver: PlayerStreamURLResolver = .shared,
        progressService: PlayerProgressService = .shared,
        sessionService: PlayerSessionService = .shared,
        chapterService: PlayerChapterService = .shared
    ) {
        self.playbackController = playbackComposition.controller
        self.bookStarter = playbackComposition.bookStarter
        self.restorationPreparer = playbackComposition.restorationPreparer
        self.audioProcessingController = playbackComposition.audioProcessing
        self.monoMixController = playbackComposition.monoMix
        self.stereoBalanceController = playbackComposition.stereoBalance
        self.conflictResolver = playbackComposition.conflictResolver
        self.storageService = storageService
        self.providerConnections = providerConnections
        self.bookQuerying = bookQuerying
        self.readerArtifacts = readerArtifacts
        self.libraryCache = libraryCache
        self.streamResolver = streamResolver
        let initialPrefs = LibraryDisplayPreferencesStore.shared.loadPreferences()
        let initialSnapshot = playbackComposition.controller.snapshot
        self.playbackSnapshot = initialSnapshot
        self.isPlayingSubject = CurrentValueSubject<Bool, Never>(initialSnapshot.isPlaying)
        self.progressSubject = CurrentValueSubject<TimeInterval, Never>(initialSnapshot.position)
        self.preferences = initialPrefs
        self.preferencesSubject = CurrentValueSubject<UserPreferences, Never>(initialPrefs)
        self.progressService = progressService
        self.bookmarkService = PlayerBookmarkService(storageService: storageService)
        self.chapterService = chapterService
        self.sessionService = sessionService

        setupObservers()
        setupServiceObservers()
        observePreferencesChanges()

        Task { [weak self] in
            guard let self else { return }
            await self.restoreLastPlayedForMiniPlayer()
        }

    }

    private func setupServiceObservers() {
        playbackController.snapshots
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                let previousBookId = self.playbackSnapshot.currentBook?.stableId
                self.playbackSnapshot = snapshot
                if let startedBookId = snapshot.currentBook?.stableId, startedBookId != previousBookId {
                    self.handlePlaybackBookChange()
                }
                self.isPlayingSubject.send(snapshot.isPlaying)
                self.progressSubject.send(snapshot.position)
                if snapshot.isLoading {
                    self.error = nil
                } else if let description = snapshot.errorDescription {
                    self.error = NSError(
                        domain: "PlaybackController",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: description]
                    )
                }
            }
            .store(in: &cancellables)

        conflictResolver?.conflicts
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.playbackConflict = $0 }
            .store(in: &cancellables)

        chapterService.$chapters
            .sink { [weak self] in self?.chapters = $0 }
            .store(in: &cancellables)
        chapterService.$currentChapter
            .sink { [weak self] in self?.currentChapter = $0 }
            .store(in: &cancellables)

        sleepTimerService.$sleepTimer
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                guard let self else { return }
                if self.sleepTimerChapterTargetPosition == nil {
                    self.sleepTimer = value
                }
            }
            .store(in: &cancellables)
        sleepTimerService.$remainingSeconds
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                guard let self else { return }
                if self.sleepTimerChapterTargetPosition == nil {
                    self.sleepTimerRemainingSeconds = value
                }
            }
            .store(in: &cancellables)
        sleepTimerService.$isFadingOut
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                guard let self else { return }
                if self.sleepTimerChapterTargetPosition == nil {
                    self.isFadingOut = value
                }
            }
            .store(in: &cancellables)

        #if os(iOS)
        ShakeDetectionService.shared.shakeDetected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self = self, self.sleepTimer != nil else { return }
                self.snoozeSleepTimer()
            }
            .store(in: &cancellables)
        #endif

    }

    func resolvePlaybackConflict(useServer: Bool) {
        conflictResolver?.resolveConflict(useServer: useServer)
    }

    func dismissPlaybackConflict() {
        conflictResolver?.dismissConflict()
    }

    private func setupObservers() {
        isPlayingSubject
            .removeDuplicates()
            .sink { [weak self] isPlaying in
                guard let self = self else { return }
                AppLogger.player.info("isPlaying changed to: \(isPlaying)")
                if isPlaying {
                    self.startProgressSync()
                    self.startABSSessionSyncTimer()
                    self.startHardcoverSyncTimer()
                    self.lastPlaybackResumedAt = Date()
                } else {
                    self.stopProgressSync()
                    self.accumulateTimeListenedSinceLastResume()
                    self.stopABSSessionSyncTimer()
                    self.stopHardcoverSyncTimer()
                }
            }
            .store(in: &cancellables)

        #if os(iOS)
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                AppLogger.player.info("App will resign active - saving progress")
                self?.saveProgress()
            }
            .store(in: &lifecycleObservers)

        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                AppLogger.player.info("App did enter background - saving progress")
                self?.saveProgress()
            }
            .store(in: &lifecycleObservers)

        NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)
            .sink { [weak self] _ in
                AppLogger.player.info("App will terminate - saving progress")
                self?.saveProgress()
            }
            .store(in: &lifecycleObservers)
        #endif

        progressSubject
            .throttle(for: .seconds(1.0), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] time in
                guard let self = self else { return }
                self.updateCurrentChapter(at: time)
                self.handleChapterSleepTick()
            }
            .store(in: &cancellables)

        progressSubject
            .debounce(for: .seconds(5), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.saveProgress()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: BookDownloadManager.downloadDidCompleteNotification)
            .sink { [weak self] notification in
                guard let self = self,
                    let bookId = notification.userInfo?["bookId"] as? String
                else { return }
                AppLogger.player.debug(
                    "Download completed; fetching chapters bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: bookId))"
                )
                Task { [weak self] in
                    await self?.fetchAndCacheChaptersAfterDownload(bookId: bookId)
                }
            }
            .store(in: &cancellables)
    }

    private func observePreferencesChanges() {
        NotificationCenter.default.publisher(for: .preferencesDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let updated = LibraryDisplayPreferencesStore.shared.loadPreferences()

                if self.preferences.playbackSpeed != updated.playbackSpeed {
                    self.playbackController.setPlaybackRate(updated.playbackSpeed)
                }
                if self.preferences.volume != updated.volume {
                    self.playbackController.setVolume(updated.volume)
                }
                if self.preferences.voiceBoostEnabled != updated.voiceBoostEnabled {
                    self.audioProcessingController.setVoiceBoostEnabled(updated.voiceBoostEnabled)
                }
                if self.preferences.voiceBoostPreset != updated.voiceBoostPreset {
                    self.audioProcessingController.setVoiceBoostPreset(updated.voiceBoostPreset)
                }

                self.preferences = updated
            }
            .store(in: &cancellables)

        #if os(iOS)
        Publishers.CombineLatest(
            isPlayingSubject.removeDuplicates(),
            preferencesSubject.map(\.disableAutoLockWhilePlaying).removeDuplicates()
        )
        .receive(on: RunLoop.main)
        .sink { isPlaying, disableAutoLockWhilePlaying in
            UIApplication.shared.isIdleTimerDisabled = isPlaying && disableAutoLockWhilePlaying
        }
        .store(in: &cancellables)
        #endif
    }

    private func handlePlaybackBookChange() {
        currentBookWasRestored = false
        restoredBook = nil
        restoredProgress = 0
        restoredDuration = 0
        lastHardcoverSyncProgress = -1
    }

    func togglePlay() {
        playbackController.togglePlay()
    }

    func play(book: Book) {
        bookStarter.play(book, presentPlayer: true)
    }

    func pause() {
        saveProgress()
        playbackController.pause()
        stopProgressSync()

        Task {
            await sessionService.syncABSSession(progress: progress, duration: duration, timeListened: sessionService.pendingTimeListened)
            sessionService.pendingTimeListened = 0
        }

        #if os(iOS)
        if let sessionId = sessionService.currentABSSessionId {
            ABSSessionBackgroundTask.shared.scheduleSessionClose(sessionId: sessionId)
        }
        #endif
    }

    func stop() {
        saveProgress()
        playbackController.stop()
        stopProgressSync()
        streamResolver.cleanupSecurityScopedAccess()

        #if os(iOS)
        ABSSessionBackgroundTask.shared.cancelScheduledClose()
        #endif

        Task {
            await sessionService.closeABSSession(progress: progress, duration: duration)
            progressService.absSessionActive = false
        }

        Task {
            await SMBStreamingServer.shared.stopStreaming()
        }
    }

    func seek(to time: TimeInterval) {
        playbackController.seek(to: time)
        saveProgress()
    }

    func resolveStreamURL(for book: Book, backendOverride: BackendConfig? = nil) async throws -> URL? {
        try await streamResolver.streamURL(for: book, backendOverride: backendOverride)
    }

    func skipForward() {
        playbackController.skipForward(seconds: preferences.skipForwardAmount)
    }

    func skipBackward() {
        playbackController.skipBackward(seconds: preferences.skipBackwardAmount)
    }

    func setPlaybackSpeed(_ speed: Double) {
        let clampedSpeed = min(max(speed, Double(AppConstants.Playback.minSpeed)), Double(AppConstants.Playback.maxSpeed))
        preferences.playbackSpeed = clampedSpeed
        playbackController.setPlaybackRate(clampedSpeed)
        LibraryDisplayPreferencesStore.shared.savePreferences(preferences)
    }

    func setVolume(_ volume: Double) {
        preferences.volume = volume
        playbackController.setVolume(volume)
        LibraryDisplayPreferencesStore.shared.savePreferences(preferences)
    }

    func setBasicVoiceMode(_ mode: BasicVoiceMode) {
        preferences.basicVoiceMode = mode
        audioProcessingController.setBasicVoiceMode(mode)
        LibraryDisplayPreferencesStore.shared.savePreferences(preferences)
    }

    func setVoiceBoostEnabled(_ enabled: Bool) {
        preferences.voiceBoostEnabled = enabled
        audioProcessingController.setVoiceBoostEnabled(enabled)
        LibraryDisplayPreferencesStore.shared.savePreferences(preferences)
    }

    func setVoiceBoostPreset(_ preset: VoiceBoostPreset) {
        preferences.voiceBoostPreset = preset
        audioProcessingController.setVoiceBoostPreset(preset)

        preferences.eqBands = audioProcessingController.eqBands

        LibraryDisplayPreferencesStore.shared.savePreferences(preferences)
    }

    func setEQEnabled(_ enabled: Bool) {
        preferences.eqEnabled = enabled
        audioProcessingController.setEQEnabled(enabled)
        LibraryDisplayPreferencesStore.shared.savePreferences(preferences)
    }

    func setEQBands(_ bands: [Float]) {
        preferences.eqBands = bands
        audioProcessingController.setEQBands(bands)
        LibraryDisplayPreferencesStore.shared.savePreferences(preferences)
    }

    func setIndependentPitchSemitones(_ semitones: Double) {
        preferences.independentPitchSemitones = semitones
        LibraryDisplayPreferencesStore.shared.savePreferences(preferences)
    }

    func setMonoMixEnabled(_ enabled: Bool) {
        preferences.monoMixEnabled = enabled
        monoMixController?.setMonoMixEnabled(enabled)
        LibraryDisplayPreferencesStore.shared.savePreferences(preferences)
    }

    func setStereoBalance(_ balance: Float) {
        preferences.stereoBalance = balance
        stereoBalanceController?.setStereoBalance(balance)
        LibraryDisplayPreferencesStore.shared.savePreferences(preferences)
    }

    func setNoiseReductionLevel(_ level: Float) {
        preferences.noiseReductionLevel = level
        LibraryDisplayPreferencesStore.shared.savePreferences(preferences)
    }

    func setBinauralEnabled(_ enabled: Bool) {
        preferences.binauralEnabled = enabled
        LibraryDisplayPreferencesStore.shared.savePreferences(preferences)
    }

    func nextChapter() {
        let time = progress
        guard let index = chapters.lastIndex(where: { time >= $0.start - 1.0 && time < $0.end }),
            index < chapters.count - 1
        else {
            return
        }
        seek(to: chapters[index + 1].start)
    }

    func previousChapter() {
        let time = progress
        guard let index = chapters.lastIndex(where: { time >= $0.start - 1.0 && time < $0.end }) else {
            return
        }

        if time - chapters[index].start > 3 {
            seek(to: chapters[index].start)
        } else if index > 0 {
            seek(to: chapters[index - 1].start)
        } else {
            seek(to: chapters[index].start)
        }
    }

    func seekToChapter(_ chapter: Chapter) {
        seek(to: chapter.start)
    }

    private func updateCurrentChapter(at time: TimeInterval) {
        currentChapter = chapters.last { chapter in
            time >= chapter.start - 1.0 && time < chapter.end
        }
    }

    private func absBackend(for book: Book) -> BackendConfig? {
        guard book.source == .audiobookshelf, let backendId = book.backendId else { return nil }
        return providerConnections.backend(id: backendId)
    }

    private var activeBook: Book? {
        playbackController.snapshot.currentBook ?? restoredBook
    }

    private var activePlaybackTime: TimeInterval {
        playbackController.snapshot.currentBook == nil ? restoredProgress : playbackController.snapshot.position
    }

    private func mergedBookmarks(for book: Book) -> [Bookmark] {
        var loaded = ReaderArtifactsStore.shared.loadBookmarks(bookId: book.stableId)
        if book.stableId != book.id {
            let legacy = ReaderArtifactsStore.shared.loadBookmarks(bookId: book.id)
            let existingIds = Set(loaded.map(\.id))
            loaded.append(contentsOf: legacy.filter { !existingIds.contains($0.id) })
        }
        return loaded.sorted { $0.position < $1.position }
    }

    private func activeChapter(at time: TimeInterval, book: Book?) -> Chapter? {
        let sourceChapters =
            if !chapters.isEmpty {
                chapters
            } else {
                book?.chapters ?? []
            }
        return sourceChapters.last { time >= $0.start - 1.0 && time < $0.end }
            ?? sourceChapters.last { time >= $0.start }
    }

    func refreshFromCurrentPlayback() {
        guard let book = activeBook else { return }

        if !bookmarks.contains(where: { $0.bookId == book.stableId || $0.bookId == book.id }) || bookmarks.isEmpty {
            bookmarks = mergedBookmarks(for: book)
        } else {
            let latest = mergedBookmarks(for: book)
            if latest != bookmarks {
                bookmarks = latest
            }
        }

        if let bookChapters = book.chapters, !bookChapters.isEmpty {
            chapters = bookChapters
            currentChapter = activeChapter(at: activePlaybackTime, book: book)
        }
    }

    private func syncBookOrbitBookmarks(book: Book) async {
        guard book.source == .bookOrbit,
            let provider = providerConnections.provider(for: book.providerId) as? BookOrbitProvider
        else { return }
        _ = await BookOrbitReaderArtifactSync.shared.sync(book: book, provider: provider)
        let merged = ReaderArtifactsStore.shared.loadBookmarks(bookId: book.stableId)
        await MainActor.run { bookmarks = merged }
    }

    @discardableResult
    func addBookmark(at position: TimeInterval? = nil, title: String? = nil, note: String? = nil) -> Bookmark? {
        guard let book = activeBook else { return nil }
        let bookmarkPosition = position ?? activePlaybackTime
        let chapter = activeChapter(at: bookmarkPosition, book: book)
        let newBookmark = bookmarkService.addBookmark(
            bookId: book.stableId,
            position: bookmarkPosition,
            locator: nil,
            title: title,
            note: note,
            mediaType: book.mediaType,
            chapterTitle: chapter?.title
        )
        bookmarks = (bookmarks + [newBookmark]).sorted { $0.position < $1.position }

        let capturedBookmark = newBookmark
        let stableId = book.stableId
        Task(priority: .utility) {
            await readerArtifacts.upsertBookmark(capturedBookmark, bookStableId: stableId)
        }

        ObsidianNotesCoordinator.shared.scheduleAutoExport(book: book)

        if let backend = absBackend(for: book) {
            Task {
                do {
                    let synced = try await AudiobookshelfService.shared.createBookmark(
                        libraryItemId: book.id,
                        time: newBookmark.position,
                        title: newBookmark.title,
                        backend: backend
                    )
                    let updated = Bookmark(
                        id: newBookmark.id,
                        bookId: newBookmark.bookId,
                        position: synced.time,
                        title: synced.title,
                        note: newBookmark.note,
                        timestamp: synced.createdAtDate ?? newBookmark.timestamp,
                        locator: nil,
                        mediaType: newBookmark.mediaType,
                        chapterTitle: newBookmark.chapterTitle
                    )
                    bookmarkService.updateBookmark(updated)
                    await MainActor.run {
                        if let idx = bookmarks.firstIndex(where: { $0.id == newBookmark.id }) {
                            bookmarks[idx] = updated
                        }
                    }
                } catch {
                    AppLogger.sync.warning(
                        "ABS bookmark push failed bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) at \(newBookmark.position): \(error.localizedDescription)"
                    )
                }
            }
        }
        if book.source == .bookOrbit {
            BookOrbitReaderArtifactSync.shared.enqueueBookmarkUpsert(book: book, localId: newBookmark.id)
            Task { await syncBookOrbitBookmarks(book: book) }
        }

        return newBookmark
    }

    func addBookmark(title: String? = nil, note: String? = nil) {
        _ = addBookmark(at: nil, title: title, note: note)
    }

    func removeBookmark(_ bookmark: Bookmark) {
        bookmarkService.deleteBookmark(bookmark)
        bookmarks.removeAll { $0.id == bookmark.id }
        #if !os(tvOS)
        AudiobookClipService.shared.deleteClip(bookId: bookmark.bookId, clipId: bookmark.id)
        #endif

        let bid = bookmark.id
        Task(priority: .utility) {
            await readerArtifacts.deleteBookmark(id: bid)
        }

        if let book = activeBook {
            ObsidianNotesCoordinator.shared.scheduleAutoExport(book: book)
        }

        if let book = activeBook, let backend = absBackend(for: book) {
            Task {
                do {
                    try await AudiobookshelfService.shared.deleteBookmark(
                        libraryItemId: book.id,
                        time: bookmark.position,
                        backend: backend
                    )
                } catch {
                    AppLogger.sync.warning(
                        "ABS bookmark delete failed bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) at \(bookmark.position): \(error.localizedDescription)"
                    )
                }
            }
        }
        if let book = activeBook, book.source == .bookOrbit, let remoteID = bookmark.remoteID {
            BookOrbitReaderArtifactSync.shared.enqueueBookmarkDelete(book: book, remoteId: remoteID)
            Task { await syncBookOrbitBookmarks(book: book) }
        }
    }

    func updateBookmark(_ bookmark: Bookmark, newTitle: String) {
        updateBookmark(bookmark, newTitle: newTitle, newNote: bookmark.note)
    }

    func updateBookmark(_ bookmark: Bookmark, newTitle: String, newNote: String?) {
        let updatedBookmark = Bookmark(
            id: bookmark.id,
            bookId: bookmark.bookId,
            position: bookmark.position,
            title: newTitle,
            note: newNote,
            timestamp: bookmark.timestamp,
            locator: bookmark.locator,
            mediaType: bookmark.mediaType,
            chapterTitle: bookmark.chapterTitle,
            remoteID: bookmark.remoteID,
            isRemotePlaceholder: bookmark.isRemotePlaceholder
        )
        bookmarkService.updateBookmark(updatedBookmark)
        if let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            bookmarks[index] = updatedBookmark
        }

        if let book = activeBook {
            ObsidianNotesCoordinator.shared.scheduleAutoExport(book: book)
        }

        if let book = activeBook, let backend = absBackend(for: book) {
            Task {
                do {
                    _ = try await AudiobookshelfService.shared.updateBookmark(
                        libraryItemId: book.id,
                        time: bookmark.position,
                        title: newTitle,
                        backend: backend
                    )
                } catch {
                    AppLogger.sync.warning(
                        "ABS bookmark update failed bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) at \(bookmark.position): \(error.localizedDescription)"
                    )
                }
            }
        }
        if let book = activeBook, book.source == .bookOrbit {
            BookOrbitReaderArtifactSync.shared.enqueueBookmarkUpsert(book: book, localId: updatedBookmark.id)
            Task { await syncBookOrbitBookmarks(book: book) }
        }
    }

    func seekToBookmark(_ bookmark: Bookmark) {
        if bookmark.mediaType == .ebook {
            NotificationCenter.default.post(name: NSNotification.Name("SeekToEbookBookmark"), object: bookmark)
        } else {
            seek(to: bookmark.position)
        }
    }

    func setSleepTimerToEndOfChapter(fadeOut: Bool = true) {
        guard let chapter = resolveCurrentChapterForSleepTimer() else {
            AppLogger.player.warning(
                "[SleepTimer] End-of-chapter requested but no current chapter resolved (hasCurrentChapter=\(self.currentChapter != nil), bookChapters=\(self.currentBook?.chapters?.count ?? 0))"
            )
            return
        }
        startChapterSleepTimer(targetPosition: chapter.end, fadeOut: fadeOut, label: "current")
    }

    func setSleepTimerToEndOfNextChapter(fadeOut: Bool = true) {
        guard let next = resolveNextChapterForSleepTimer() else {
            AppLogger.player.warning(
                "[SleepTimer] End-of-next-chapter requested but no next chapter resolved (vmChapters=\(self.chapters.count), bookChapters=\(self.currentBook?.chapters?.count ?? 0), progress=\(self.progress))"
            )
            return
        }
        startChapterSleepTimer(targetPosition: next.end, fadeOut: fadeOut, label: "next")
    }

    private func resolveCurrentChapterForSleepTimer() -> Chapter? {
        if let chapter = currentChapter { return chapter }
        return chapterList().last { progress >= $0.start }
    }

    private func resolveNextChapterForSleepTimer() -> Chapter? {
        let list = chapterList()
        guard !list.isEmpty else { return nil }
        if let current = currentChapter,
            let idx = list.firstIndex(where: { $0.id == current.id }),
            idx + 1 < list.count
        {
            return list[idx + 1]
        }
        if let idx = list.lastIndex(where: { progress >= $0.start }),
            idx + 1 < list.count
        {
            return list[idx + 1]
        }
        return list.first { $0.start > progress }
    }

    private func chapterList() -> [Chapter] {
        if !chapters.isEmpty { return chapters }
        return currentBook?.chapters ?? []
    }

    private func startChapterSleepTimer(targetPosition: TimeInterval, fadeOut: Bool, label: String) {
        sleepTimerService.stopTimer()
        cancelChapterSleepTimerTask()
        sleepTimerChapterTargetPosition = targetPosition
        sleepTimerChapterFadeOut = fadeOut
        resetSleepTimerFade()
        isFadingOut = false
        let wallClockSeconds = chapterTimerRemainingWallClockSeconds(target: targetPosition)
        sleepTimerRemainingSeconds = wallClockSeconds
        sleepTimer = Date().addingTimeInterval(wallClockSeconds)
        startChapterSleepTimerTask()
        AppLogger.player.info(
            "[SleepTimer] Starting end-of-\(label)-chapter timer: target=\(targetPosition)s, progress=\(self.progress)s, speed=\(self.playbackSpeed)x, wallClock=\(wallClockSeconds)s"
        )
    }

    private func chapterTimerRemainingWallClockSeconds(target: TimeInterval) -> TimeInterval {
        let speed = max(0.1, playbackSpeed)
        return max(0, (target - progress) / speed)
    }

    private func handleChapterSleepTick() {
        guard let target = sleepTimerChapterTargetPosition else { return }

        if progress >= target {
            sleepTimerChapterTargetPosition = nil
            cancelChapterSleepTimerTask()
            resetSleepTimerFade()
            isFadingOut = false
            sleepTimer = nil
            sleepTimerRemainingSeconds = 0
            recordSleepTimerFiredPosition()
            pause()
            return
        }

        let remaining = chapterTimerRemainingWallClockSeconds(target: target)
        sleepTimerRemainingSeconds = remaining
        sleepTimer = Date().addingTimeInterval(remaining)

        if sleepTimerChapterFadeOut {
            let fadeWindow = AppConstants.SleepTimer.fadeWindowSeconds
            if remaining <= fadeWindow {
                if !isFadingOut {
                    isFadingOut = true
                    AppLogger.player.info("[SleepTimer] Entering fade window (\(Int(fadeWindow))s)")
                }
                applySleepTimerFade(remainingSeconds: remaining)
            } else if isFadingOut {
                isFadingOut = false
                resetSleepTimerFade()
            }
        }
    }

    private func startChapterSleepTimerTask() {
        chapterSleepTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.handleChapterSleepTick()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func cancelChapterSleepTimerTask() {
        chapterSleepTimerTask?.cancel()
        chapterSleepTimerTask = nil
    }

    func startSleepTimer(minutes: Int, fadeOut: Bool = true) {
        sleepTimerChapterTargetPosition = nil
        cancelChapterSleepTimerTask()
        sleepTimerService.startTimer(minutes: minutes, fadeOut: fadeOut)

        var state =
            PlayerStateStore.shared.loadSleepTimer()
            ?? SleepTimerState(
                isActive: false,
                isPaused: false,
                endDate: nil,
                remainingSeconds: 0,
                lastDurationMinutes: 0,
                lastEndedByExpiry: true
            )
        state.timerStartedDate = Date()
        state.lastDurationMinutes = minutes
        PlayerStateStore.shared.saveSleepTimer(state)
    }

    func stopSleepTimer() {
        let wasChapter = sleepTimerChapterTargetPosition != nil
        sleepTimerChapterTargetPosition = nil
        cancelChapterSleepTimerTask()
        sleepTimerService.stopTimer()
        #if os(iOS)
        ShakeDetectionService.shared.stopMonitoring()
        #endif
        resetSleepTimerFade()
        if wasChapter {
            sleepTimer = nil
            sleepTimerRemainingSeconds = 0
            isFadingOut = false
        }
    }

    func snoozeSleepTimer() {
        sleepTimerChapterTargetPosition = nil
        cancelChapterSleepTimerTask()
        resetSleepTimerFade()
        isFadingOut = false
        sleepTimerService.snooze()
    }

    private func applySleepTimerFade(remainingSeconds: TimeInterval) {
        let fadeWindow = AppConstants.SleepTimer.fadeWindowSeconds
        let clampedRemaining = max(0, min(fadeWindow, remainingSeconds))
        let normalized = clampedRemaining / fadeWindow
        let minScale = AppConstants.SleepTimer.fadeMinScale
        let curve = pow(normalized, AppConstants.SleepTimer.fadeCurveExponent)
        let scale = minScale + (1.0 - minScale) * curve

        if Int(clampedRemaining) % 5 == 0 {
            let formattedScale = String(format: "%.2f", scale)
            AppLogger.player.info("\u{1F319} [SleepTimer] Pre-fade active: \(Int(clampedRemaining))s left, scale=\(formattedScale)")
        }

        if sleepTimerBaseVolume == nil {
            sleepTimerBaseVolume = playbackController.snapshot.volume
        }

        if let baseVolume = sleepTimerBaseVolume {
            playbackController.setVolume(baseVolume * scale)
        }
    }

    private func resetSleepTimerFade() {
        if let baseVolume = sleepTimerBaseVolume {
            playbackController.setVolume(baseVolume)
        }
        if sleepTimerBaseVolume != nil {
            AppLogger.player.info("\u{1F319} [SleepTimer] Pre-fade reset to baseline volume")
        }
        sleepTimerBaseVolume = nil
    }

    private func recordSleepTimerFiredPosition() {
        guard let book = currentBook else { return }
        var state =
            PlayerStateStore.shared.loadSleepTimer()
            ?? SleepTimerState(
                isActive: false,
                isPaused: false,
                endDate: nil,
                remainingSeconds: 0,
                lastDurationMinutes: 0,
                lastEndedByExpiry: true
            )
        state.timerFiredDate = Date()
        state.timerFiredPosition = progress
        state.timerFiredBookId = book.id
        state.lastEndedByExpiry = true

        PlayerStateStore.shared.saveSleepTimer(state)
        AppLogger.player.info(
            "[SleepTimer] Recorded fire: pos=\(String(format: "%.0f", progress))s, started=\(state.timerStartedDate?.description ?? "nil")"
        )
    }

    private var activePlaybackOwnsProgressPersistence: Bool {
        guard playbackController.ownsProgressPersistence else { return false }
        guard let book = currentBook,
            let managedBook = playbackController.snapshot.currentBook
        else {
            return false
        }
        return playbackController.snapshot.isLoaded && managedBook.stableId == book.stableId
    }

    private func startProgressSync() {
        guard !activePlaybackOwnsProgressPersistence else { return }
        guard preferences.autoSyncProgress,
            SyncCoordinator.shared.syncEnabled
        else {
            return
        }

        guard sessionService.currentABSSessionId == nil else { return }
        progressService.startProgressSync(currentBook: currentBook, isPlaying: isPlaying) { [weak self] in self?.progress ?? 0 }
    }

    private func stopProgressSync() {
        guard !activePlaybackOwnsProgressPersistence else { return }
        progressService.stopProgressSync()
    }

    private func accumulateTimeListenedSinceLastResume() {
        guard let resumed = lastPlaybackResumedAt else { return }
        let elapsed = Date().timeIntervalSince(resumed)
        sessionService.pendingTimeListened += elapsed
        lastPlaybackResumedAt = nil
    }

    private func startABSSessionSyncTimer() {
        absSessionSyncTimer?.invalidate()
        guard sessionService.currentABSSessionId != nil else { return }

        absSessionSyncTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.accumulateTimeListenedSinceLastResume()
                self.lastPlaybackResumedAt = Date()
                let pending = self.sessionService.pendingTimeListened
                let currentProgress = self.progress
                let currentDuration = self.duration
                await self.sessionService.syncABSSession(
                    progress: currentProgress,
                    duration: currentDuration,
                    timeListened: pending
                )
                self.sessionService.pendingTimeListened = 0
            }
        }
    }

    private func stopABSSessionSyncTimer() {
        absSessionSyncTimer?.invalidate()
        absSessionSyncTimer = nil
    }

    private func startHardcoverSyncTimer() {
        hardcoverSyncTimer?.invalidate()
        guard SettingsManager.shared.hardcoverAutoSyncEnabled,
            SettingsManager.shared.hardcoverApiKey != nil
        else { return }

        hardcoverSyncTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.syncHardcoverProgress()
            }
        }
    }

    private func stopHardcoverSyncTimer() {
        hardcoverSyncTimer?.invalidate()
        hardcoverSyncTimer = nil
        Task { await syncHardcoverProgress() }
    }

    private func syncHardcoverProgress() async {
        guard let book = currentBook, duration > 0, progress > 0 else { return }
        let fraction = progress / duration
        guard abs(fraction - lastHardcoverSyncProgress) > 0.005 else { return }
        lastHardcoverSyncProgress = fraction
        await SyncCoordinator.shared.pushHardcoverIfNeeded(book: book, progress: fraction, sessionService: sessionService)
    }

    private func syncProgress() {
        guard !activePlaybackOwnsProgressPersistence else { return }
        guard let book = currentBook, preferences.autoSyncProgress else { return }
        Task {
            await progressService.syncProgressToRemote(book: book, progress: progress)
        }
    }

    private func syncProgressToRemote(book: Book, progress: TimeInterval) async {
        await progressService.syncProgressToRemote(book: book, progress: progress)
    }

    private func saveProgress() {
        guard !activePlaybackOwnsProgressPersistence else { return }
        guard let book = currentBook, progress > 0, duration > 0 else { return }

        progressService.saveProgress(book: book, position: progress, duration: duration)
        BookProgressStore.shared.saveRecentlyPlayed(book)

        if preferences.autoSyncProgress, SyncCoordinator.shared.syncEnabled {
            remoteSyncTask?.cancel()
            remoteSyncTask = Task {
                await progressService.syncProgressToRemote(book: book, progress: progress)
            }
        }

        let now = Date()
        let isFinishing = book.duration.map { progress >= $0 * 0.99 } ?? false
        let shouldPublish = now.timeIntervalSince(lastAllBooksPublishTime) >= AppConstants.Sync.progressSyncInterval || isFinishing

        if shouldPublish, libraryCache.indexInMemory(stableId: book.stableId) != nil {
            lastAllBooksPublishTime = now
            libraryCache.mutateBook(stableId: book.stableId) {
                $0.currentTime = progress
                if isFinishing { $0.isFinished = true }
            }
        }

        let currentPercent = progress / duration
        Task {
            await SyncCoordinator.shared.pushHardcoverIfNeeded(book: book, progress: currentPercent, sessionService: sessionService)
        }
    }

    private func fetchAndCacheChaptersAfterDownload(bookId: String) async {
        await chapterService.fetchAndCacheChaptersAfterDownload(bookId: bookId)
    }

    func saveProgressOnBackground() async {
        saveProgress()
    }

    func closeABSSessionFromBackground() async {
        guard sessionService.currentABSSessionId != nil else { return }
        await sessionService.closeABSSession(progress: progress, duration: duration)
        progressService.absSessionActive = false
        AppLogger.player.info("ABS session closed from background task")
    }

    func download(book: Book) async {
        AppLogger.player.debug("Download requested for bookDiagnosticID=\(diagnosticBookID(book))")

        if book.source == .plex || book.source == .audiobookshelf {
            let hasInternet = await checkNetworkConnectivity()
            AppLogger.player.info("Internet connectivity check: \(hasInternet)")

            if !hasInternet {
                await MainActor.run {
                    self.error = NSError(
                        domain: "PlayerViewModel",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No internet connection available"]
                    )
                }
                return
            }
        }

        await downloadImpl(book: book)
    }

    private func checkNetworkConnectivity() async -> Bool {
        guard let url = URL(string: "https://captive.apple.com/hotspot-detect.html") else {
            return true
        }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 3

        do {
            let (_, _) = try await URLSession.shared.data(for: request)
            return true
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                switch nsError.code {
                case NSURLErrorNotConnectedToInternet,
                    NSURLErrorNetworkConnectionLost,
                    NSURLErrorCannotFindHost,
                    NSURLErrorCannotConnectToHost:
                    return false
                default:
                    return true
                }
            }
            return true
        }
    }

    private func downloadImpl(book: Book) async {
        AppLogger.player.debug("Download started for bookDiagnosticID=\(diagnosticBookID(book))")

        let downloadId = book.downloadKey

        if LocalStorageManager.shared.isAudiobookDownloaded(downloadId) {
            AppLogger.player.debug("Book already downloaded; bookDiagnosticID=\(diagnosticBookID(book))")
            return
        }

        await UnifiedDownloadService.shared.download(book: book)
    }

    func removeDownload(book: Book) async {
        await UnifiedDownloadService.shared.deleteDownload(book: book)
    }

    func markAsFinished(book: Book) async {
        do {
            guard let dur = book.duration, dur > 0 else {
                throw NSError(domain: "PlayerViewModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing duration for this book"])
            }

            BookProgressStore.shared.saveProgress(for: book, progress: dur, duration: dur)
            BookProgressStore.shared.saveRecentlyPlayed(book)

            await ListeningStatsTracker.shared.markBookAsFinished(bookId: book.stableId)

            Task {
                await HardcoverSyncService.shared.syncBookFinished(book: book)

                if LibraryDisplayPreferencesStore.shared.loadPreferences().autoDeleteFinishedBooks {
                    AppLogger.player.debug("Auto-deleting finished bookDiagnosticID=\(diagnosticBookID(book))")
                    await UnifiedDownloadService.shared.deleteDownload(book: book)
                }
            }

            await MainActor.run {
                if self.currentBook?.id == book.id {
                    self.playbackController.seek(to: dur)
                }
            }

            var finishedBook = book
            finishedBook.currentTime = dur
            finishedBook.isFinished = true
            finishedBook.lastUpdate = Date()
            await SyncCoordinator.shared.pushFinished(book: finishedBook, domain: .audiobook)
        } catch {
            await MainActor.run {
                self.error = error
            }
        }
    }

    private func restoreLastPlayedForMiniPlayer() async {
        guard let lastId = PlayerStateStore.shared.loadLastPlayedBookId(), !lastId.isEmpty else { return }

        var match = await bookQuerying.book(byAnyId: lastId)
        if match == nil {
            let recentBooks = BookProgressStore.shared.loadRecentlyPlayed()
            match = recentBooks.first(where: { $0.stableId == lastId || $0.id == lastId })
        }

        guard let match else { return }

        var resumeProgress: TimeInterval?
        var resumeDuration: TimeInterval?

        if let savedProgress = BookProgressStore.shared.loadProgress(for: match) {
            resumeProgress = savedProgress.progress
            resumeDuration = savedProgress.duration
        }

        await MainActor.run {
            self.restoredBook = match
            self.currentBookWasRestored = true
            if let resumeProgress {
                self.restoredProgress = resumeProgress
            }
            if let resumeDuration {
                self.restoredDuration = resumeDuration
            }
        }

        restorationPreparer?.prewarmRestoredBook(match, resumeAt: resumeProgress)
    }

}
