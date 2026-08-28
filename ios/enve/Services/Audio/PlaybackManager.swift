import AVFoundation
import Combine
import Foundation
import Logging
import MediaPlayer
import SwiftUI
import Zip

enum GrimmoryOpenDecision: Equatable {
    case noServerData

    case adoptServer(resume: TimeInterval)

    case keepLocal(resume: TimeInterval, push: Bool)

    case conflict(local: TimeInterval, server: TimeInterval)
}

struct AudiobookNowPlayingMetadata: Equatable {
    let chapterTitle: String?
    let chapterNumber: Int?
    let chapterCount: Int?
    let elapsed: TimeInterval
    let duration: TimeInterval
}

func resolveAudiobookNowPlayingMetadata(
    book: Book,
    currentTime: TimeInterval,
    playbackDuration: TimeInterval
) -> AudiobookNowPlayingMetadata {
    let globalDuration = playbackDuration > 0 ? playbackDuration : max(0, book.duration ?? 0)
    let globalElapsed = globalDuration > 0
        ? min(max(0, currentTime), globalDuration)
        : max(0, currentTime)
    let chapters = book.chapters?.sorted(by: { $0.start < $1.start }) ?? []
    let chapterIndex =
        chapters.firstIndex { globalElapsed >= $0.start && globalElapsed < $0.end }
        ?? chapters.lastIndex { globalElapsed >= $0.start }

    return AudiobookNowPlayingMetadata(
        chapterTitle: chapterIndex.map { chapters[$0].title },
        chapterNumber: chapterIndex.map { $0 + 1 },
        chapterCount: chapterIndex == nil ? nil : chapters.count,
        elapsed: globalElapsed,
        duration: globalDuration
    )
}

func resolvePlaybackResumeTime(
    requestedTime: TimeInterval,
    sessionTime: TimeInterval?,
    duration: TimeInterval,
    tolerance: TimeInterval = 5
) -> TimeInterval {
    let requested = max(0, requestedTime)
    let session = max(0, sessionTime ?? 0)
    let candidate = requested > tolerance ? requested : max(requested, session)

    if duration > 0, candidate > duration + tolerance {
        return 0
    }
    return candidate
}

func decideGrimmoryOpen(
    localTime: TimeInterval,
    serverTime: TimeInterval,
    serverStamp: Date?,
    anchor: Date?,
    isFinished: Bool,
    tolerance: TimeInterval = 5
) -> GrimmoryOpenDecision {
    guard let serverStamp, serverTime > 0 else { return .noServerData }

    let serverChanged = anchor == nil || serverStamp > anchor!.addingTimeInterval(0.5)
    if !serverChanged {
        return .keepLocal(resume: max(localTime, serverTime), push: localTime > serverTime + tolerance)
    }
    if serverTime >= localTime - tolerance {
        return .adoptServer(resume: serverTime)
    }
    if isFinished {
        return .keepLocal(resume: localTime, push: false)
    }

    return .conflict(local: localTime, server: serverTime)
}

enum PlaybackError: LocalizedError {
    case invalidURL
    case noProvider
    case assetNotPlayable
    case mediaLoadTimeout
    case playerItemFailed(underlying: Error?)
    case noAudioSource
    case emptyPlaybackSession(bookTitle: String)
    case smbStreamFailed
    case downloadedFileEmpty(path: String)
    case trackIndexOutOfRange(index: Int, count: Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid audio URL"
        case .noProvider:
            return "No provider set for current book"
        case .assetNotPlayable:
            return "Asset is not playable"
        case .mediaLoadTimeout:
            return "Timeout waiting for media to load"
        case .playerItemFailed(let underlying):
            if let nsError = underlying as NSError? {
                if nsError.domain == NSURLErrorDomain {
                    let code = URLError.Code(rawValue: nsError.code)
                    switch code {
                    case .secureConnectionFailed,
                        .serverCertificateUntrusted,
                        .serverCertificateHasBadDate,
                        .serverCertificateNotYetValid:
                        return "Secure connection to the audio stream failed. The server certificate was rejected."
                    default:
                        break
                    }
                }
            }
            return underlying?.localizedDescription ?? "Player item failed to load"
        case .noAudioSource:
            return "No audio source found for book"
        case .emptyPlaybackSession(let bookTitle):
            return "No playable audio tracks were returned for \"\(bookTitle)\""
        case .smbStreamFailed:
            return "Failed to start SMB stream"
        case .downloadedFileEmpty(let path):
            return "Downloaded file is empty or corrupt at: \(path)"
        case .trackIndexOutOfRange(let index, let count):
            return "Track index \(index) out of range (total: \(count))"
        }
    }
}

@MainActor
@Observable
final class PlaybackManager {
    static let shared = PlaybackManager()

    private let audioProcessor = AudioProcessor.shared
    private let bookSession: any CurrentBookSession
    private let libraryCache: LibraryBookCache
    private let connectionStore: ProviderConnectionStore
    private let bookRepository: BookStoreRepository

    var isPlaying = false {
        didSet {
            isPlayingSubject.send(isPlaying)
            updateNowPlayingInfo()
            stateDidChangeSubject.send(())
        }
    }
    var currentTime: TimeInterval = 0 {
        didSet {
            currentTimeSubject.send(currentTime)
            updateNowPlayingInfo()
            stateDidChangeSubject.send(())
        }
    }
    var duration: TimeInterval = 0 {
        didSet {
            durationSubject.send(duration)
            updateNowPlayingInfo()
            stateDidChangeSubject.send(())
        }
    }
    var isLoading = false {
        didSet { stateDidChangeSubject.send(()) }
    }
    var playbackError: String? {
        didSet {
            if let playbackError, playbackError != oldValue {
                playbackErrorSubject.send(playbackError)
            }
            stateDidChangeSubject.send(())
        }
    }
    var currentBook: Book? {
        didSet {
            currentBookSubject.send(currentBook)
            updateNowPlayingInfo()
            stateDidChangeSubject.send(())
        }
    }
    var playbackSpeed: Float = AppConstants.Playback.defaultSpeed {
        didSet {
            playbackSpeedSubject.send(playbackSpeed)
            guard playbackSpeed != oldValue else { return }
            applyPlaybackSpeed()
            stateDidChangeSubject.send(())
        }
    }
    private var currentItemIsPodcast: Bool {
        currentBook?.isPodcastEpisode == true
    }
    private(set) var skipForwardInterval: TimeInterval = AppConstants.Playback.defaultSkipForward
    private(set) var skipBackwardInterval: TimeInterval = AppConstants.Playback.defaultSkipBackward

    private var currentSessionId: String? {
        didSet { stateDidChangeSubject.send(()) }
    }
    var isOverlayPlaybackActive: Bool {
        currentSessionId?.hasPrefix("overlay-") == true
    }
    private var currentProvider: (any PlaybackSessionProvider)?
    private var playbackEndObserver: NSObjectProtocol?
    private var playbackFailureObserver: NSObjectProtocol?
    private var playbackStalledObserver: NSObjectProtocol?
    private var playbackRecoveryTask: Task<Void, Never>?
    private var playbackRecoveryAttempts = 0
    private var playbackRecoveryBaseline: TimeInterval = 0
    private let maxPlaybackRecoveryAttempts = 2
    private var syncTimer: Timer?
    private var timeListenedSinceLastSync: TimeInterval = 0
    private var hasClearedNowPlayingWhenIdle = false
    private var nowPlayingUpdateTask: Task<Void, Never>?
    private var shouldResumeAfterInterruption = false
    private let verbosePlaybackLogs = false
    private var lastStatsTickAt: Date = .distantPast
    private let activeStatsTickInterval: TimeInterval = 5.0
    private let backgroundStatsTickInterval: TimeInterval = 20.0
    private let activeProgressSyncInterval: TimeInterval = 30.0
    private let backgroundProgressSyncInterval: TimeInterval = 120.0
    private let localProgressMinDelta: TimeInterval = 10.0
    private let localProgressMinInterval: TimeInterval = 20.0
    private var lastLocalPersistedTime: TimeInterval = -1
    private var lastLocalPersistedAt: Date = .distantPast
    private var lastLocalPersistedFinished: Bool?
    private var suspendNonEssentialBackgroundWork = false
    private var lastBackgroundTimePublishAt: Date = .distantPast
    private let backgroundTimePublishInterval: TimeInterval = 5.0

    private var currentTracks: [AudioTrackInfo] = []
    private var currentTrackIndex: Int = 0
    private var currentTrackStartOffset: TimeInterval = 0

    var syncConflict: (local: TimeInterval, server: TimeInterval, bookId: String)? {
        didSet {
            syncConflictSubject.send(syncConflict)
            if syncConflict == nil { pendingGrimmoryServerStamp = nil }
        }
    }

    private var pendingGrimmoryServerStamp: Date?

    private var isSeeking = false
    private var player: AVPlayer? {
        didSet { stateDidChangeSubject.send(()) }
    }
    #if os(iOS)
    private var nowPlayingSession: MPNowPlayingSession?
    #endif
    private var timeObserver: Any?

    var hasActivePlayer: Bool { player != nil }

    @ObservationIgnored let isPlayingSubject = CurrentValueSubject<Bool, Never>(false)
    @ObservationIgnored let currentTimeSubject = CurrentValueSubject<TimeInterval, Never>(0)
    @ObservationIgnored let durationSubject = CurrentValueSubject<TimeInterval, Never>(0)
    @ObservationIgnored let currentBookSubject = CurrentValueSubject<Book?, Never>(nil)
    @ObservationIgnored let playbackSpeedSubject = CurrentValueSubject<Float, Never>(1.0)
    @ObservationIgnored let stateDidChangeSubject = PassthroughSubject<Void, Never>()
    @ObservationIgnored let syncConflictSubject = CurrentValueSubject<(local: TimeInterval, server: TimeInterval, bookId: String)?, Never>(
        nil
    )
    @ObservationIgnored let playbackErrorSubject = PassthroughSubject<String, Never>()
    @ObservationIgnored let playbackCompletionSubject = PassthroughSubject<Book, Never>()

    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    private let storageService = StorageService.shared

    private func debugLog(_ message: String) {
        guard verbosePlaybackLogs else { return }
        AppLogger.player.debug("\(message)")
    }

    private func diagnosticBookID(_ book: Book) -> String {
        DiagnosticLogSanitizer.identifier(for: book.stableId)
    }

    private func logStreamingFailureContext(
        _ error: Error,
        track: AudioTrackInfo,
        url: URL,
        playerItem: AVPlayerItem? = nil,
        phase: String
    ) {
        let nsError = error as NSError
        let providerType = currentProvider?.connection.type.rawValue ?? "none"
        let headerKeys = currentProvider?.getStreamingHeaders().keys.sorted().joined(separator: ", ") ?? "none"
        let customHeaderKeys = currentProvider?.connection.customHeaders?.keys.sorted().joined(separator: ", ") ?? "none"

        AppLogger.player.error("Stream failure during \(phase)")
        let bookID = currentBook.map(diagnosticBookID) ?? "none"
        let sessionID = currentSessionId.map(DiagnosticLogSanitizer.identifier) ?? "none"
        AppLogger.player.debug(
            "bookDiagnosticID=\(bookID) source=\(currentBook?.source.rawValue ?? "unknown") provider=\(providerType)"
        )
        AppLogger.player.debug("sessionDiagnosticID=\(sessionID) trackIndex=\(track.index) startOffset=\(track.startOffset)")
        AppLogger.player.debug("streamURL=\(url.redacted)")
        AppLogger.player.debug("authHeaders=\(headerKeys) customHeaders=\(customHeaderKeys)")
        AppLogger.player.error("errorDomain=\(nsError.domain) errorCode=\(nsError.code) error=\(nsError.localizedDescription)")

        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            AppLogger.player.error("urlError=\(code.rawValue) \(code)")
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            AppLogger.player.debug(
                "underlyingDomain=\(underlying.domain) underlyingCode=\(underlying.code) underlying=\(underlying.localizedDescription)"
            )
        }

        if let playerItem {
            if let itemError = playerItem.error as NSError? {
                AppLogger.player.error(
                    "playerItemErrorDomain=\(itemError.domain) playerItemErrorCode=\(itemError.code) playerItemError=\(itemError.localizedDescription)"
                )
            }

            if let log = playerItem.errorLog(), let lastEvent = log.events.last {
                AppLogger.player.error("errorLogHasServer=\(lastEvent.serverAddress != nil)")
                AppLogger.player.error("errorLogStatus=\(lastEvent.errorStatusCode) comment=\(lastEvent.errorComment ?? "none")")
            }

            if let accessLog = playerItem.accessLog(), let lastEvent = accessLog.events.last {
                AppLogger.player.debug("accessLogHasServer=\(lastEvent.serverAddress != nil)")
                AppLogger.player.debug(
                    "accessLogPlaybackStartOffset=\(lastEvent.playbackStartOffset) observedBitrate=\(lastEvent.observedBitrate)"
                )
            }
        }
    }

    private func normalizedTracks(_ tracks: [AudioTrackInfo]) -> [AudioTrackInfo] {
        tracks.sorted {
            if $0.startOffset == $1.startOffset {
                return $0.index < $1.index
            }
            return $0.startOffset < $1.startOffset
        }
    }

    private func normalizeChaptersIfNeeded(totalDuration: TimeInterval) {
        guard totalDuration > 0,
            var updatedBook = currentBook,
            let chapters = updatedBook.chapters,
            !chapters.isEmpty
        else {
            return
        }

        let normalized: [Chapter]
        let hasAnyPositiveStart = chapters.contains { $0.start > 0 }

        if !hasAnyPositiveStart && chapters.count > 1 {
            let estimatedChapterDuration = totalDuration / Double(chapters.count)
            normalized = chapters.enumerated().map { index, chapter in
                let start = estimatedChapterDuration * Double(index)
                let end =
                    index == chapters.count - 1
                    ? totalDuration
                    : estimatedChapterDuration * Double(index + 1)
                return Chapter(
                    id: chapter.id,
                    start: start,
                    end: end,
                    title: chapter.title,
                    index: chapter.index == 0 ? index : chapter.index
                )
            }
        } else {
            var rebuilt: [Chapter] = []
            rebuilt.reserveCapacity(chapters.count)

            for index in chapters.indices {
                let chapter = chapters[index]
                let previousEnd = rebuilt.last?.end ?? 0
                let start = max(chapter.start, previousEnd)
                let nextStart = chapters[(index + 1)...].map(\.start).first(where: { $0 > start }) ?? totalDuration
                let end = max(chapter.end > start ? chapter.end : nextStart, start)
                rebuilt.append(
                    Chapter(
                        id: chapter.id,
                        start: start,
                        end: min(end, totalDuration),
                        title: chapter.title,
                        index: chapter.index
                    )
                )
            }

            normalized = rebuilt
        }

        guard normalized != chapters else { return }

        AppLogger.player.info("Normalized \(normalized.count) chapter timings using player duration \(Int(totalDuration))s")
        updatedBook.chapters = normalized
        currentBook = updatedBook
        self.bookSession.currentBook = updatedBook
        self.libraryCache.mutateBook(uniqueId: updatedBook.uniqueId) { $0.chapters = normalized }
        ReaderArtifactsStore.shared.saveCachedChapters(bookId: updatedBook.stableId, chapters: normalized)
        if updatedBook.id != updatedBook.stableId {
            ReaderArtifactsStore.shared.saveCachedChapters(bookId: updatedBook.id, chapters: normalized)
        }
    }

    private func persistRecentPlaybackSnapshot() {
        guard var book = currentBook else { return }
        book.currentTime = currentTime
        if duration > 0 {
            book.duration = duration
        }
        book.lastUpdate = Date()
        BookProgressStore.shared.saveRecentlyPlayed(book)
        let snapshot = book
        Task(priority: .utility) { await self.bookRepository.upsertBooks([snapshot]) }
        NotificationCenter.default.post(name: .continueListeningNeedsRefresh, object: nil)
    }

    private init(
        bookSession: any CurrentBookSession = AppState.shared,
        libraryCache: LibraryBookCache = AppState.shared.libraryCache,
        connectionStore: ProviderConnectionStore = AppState.shared.providerConnections,
        bookRepository: BookStoreRepository = AppState.shared.bookStore
    ) {
        self.bookSession = bookSession
        self.libraryCache = libraryCache
        self.connectionStore = connectionStore
        self.bookRepository = bookRepository
        setupAudioSession(activate: false)
        setupObservers()
        registerEnvePlaybackHandoff()
        loadPlaybackPreferences()
    }

    private func registerEnvePlaybackHandoff() {
        #if os(iOS)
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, _, _, _, _ in
                Task { @MainActor in PlaybackManager.shared.pauseForMusicPlayback() }
            },
            "com.enve.music.playback.started" as CFString,
            nil,
            .deliverImmediately
        )
        #endif
    }

    private func announcePlaybackOwnership() {
        #if os(iOS)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.enve.book.playback.started" as CFString),
            nil,
            nil,
            true
        )
        #endif
    }

    private func pauseForMusicPlayback() {
        guard isPlaying else { return }
        pause(userInitiated: false)
    }

    private func loadPlaybackPreferences() {
        let preferences = LibraryDisplayPreferencesStore.shared.loadPreferences()
        let requestedSpeed: Double
        if currentItemIsPodcast {
            let fallback = UserDefaults.standard.float(forKey: "podcastPlaybackSpeed")
            requestedSpeed = fallback > 0 ? Double(fallback) : preferences.podcastPlaybackSpeed
        } else {
            let fallbackSpeed = UserDefaults.standard.float(forKey: "playbackSpeed")
            let global =
                preferences.playbackSpeed != UserPreferences.default.playbackSpeed
                ? preferences.playbackSpeed
                : (fallbackSpeed > 0 ? Double(fallbackSpeed) : Double(UserPreferences.default.playbackSpeed))
            let perBook = currentBook.flatMap { PlaybackSpeedMemory.shared.speed(forStableId: $0.stableId) }
            requestedSpeed = perBook ?? global
        }

        let clampedSpeed = clampedPlaybackSpeed(Float(requestedSpeed))
        if playbackSpeed != clampedSpeed {
            playbackSpeed = clampedSpeed
        }
        skipForwardInterval = max(1, preferences.skipForwardAmount)
        skipBackwardInterval = max(1, preferences.skipBackwardAmount)
        updateRemoteSkipIntervals()
        updateNowPlayingInfo()
    }

    func switchSpeedForCurrentBook() {
        let prefs = LibraryDisplayPreferencesStore.shared.loadPreferences()
        let target: Float
        if currentItemIsPodcast {
            let fallback = UserDefaults.standard.float(forKey: "podcastPlaybackSpeed")
            target = clampedPlaybackSpeed(
                Float(
                    fallback > 0 ? Double(fallback) : prefs.podcastPlaybackSpeed
                )
            )
        } else {
            let fallback = UserDefaults.standard.float(forKey: "playbackSpeed")
            let global =
                prefs.playbackSpeed != UserPreferences.default.playbackSpeed
                ? prefs.playbackSpeed
                : (fallback > 0 ? Double(fallback) : Double(UserPreferences.default.playbackSpeed))
            let perBook = currentBook.flatMap { PlaybackSpeedMemory.shared.speed(forStableId: $0.stableId) }
            target = clampedPlaybackSpeed(Float(perBook ?? global))
        }
        if playbackSpeed != target {
            playbackSpeed = target
        }
    }

    private func clampedPlaybackSpeed(_ speed: Float) -> Float {
        max(AppConstants.Playback.minSpeed, min(speed, AppConstants.Playback.maxSpeed))
    }

    private func applyPlaybackSpeed() {
        player?.rate = isPlaying ? playbackSpeed : 0
        if currentItemIsPodcast {
            let existing = UserDefaults.standard.float(forKey: "podcastPlaybackSpeed")
            if existing != playbackSpeed {
                UserDefaults.standard.set(playbackSpeed, forKey: "podcastPlaybackSpeed")
            }
            var prefs = LibraryDisplayPreferencesStore.shared.loadPreferences()
            let target = Double(playbackSpeed)
            if prefs.podcastPlaybackSpeed != target {
                prefs.podcastPlaybackSpeed = target
                LibraryDisplayPreferencesStore.shared.savePreferences(prefs)
            }
        } else {
            let existing = UserDefaults.standard.float(forKey: "playbackSpeed")
            if existing != playbackSpeed {
                UserDefaults.standard.set(playbackSpeed, forKey: "playbackSpeed")
            }
            var prefs = LibraryDisplayPreferencesStore.shared.loadPreferences()
            let target = Double(playbackSpeed)
            if prefs.playbackSpeed != target {
                prefs.playbackSpeed = target
                LibraryDisplayPreferencesStore.shared.savePreferences(prefs)
            }
        }
        updateNowPlayingInfo()
    }

    private func setupAudioSession(activate: Bool = true) {
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        do {
            let voiceMode = LibraryDisplayPreferencesStore.shared.loadPreferences().basicVoiceMode.audioSessionMode
            let policy: AVAudioSession.RouteSharingPolicy = voiceMode == .voicePrompt ? .default : .longFormAudio
            let options: AVAudioSession.CategoryOptions = policy == .default ? [.allowAirPlay, .allowBluetoothA2DP] : []
            try audioSession.setCategory(.playback, mode: voiceMode, policy: policy, options: options)
            if activate {
                activateAudioSession()
            }
        } catch {
            AppLogger.player.error("Failed to setup audio session: \(error)")
        }
        #endif
        NowPlayingCoordinator.shared.setActive(self)
    }

    private nonisolated func activateAudioSession() {
        #if os(iOS)
        Task.detached(priority: .userInitiated) {
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                AppLogger.player.error("Failed to activate audio session: \(error)")
            }
        }
        #endif
    }

    private func updateNowPlayingInfo() {
        guard let book = currentBook else {
            if hasClearedNowPlayingWhenIdle { return }
            NowPlayingCoordinator.shared.clearNowPlaying(if: self)
            hasClearedNowPlayingWhenIdle = true
            return
        }
        hasClearedNowPlayingWhenIdle = false

        let metadata = resolveAudiobookNowPlayingMetadata(
            book: book,
            currentTime: currentTime,
            playbackDuration: duration
        )
        let info = NowPlayingInfo(
            title: book.title,
            artist: metadata.chapterTitle ?? book.author ?? "Unknown Author",
            albumTitle: book.author,
            duration: metadata.duration,
            elapsed: metadata.elapsed,
            showsProgress: LibraryDisplayPreferencesStore.shared.loadPreferences().showLockScreenProgressBar,
            rate: isPlaying ? Double(playbackSpeed) : 0,
            defaultRate: Double(playbackSpeed),
            mediaType: .audio,
            contentIdentifier: book.stableId,
            collectionIdentifier: book.providerId.uuidString,
            serviceIdentifier: Bundle.main.bundleIdentifier ?? "com.enve.enve",
            playbackQueueIndex: 0,
            playbackQueueCount: 1,
            chapterNumber: metadata.chapterNumber,
            chapterCount: metadata.chapterCount,
            artworkURL: book.coverURL
        )
        nowPlayingUpdateTask?.cancel()
        nowPlayingUpdateTask = Task { @MainActor [weak self] in
            guard self != nil else { return }
            NowPlayingCoordinator.shared.updateNowPlaying(info)
        }
    }

    func refreshNowPlayingInfo() {
        updateNowPlayingInfo()
    }

    private func setupObservers() {
        NotificationCenter.default.publisher(for: .preferencesDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.loadPlaybackPreferences()
            }
            .store(in: &cancellables)

        #if os(iOS)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.suspendNonEssentialBackgroundWork = true
                self.lastBackgroundTimePublishAt = .distantPast
                if self.isPlaying {
                    self.syncProgress(forceLocalWrite: true)
                    self.startSyncTimer()
                } else {
                    self.stopSyncTimer()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.suspendNonEssentialBackgroundWork = false
                self.lastBackgroundTimePublishAt = .distantPast
                if self.isOverlayPlaybackActive {
                    self.syncProgress(forceLocalWrite: true)
                }
                if self.isPlaying {
                    self.startSyncTimer()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self = self,
                    let userInfo = notification.userInfo,
                    let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                    let type = AVAudioSession.InterruptionType(rawValue: typeValue)
                else {
                    return
                }

                #if targetEnvironment(simulator)

                AppLogger.player.info("Ignoring audio-session interruption on simulator (type: \(type.rawValue))")
                return
                #else

                switch type {
                case .began:
                    let wasPlaying = self.isPlaying
                    self.shouldResumeAfterInterruption = wasPlaying

                    if wasPlaying {
                        AppLogger.player.info("Audio interrupted; pausing playback")
                        self.pause(userInitiated: false)
                    }

                case .ended:
                    let optionsRaw = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                    let shouldResume = options.contains(.shouldResume)

                    guard self.shouldResumeAfterInterruption else {
                        self.shouldResumeAfterInterruption = false
                        return
                    }

                    self.shouldResumeAfterInterruption = false

                    guard shouldResume, self.currentBook != nil else {
                        AppLogger.player.info("Interruption ended without resume signal")
                        return
                    }

                    AppLogger.player.info("Interruption ended; auto-resuming playback")
                    self.play()

                @unknown default:
                    self.shouldResumeAfterInterruption = false
                }
                #endif
            }
            .store(in: &cancellables)
        #endif
    }

    private var currentStatsTickInterval: TimeInterval {
        #if os(iOS)
        return UIApplication.shared.applicationState == .active ? activeStatsTickInterval : backgroundStatsTickInterval
        #else
        return activeStatsTickInterval
        #endif
    }

    private var currentProgressSyncInterval: TimeInterval {
        #if os(iOS)
        return UIApplication.shared.applicationState == .active ? activeProgressSyncInterval : backgroundProgressSyncInterval
        #else
        return activeProgressSyncInterval
        #endif
    }

    private var isAppActive: Bool {
        #if os(iOS)
        return UIApplication.shared.applicationState == .active
        #else
        return true
        #endif
    }

    private func updateRemoteSkipIntervals() {
        NowPlayingCoordinator.shared.updateSkipIntervals(
            forward: skipForwardInterval,
            backward: skipBackwardInterval
        )
    }

    func playDirectURL(_ book: Book, url: URL) {
        AppLogger.player.debug("playDirectURL bookDiagnosticID=\(diagnosticBookID(book)) url=\(url.redacted)")

        if currentBook?.stableId == book.stableId && player != nil {
            resume()
            return
        }

        stop()

        var resumeTime: TimeInterval = 0
        if let stored = BookProgressStore.shared.loadProgress(for: book) {
            resumeTime = stored.progress
        } else if let appProgress = UserProgressStore.shared.progress(for: book) {
            resumeTime = appProgress.currentTime
        }

        currentBook = book
        currentProvider = nil
        switchSpeedForCurrentBook()
        duration = book.duration ?? 0
        currentTime = resumeTime
        isLoading = true
        playbackError = nil

        let track = AudioTrackInfo(
            index: 0,
            startOffset: 0,
            duration: book.duration ?? 0,
            contentUrl: url.absoluteString,
            mimeType: "audio/mpeg"
        )
        currentTracks = [track]
        currentTrackIndex = 0
        currentTrackStartOffset = 0

        Task {
            do {
                try await loadAndPlayTrack(track, seekTime: resumeTime)
                await MainActor.run {
                    self.isLoading = false
                    self.play()
                }
            } catch {
                AppLogger.player.error("Direct URL playback failed: \(error)")
                await MainActor.run {
                    self.isLoading = false
                    self.playbackError = "Unable to play \"\(book.title)\": \(error.localizedDescription)"
                }
            }
        }
    }

    func playOverlayTracks(
        _ tracks: [AudioTrackInfo],
        book: Book,
        totalDuration: TimeInterval,
        resumeTime: TimeInterval
    ) async throws -> String {
        if isOverlayPlaybackActive,
            currentBook?.uniqueId == book.uniqueId,
            player != nil
        {
            isLoading = false
            if !isPlaying { resume() }
            return currentSessionId ?? "overlay-\(book.uniqueId)"
        }
        guard !tracks.isEmpty else { throw PlaybackError.assetNotPlayable }

        stop(invalidatePendingOverlayPreparation: false)

        currentBook = book
        currentProvider = nil
        switchSpeedForCurrentBook()
        duration = totalDuration
        currentTime = resumeTime
        isLoading = true
        playbackError = nil
        let sessionId = "overlay-\(book.uniqueId)-\(UUID().uuidString)"
        currentSessionId = sessionId

        let orderedTracks = normalizedTracks(tracks)
        self.currentTracks = orderedTracks

        do {
            if let state = orderedTracks.playbackState(at: resumeTime) {
                currentTrackIndex = state.index
                currentTrackStartOffset = state.track.startOffset
                try await loadAndPlayTrack(
                    state.track,
                    seekTime: state.localTime,
                    expectedSessionId: sessionId
                )
            } else {
                currentTrackIndex = 0
                currentTrackStartOffset = orderedTracks[0].startOffset
                try await loadAndPlayTrack(
                    orderedTracks[0],
                    seekTime: 0,
                    expectedSessionId: sessionId
                )
            }
            guard currentSessionId == sessionId else { throw CancellationError() }
            isLoading = false
            return sessionId
        } catch {
            if currentSessionId == sessionId {
                stop(invalidatePendingOverlayPreparation: false)
                isLoading = false
            }
            throw error
        }
    }

    func playLocalBook(_ book: Book) {
        AppLogger.player.debug("playLocalBook bookDiagnosticID=\(diagnosticBookID(book)) source=\(book.source)")

        if currentBook?.stableId == book.stableId && player != nil {
            AppLogger.player.info("Same book already loaded, resuming...")
            resume()
            return
        }

        stop()

        var resumeTime: TimeInterval = 0
        var localUpdate = Date.distantPast
        if let storedProgress = BookProgressStore.shared.loadProgress(for: book) {
            resumeTime = storedProgress.progress
            localUpdate = Date(timeIntervalSince1970: storedProgress.lastUpdated)
            AppLogger.player.info("Using stored progress: \(resumeTime)s")
        } else if let appProgress = UserProgressStore.shared.progress(for: book) {
            resumeTime = appProgress.currentTime
            localUpdate = appProgress.lastUpdate
            AppLogger.player.info("Using AppState progress: \(resumeTime)s")
        }

        currentBook = book
        currentProvider = self.connectionStore.capability(PlaybackSessionProvider.self, for: book)
        switchSpeedForCurrentBook()
        duration = book.duration ?? 0
        currentTime = resumeTime
        isLoading = true
        playbackError = nil

        Task {
            do {
                let resolvedResumeTime = await resolveProviderOpenResumeTime(
                    for: book,
                    provider: currentProvider,
                    initialResumeTime: resumeTime,
                    localUpdate: localUpdate
                )
                try await setupLocalPlayer(for: book, resumeTime: resolvedResumeTime)
                await MainActor.run {
                    self.isLoading = false
                    self.play()
                }
            } catch {
                AppLogger.player.error("Failed to setup local player: \(error)")
                await MainActor.run {
                    self.isLoading = false
                    self.playbackError = "Unable to play \"\(book.title)\": \(error.localizedDescription)"
                }
            }
        }
    }

    private func setupLocalPlayer(for book: Book, resumeTime: TimeInterval) async throws {
        AppLogger.player.debug("Setting up local player bookDiagnosticID=\(diagnosticBookID(book))")

        if let localPlaybackIssue = LocalStorageManager.shared.unsupportedLocalPlaybackReason(for: book) {
            throw NSError(
                domain: "PlaybackManager",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: localPlaybackIssue]
            )
        }

        if var localTracks = makeLocalTracks(for: book), !localTracks.isEmpty {
            if localTracks.count == 1, let fileURL = URL(string: localTracks[0].contentUrl), fileURL.isFileURL {
                if isZipFile(at: fileURL) {
                    AppLogger.player.info("Downloaded file is actually a ZIP archive, extracting...")
                    let dir = fileURL.deletingLastPathComponent()
                    try extractZipAndRebuild(at: fileURL, destinationDir: dir)
                    if let newTracks = makeLocalTracks(for: book), !newTracks.isEmpty {
                        localTracks = newTracks
                        AppLogger.player.info("Extracted \(localTracks.count) audio file(s) from ZIP")
                    } else {
                        throw PlaybackError.downloadedFileEmpty(path: "ZIP archive contained no playable audio files")
                    }
                }
            }
            if localTracks.count > 1 {
                AppLogger.player.info("Found \(localTracks.count) local downloaded file(s)")
            } else {
                let localURL = URL(string: localTracks[0].contentUrl)
                let descriptor = localURL.map(DiagnosticLogSanitizer.fileDescriptor) ?? "file[unresolved]"
                AppLogger.player.debug("Found local download: \(descriptor)")
            }
            self.currentSessionId = "local-\(book.id)"
            let orderedTracks = normalizedTracks(localTracks)
            self.currentTracks = orderedTracks

            if let state = orderedTracks.playbackState(at: resumeTime) {
                self.currentTrackIndex = state.index
                self.currentTrackStartOffset = state.track.startOffset
                try await loadAndPlayTrack(state.track, seekTime: state.localTime)
            } else {
                self.currentTrackIndex = 0
                self.currentTrackStartOffset = orderedTracks[0].startOffset
                try await loadAndPlayTrack(orderedTracks[0], seekTime: 0)
            }
            return
        }

        if book.source == .smb {
            AppLogger.player.info("SMB book not downloaded, starting streaming server...")
            guard let streamURLs = try await SMBStreamingServer.shared.startStreamingAllFiles(book: book),
                !streamURLs.isEmpty
            else {
                throw PlaybackError.smbStreamFailed
            }

            AppLogger.player.info("SMB streaming \(streamURLs.count) file(s)")
            let bookTracks = book.audioTracks ?? []
            var cumulativeOffset: TimeInterval = 0
            var smbTracks: [AudioTrackInfo] = []

            for (index, url) in streamURLs.enumerated() {
                let trackDuration: TimeInterval
                if index < bookTracks.count, bookTracks[index].duration > 0 {
                    trackDuration = bookTracks[index].duration
                } else if let totalDuration = book.duration, totalDuration > 0, streamURLs.count > 0 {
                    trackDuration = totalDuration / Double(streamURLs.count)
                } else {
                    trackDuration = 3600
                }

                let ext = url.pathExtension.lowercased()
                let mime: String
                switch ext {
                case "m4b", "m4a": mime = "audio/mp4"
                case "mp3": mime = "audio/mpeg"
                case "flac": mime = "audio/flac"
                default: mime = "audio/mpeg"
                }

                smbTracks.append(
                    AudioTrackInfo(
                        index: index,
                        startOffset: cumulativeOffset,
                        duration: trackDuration,
                        contentUrl: url.absoluteString,
                        mimeType: mime
                    )
                )
                cumulativeOffset += trackDuration
            }

            self.currentSessionId = "smb-stream-\(book.id)"
            let orderedTracks = normalizedTracks(smbTracks)
            self.currentTracks = orderedTracks

            if let state = orderedTracks.playbackState(at: resumeTime) {
                self.currentTrackIndex = state.index
                self.currentTrackStartOffset = state.track.startOffset
                try await loadAndPlayTrack(state.track, seekTime: state.localTime)
            } else {
                self.currentTrackIndex = 0
                self.currentTrackStartOffset = orderedTracks[0].startOffset
                try await loadAndPlayTrack(orderedTracks[0], seekTime: 0)
            }
            return
        }

        if let localTracks = buildLocalTrackInfos(from: book), !localTracks.isEmpty {
            AppLogger.player.info("Using \(localTracks.count) local track(s) from book metadata")
            self.currentSessionId = "local-\(book.id)"
            let orderedTracks = normalizedTracks(localTracks)
            self.currentTracks = orderedTracks

            if let state = orderedTracks.playbackState(at: resumeTime) {
                self.currentTrackIndex = state.index
                self.currentTrackStartOffset = state.track.startOffset
                try await loadAndPlayTrack(state.track, seekTime: state.localTime)
            } else {
                self.currentTrackIndex = 0
                self.currentTrackStartOffset = orderedTracks[0].startOffset
                try await loadAndPlayTrack(orderedTracks[0], seekTime: 0)
            }
            return
        }

        if let filePath = book.filePath {
            let url = Self.resolveLocalPath(filePath)
            AppLogger.player.debug("Using local file: \(DiagnosticLogSanitizer.fileDescriptor(for: url))")
            let track = AudioTrackInfo(
                index: 0,
                startOffset: 0,
                duration: book.duration ?? 0,
                contentUrl: url.absoluteString,
                mimeType: "audio/mp4"
            )
            self.currentSessionId = "local-\(book.id)"
            self.currentTracks = [track]
            self.currentTrackIndex = 0
            self.currentTrackStartOffset = 0
            try await loadAndPlayTrack(track, seekTime: resumeTime)
            return
        }

        throw PlaybackError.noAudioSource
    }

    func playBook(_ book: Book, provider: any PlaybackSessionProvider) {
        AppLogger.player.debug("playBook bookDiagnosticID=\(diagnosticBookID(book))")
        AppLogger.player.debug("Provider: \(type(of: provider))")
        let currentBookID = currentBook.map(diagnosticBookID) ?? "none"
        AppLogger.player.debug("Current bookDiagnosticID=\(currentBookID)")
        AppLogger.player.debug("Player exists: \(player != nil)")
        AppLogger.player.debug("Is playing: \(isPlaying)")
        AppLogger.player.debug("Current time in memory: \(currentTime)s")

        if currentBook?.stableId == book.stableId && player != nil {
            AppLogger.player.info("Same book already loaded, resuming from currentTime: \(currentTime)s...")
            refreshCurrentTimeFromPlayer()
            resume()
            return
        }

        AppLogger.player.info("Loading new book...")
        AppLogger.player.debug("Book diagnosticID: \(diagnosticBookID(book))")
        stop()

        let localProgress = UserProgressStore.shared.progress(for: book)
        var localTime = localProgress?.currentTime ?? 0
        var localUpdate = localProgress?.lastUpdate ?? Date.distantPast
        AppLogger.player.info("AppState progress: \(localTime)s, lastUpdate: \(localUpdate)")

        if let storedProgress = BookProgressStore.shared.loadProgress(for: book) {
            AppLogger.player.debug("Stored playback position=\(storedProgress.progress)s")
            if storedProgress.progress > localTime {
                localTime = storedProgress.progress
                localUpdate = Date(timeIntervalSince1970: storedProgress.lastUpdated)
                AppLogger.player.info("Using StorageService progress as it's higher: \(localTime)s")
            }
        } else {
            AppLogger.player.debug("No scoped playback progress found for bookDiagnosticID=\(diagnosticBookID(book))")
        }

        if book.source == .booklore, book.mediaType == .audiobook {
            currentBook = book
            currentProvider = provider
            duration = book.duration ?? 0
            isLoading = true
            Task { await reconcileGrimmoryAudiobook(book: book, provider: provider, localTime: localTime) }
            return
        }

        let freshBook = self.libraryCache.bookInMemory(uniqueId: book.uniqueId)
        let serverTime = freshBook?.currentTime ?? book.currentTime
        let serverUpdate = freshBook?.lastUpdate ?? book.lastUpdate

        AppLogger.player.info("Server/book progress: \(serverTime)s, lastUpdate: \(String(describing: serverUpdate))")

        let recentlySynced = localUpdate.timeIntervalSinceNow > -AppConstants.Playback.recentSyncWindow

        if abs(localTime - serverTime) > AppConstants.Playback.syncConflictThreshold && serverTime > 0 && localTime > 0 && !recentlySynced {
            AppLogger.player.debug(
                "Sync conflict for bookDiagnosticID=\(diagnosticBookID(book)). Local: \(localTime)s, Server: \(serverTime)s"
            )
            self.syncConflict = (local: localTime, server: serverTime, bookId: book.id)
            self.currentBook = book
            self.currentProvider = provider
            return
        }

        let resumeTime: TimeInterval
        if localTime > 0 {
            resumeTime = localTime
            AppLogger.player.info("Using local storage progress: \(localTime)s")
        } else if serverTime > 0 {
            resumeTime = serverTime
            AppLogger.player.info("Using book.currentTime progress: \(serverTime)s")
        } else {
            resumeTime = 0
            AppLogger.player.info("Starting from beginning")
        }

        currentBook = book
        currentProvider = provider
        switchSpeedForCurrentBook()
        duration = book.duration ?? 0
        currentTime = resumeTime

        isLoading = true
        playbackError = nil

        Task {
            do {
                let resolvedResumeTime = await resolveProviderOpenResumeTime(
                    for: book,
                    provider: provider,
                    initialResumeTime: resumeTime,
                    localUpdate: localUpdate
                )
                try await setupPlayer(for: book, provider: provider, resumeTime: resolvedResumeTime)
                await MainActor.run {
                    self.isLoading = false
                    self.play()
                }
            } catch {
                AppLogger.player.error("Failed to setup player: \(error)")
                await MainActor.run {
                    self.isLoading = false
                    self.playbackError = "Unable to play \"\(book.title)\": \(error.localizedDescription)"
                }
            }
        }
    }

    private func reconcileGrimmoryAudiobook(
        book: Book,
        provider: any PlaybackSessionProvider,
        localTime: TimeInterval
    ) async {
        let grimmory = provider as? BookloreProvider

        var resolvedBook = book
        var duration = book.duration ?? 0
        if duration <= 0, let grimmory,
            let session = try? await grimmory.startPlaybackSession(for: book)
        {
            let trackDuration = session.audioTracks.reduce(0.0) { $0 + max($1.duration, 0) }
            if trackDuration > 0 {
                duration = trackDuration
                resolvedBook.duration = duration
            }
        }

        var serverTime: TimeInterval = 0
        var serverStamp: Date?
        if let grimmory,
            let result = try? await grimmory.fetchAudiobookProgress(for: resolvedBook),
            let stamp = result.updatedAt
        {
            serverTime =
                result.positionSeconds > 0
                ? result.positionSeconds
                : (duration > 0 ? result.percentage * duration : 0)
            serverStamp = stamp
        }

        let decision = decideGrimmoryOpen(
            localTime: localTime,
            serverTime: serverTime,
            serverStamp: serverStamp,
            anchor: BookProgressStore.shared.loadServerStamp(for: resolvedBook),
            isFinished: resolvedBook.isFinished || resolvedBook.serverReadStatus == "READ"
        )

        switch decision {
        case .noServerData:
            startGrimmoryPlayback(book: resolvedBook, provider: provider, resumeTime: localTime)

        case .adoptServer(let resume):
            BookProgressStore.shared.saveProgress(for: resolvedBook, progress: resume, duration: duration)
            if let serverStamp { BookProgressStore.shared.saveServerStamp(for: resolvedBook, serverStamp) }
            AppLogger.player.debug(
                "[Grimmory open] pulling server \(Int(resume))s over local \(Int(localTime))s for bookDiagnosticID=\(diagnosticBookID(resolvedBook))"
            )
            startGrimmoryPlayback(book: resolvedBook, provider: provider, resumeTime: resume)

        case .keepLocal(let resume, let push):
            if let serverStamp { BookProgressStore.shared.saveServerStamp(for: resolvedBook, serverStamp) }
            startGrimmoryPlayback(book: resolvedBook, provider: provider, resumeTime: resume)
            if push {
                await SyncCoordinator.shared.pushProgress(
                    book: resolvedBook,
                    forceImmediate: true,
                    domain: .audiobook
                )
            }

        case .conflict(let local, let server):

            AppLogger.player.debug(
                "[Grimmory open] conflict: server \(Int(server))s behind local \(Int(local))s for bookDiagnosticID=\(diagnosticBookID(resolvedBook))"
            )
            currentBook = resolvedBook
            currentProvider = provider
            self.duration = duration
            isLoading = false
            pendingGrimmoryServerStamp = serverStamp
            syncConflict = (local: local, server: server, bookId: resolvedBook.id)
        }
    }

    private func startGrimmoryPlayback(
        book: Book,
        provider: any PlaybackSessionProvider,
        resumeTime: TimeInterval
    ) {
        currentBook = book
        currentProvider = provider
        switchSpeedForCurrentBook()
        duration = book.duration ?? 0
        currentTime = resumeTime
        isLoading = true
        playbackError = nil
        Task {
            do {
                try await setupPlayer(for: book, provider: provider, resumeTime: resumeTime)
                await MainActor.run {
                    self.isLoading = false
                    self.play()
                }
            } catch {
                AppLogger.player.error("Grimmory playback setup failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.isLoading = false
                    self.playbackError = "Unable to play \"\(book.title)\": \(error.localizedDescription)"
                }
            }
        }
    }

    private func resolveProviderOpenResumeTime(
        for book: Book,
        provider: (any PlaybackSessionProvider)?,
        initialResumeTime: TimeInterval,
        localUpdate: Date? = nil
    ) async -> TimeInterval {
        guard NetworkPolicyService.shared.isConnected,
            let provider,
            book.mediaType == .audiobook,
            book.source != .local,
            book.source != .smb,
            book.source != .booklore,
            let progressProvider = provider as? any AudiobookProgressPulling,
            let result = try? await progressProvider.fetchAudiobookProgress(for: book)
        else {
            return initialResumeTime
        }

        var serverTime = result.positionSeconds
        if serverTime <= 0,
            let duration = book.duration,
            duration > 0,
            result.percentage > 0
        {
            let fraction = result.percentage > 1 ? result.percentage / 100 : result.percentage
            serverTime = fraction * duration
        }

        guard serverTime > 0 else { return initialResumeTime }

        let tolerance = AppConstants.Playback.syncConflictThreshold
        if book.source == .storyteller, let serverStamp = result.updatedAt {
            let anchor = BookProgressStore.shared.loadServerStamp(for: book)
            let serverChanged = anchor == nil || serverStamp > anchor!.addingTimeInterval(0.5)
            if serverChanged || initialResumeTime <= tolerance {
                applyOpenResumeTime(serverTime, for: book, updatedAt: serverStamp, persist: true)
                BookProgressStore.shared.saveServerStamp(for: book, serverStamp)
                AppLogger.player.info(
                    "Using Storyteller server progress at open: \(Int(serverTime))s (local was \(Int(initialResumeTime))s)"
                )
                return serverTime
            }
        }

        let serverIsNewer =
            result.updatedAt.map { stamp in
                localUpdate.map { stamp > $0 } ?? true
            } ?? false
        let shouldAdopt =
            initialResumeTime <= tolerance
            || serverTime > initialResumeTime + tolerance
            || (serverIsNewer && abs(serverTime - initialResumeTime) > tolerance)

        guard shouldAdopt else { return initialResumeTime }

        applyOpenResumeTime(serverTime, for: book, updatedAt: result.updatedAt, persist: true)
        AppLogger.player.info("Using provider progress at open: \(Int(serverTime))s (local was \(Int(initialResumeTime))s)")
        return serverTime
    }

    private func applyOpenResumeTime(_ time: TimeInterval, for book: Book, updatedAt: Date?, persist: Bool) {
        currentTime = time
        let stamp = updatedAt ?? Date()

        if var activeBook = currentBook, activeBook.uniqueId == book.uniqueId {
            activeBook.currentTime = time
            activeBook.lastUpdate = stamp
            currentBook = activeBook
            self.bookSession.currentBook = activeBook
        } else if var activeBook = self.bookSession.currentBook, activeBook.uniqueId == book.uniqueId {
            activeBook.currentTime = time
            activeBook.lastUpdate = stamp
            self.bookSession.currentBook = activeBook
        }

        self.libraryCache.mutateBook(uniqueId: book.uniqueId) {
            $0.currentTime = time
            $0.lastUpdate = stamp
        }

        guard persist, time > 0 else { return }

        let duration = book.duration ?? self.duration
        BookProgressStore.shared.saveProgress(
            for: book,
            progress: time,
            duration: duration,
            at: stamp
        )
        UserProgressStore.shared.update(
            UserMediaProgress(
                id: UUID().uuidString,
                libraryItemId: book.isPodcastEpisode ? (book.podcastLibraryItemId ?? book.id) : book.id,
                providerId: book.providerId,
                episodeId: book.episodeId,
                currentTime: time,
                progress: duration > 0 ? time / duration : 0,
                isFinished: duration > 0 && time >= duration - 5,
                duration: duration,
                lastUpdate: stamp,
                ebookProgress: nil
            )
        )
        Task {
            await LinkedBookProgressCoordinator.shared.recordAudiobookProgress(
                book: book,
                currentTime: time,
                isFinished: duration > 0 && time >= duration - 5,
                observedAt: stamp,
                authoritative: true
            )
        }
    }

    private func setupPlayer(for book: Book, provider: any PlaybackSessionProvider, resumeTime: TimeInterval) async throws {
        AppLogger.player.debug("Setting up player bookDiagnosticID=\(diagnosticBookID(book))")
        AppLogger.player.debug("Resume time: \(resumeTime)s")
        self.currentProvider = provider
        let localPlaybackIssue = LocalStorageManager.shared.unsupportedLocalPlaybackReason(for: book)

        if localPlaybackIssue == nil,
            let localTracks = makeLocalTracks(for: book), !localTracks.isEmpty
        {
            let reason = NetworkPolicyService.shared.isConnected ? "downloaded book" : "offline mode"
            AppLogger.player.info("Using \(localTracks.count) local file(s) (\(reason))")
            self.currentSessionId = "local-\(book.id)"
            let orderedTracks = normalizedTracks(localTracks)
            self.currentTracks = orderedTracks
            if let state = orderedTracks.playbackState(at: resumeTime) {
                self.currentTrackIndex = state.index
                self.currentTrackStartOffset = state.track.startOffset
                try await loadAndPlayTrack(state.track, seekTime: state.localTime)
            } else {
                self.currentTrackIndex = 0
                self.currentTrackStartOffset = 0
                try await loadAndPlayTrack(orderedTracks[0], seekTime: 0)
            }
            return
        }

        if let localPlaybackIssue {
            AppLogger.player.warning("Skipping local playback for unsupported download: \(localPlaybackIssue)")
        }

        AppLogger.player.info("No local download, starting playback session...")
        let session: PlaybackSessionInfo
        do {
            session = try await provider.startPlaybackSession(for: book)
            AppLogger.player.info("Playback session started successfully")
        } catch {
            if localPlaybackIssue == nil,
                let localTracks = makeLocalTracks(for: book), !localTracks.isEmpty
            {
                AppLogger.player.error("Streaming session failed, falling back to \(localTracks.count) local file(s): \(error)")
                self.currentSessionId = "local-\(book.id)"
                let orderedTracks = normalizedTracks(localTracks)
                self.currentTracks = orderedTracks
                if let state = orderedTracks.playbackState(at: resumeTime) {
                    self.currentTrackIndex = state.index
                    self.currentTrackStartOffset = state.track.startOffset
                    try await loadAndPlayTrack(state.track, seekTime: state.localTime)
                } else {
                    self.currentTrackIndex = 0
                    self.currentTrackStartOffset = 0
                    try await loadAndPlayTrack(orderedTracks[0], seekTime: 0)
                }
                return
            }
            throw error
        }

        self.currentSessionId = session.sessionId
        let orderedTracks = normalizedTracks(session.audioTracks)
        guard let firstTrack = orderedTracks.first else {
            AppLogger.player.warning(
                "Playback session returned zero audio tracks for bookDiagnosticID=\(diagnosticBookID(book))"
            )
            throw PlaybackError.emptyPlaybackSession(bookTitle: book.title)
        }
        let sessionDuration = orderedTracks.totalDuration
        let playbackBook = book.withPlaybackSessionTimeline(
            tracks: orderedTracks,
            duration: sessionDuration > 0 ? sessionDuration : book.duration
        )
        self.currentBook = playbackBook
        self.bookSession.currentBook = playbackBook
        self.libraryCache.mutateBook(uniqueId: playbackBook.uniqueId) {
            $0.duration = playbackBook.duration
            $0.currentTime = playbackBook.currentTime
            $0.lastUpdate = playbackBook.lastUpdate
        }
        self.currentTracks = orderedTracks

        let effectiveResumeTime = resolvePlaybackResumeTime(
            requestedTime: resumeTime,
            sessionTime: session.serverCurrentTime,
            duration: sessionDuration,
            tolerance: AppConstants.Playback.resumeTimeTolerance
        )
        if resumeTime <= AppConstants.Playback.resumeTimeTolerance,
            let serverTime = session.serverCurrentTime,
            effectiveResumeTime == serverTime
        {
            AppLogger.player.info("Using server session currentTime: \(Int(serverTime))s")
        } else if effectiveResumeTime != resumeTime {
            AppLogger.player.info("Resume time \(resumeTime)s exceeds duration \(sessionDuration)s; resetting to 0")
        }
        if sessionDuration > 0 {
            self.duration = sessionDuration
        }
        if abs(currentTime - effectiveResumeTime) > AppConstants.Playback.seekCorrectionThreshold {
            applyOpenResumeTime(effectiveResumeTime, for: playbackBook, updatedAt: nil, persist: effectiveResumeTime > 0)
        }

        AppLogger.player.debug(
            "Session diagnosticID: \(DiagnosticLogSanitizer.identifier(for: session.sessionId))"
        )
        AppLogger.player.debug("Audio tracks count: \(orderedTracks.count)")

        for (index, track) in orderedTracks.enumerated() {
            AppLogger.player.info("Track \(index): startOffset=\(track.startOffset)s, duration=\(track.duration)s")
        }

        guard let state = orderedTracks.playbackState(at: effectiveResumeTime) else {
            AppLogger.player.info("Could not find track for time \(effectiveResumeTime), defaulting to start")
            currentTrackIndex = 0
            currentTrackStartOffset = firstTrack.startOffset
            try await loadAndPlayTrack(firstTrack, seekTime: 0)
            return
        }

        currentTrackIndex = state.index
        let targetTrack = state.track
        let localSeekTime = state.localTime
        currentTrackStartOffset = targetTrack.startOffset

        AppLogger.player.info("Selected track index: \(state.index) (Property Index: \(targetTrack.index))")
        AppLogger.player.info("Track start offset: \(targetTrack.startOffset)s")
        AppLogger.player.info("Local seek time within track: \(localSeekTime)s")

        guard let url = URL(string: targetTrack.contentUrl) else {
            AppLogger.player.error("Invalid audio URL for track \(targetTrack.index)")
            throw PlaybackError.invalidURL
        }

        AppLogger.player.info("Selected track URL: \(url.redacted)")
        AppLogger.player.info("Chapters: \(session.chapters.count)")

        if !session.chapters.isEmpty && ((book.chapters?.isEmpty ?? true) || (self.currentBook?.chapters?.isEmpty ?? true)) {
            AppLogger.player.warning("Updating missing chapters from session...")

            let sessionChapters = session.chapters

            ReaderArtifactsStore.shared.saveCachedChapters(bookId: book.stableId, chapters: sessionChapters)
            if book.id != book.stableId {
                ReaderArtifactsStore.shared.saveCachedChapters(bookId: book.id, chapters: sessionChapters)
            }

            await MainActor.run {
                if var updatedBook = self.currentBook {
                    updatedBook.chapters = sessionChapters
                    self.currentBook = updatedBook
                    self.bookSession.currentBook = updatedBook
                    self.libraryCache.mutateBook(uniqueId: updatedBook.uniqueId) { $0.chapters = sessionChapters }
                }
            }
        }

        try await loadAndPlayTrack(targetTrack, seekTime: localSeekTime)
    }

    private func clearPlaybackItemObservers() {
        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
            self.playbackEndObserver = nil
        }
        if let playbackFailureObserver {
            NotificationCenter.default.removeObserver(playbackFailureObserver)
            self.playbackFailureObserver = nil
        }
        if let playbackStalledObserver {
            NotificationCenter.default.removeObserver(playbackStalledObserver)
            self.playbackStalledObserver = nil
        }
    }

    private func resetPlaybackRecovery() {
        playbackRecoveryTask?.cancel()
        playbackRecoveryTask = nil
        playbackRecoveryAttempts = 0
        playbackRecoveryBaseline = 0
    }

    private func schedulePlaybackRecovery(
        track: AudioTrackInfo,
        playerItem: AVPlayerItem,
        phase: String,
        delayNanoseconds: UInt64
    ) {
        guard playbackRecoveryTask == nil, isPlaying, currentBook != nil else { return }
        guard playbackRecoveryAttempts < maxPlaybackRecoveryAttempts else {
            failPlaybackRecovery(phase: phase, error: playerItem.error)
            return
        }

        let sessionId = currentSessionId
        let itemIdentifier = ObjectIdentifier(playerItem)
        let stalledAt = currentTime
        playbackRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }

            guard let self else { return }
            guard self.currentSessionId == sessionId,
                self.isPlaying,
                let activeItem = self.player?.currentItem,
                ObjectIdentifier(activeItem) == itemIdentifier,
                abs(self.currentTime - stalledAt) < 1.5
            else {
                self.playbackRecoveryTask = nil
                return
            }

            self.playbackRecoveryAttempts += 1
            self.playbackRecoveryBaseline = self.currentTime
            let attempt = self.playbackRecoveryAttempts
            guard let state = self.currentTracks.playbackState(at: self.currentTime) else {
                self.playbackRecoveryTask = nil
                self.failPlaybackRecovery(phase: phase, error: playerItem.error)
                return
            }

            AppLogger.player.warning(
                "Recovering \(phase) on track \(state.index), attempt \(attempt)/\(self.maxPlaybackRecoveryAttempts)"
            )

            do {
                try await self.loadAndPlayTrack(
                    state.track,
                    seekTime: state.localTime,
                    expectedSessionId: sessionId,
                    isRecovery: true
                )
                guard self.currentSessionId == sessionId else {
                    self.playbackRecoveryTask = nil
                    return
                }
                self.player?.play()
                self.player?.rate = self.playbackSpeed
                self.playbackRecoveryTask = nil
            } catch {
                if error is CancellationError { return }
                AppLogger.player.error("Playback recovery attempt \(attempt) failed: \(error.localizedDescription)")
                self.playbackRecoveryTask = nil
                if attempt >= self.maxPlaybackRecoveryAttempts {
                    self.failPlaybackRecovery(phase: phase, error: error)
                } else if let retryItem = self.player?.currentItem {
                    self.schedulePlaybackRecovery(
                        track: track,
                        playerItem: retryItem,
                        phase: phase,
                        delayNanoseconds: 1_000_000_000
                    )
                }
            }
        }
    }

    private func failPlaybackRecovery(phase: String, error: Error?) {
        playbackRecoveryTask?.cancel()
        playbackRecoveryTask = nil
        player?.pause()
        isPlaying = false
        stopSyncTimer()
        syncProgress(forceLocalWrite: true)
        let detail = error?.localizedDescription ?? phase
        playbackError = "Unable to continue \"\(currentBook?.title ?? "this book")\": \(detail)"
    }

    private func loadAndPlayTrack(
        _ track: AudioTrackInfo,
        seekTime: TimeInterval = 0,
        expectedSessionId: String? = nil,
        isRecovery: Bool = false
    ) async throws {
        try validatePlaybackSession(expectedSessionId)
        if !isRecovery {
            resetPlaybackRecovery()
        }

        if let foundIndex = currentTracks.firstIndex(where: {
            $0.startOffset == track.startOffset && $0.contentUrl == track.contentUrl
        }) {
            currentTrackIndex = foundIndex
        } else {
            debugLog(" [PlaybackManager] Track index fallback")
            currentTrackIndex = currentTracks.firstIndex(where: { $0.index == track.index }) ?? 0
        }

        currentTrackStartOffset = track.startOffset

        guard let url = URL(string: track.contentUrl) else {
            AppLogger.player.error("Invalid audio URL for track \(track.index)")
            throw PlaybackError.invalidURL
        }

        let isLocalhost = url.host == "127.0.0.1" || url.host == "localhost"
        let isPodcastDirect = currentBook?.isPodcastEpisode == true && currentProvider == nil

        if !url.isFileURL && !isLocalhost && !isPodcastDirect && currentProvider == nil {
            throw PlaybackError.noProvider
        }

        debugLog(" [PlaybackManager] Loading track index: \(track.index)")
        debugLog(" [PlaybackManager] Track URL: \(url.redacted)")
        debugLog(" [PlaybackManager] Is localhost streaming: \(isLocalhost)")

        let asset: AVURLAsset
        if url.isFileURL || isLocalhost || isPodcastDirect {
            asset = AVURLAsset(url: url)
        } else {
            let headers = currentProvider?.getStreamingHeaders() ?? [:]
            AppLogger.player.info("Streaming headers: \(headers.keys.joined(separator: ", "))")
            let options = ["AVURLAssetHTTPHeaderFieldsKey": headers]
            asset = AVURLAsset(url: url, options: options)
        }

        var playableAsset = asset
        let isPlayable = try await asset.load(.isPlayable)
        try validatePlaybackSession(expectedSessionId)
        if !isPlayable {
            if url.isFileURL, let correctedURL = Self.correctFileExtensionIfNeeded(for: url) {
                AppLogger.player.debug(
                    "File format mismatch corrected: \(DiagnosticLogSanitizer.fileDescriptor(for: correctedURL))"
                )
                let retryAsset = AVURLAsset(url: correctedURL)
                let retryPlayable = try await retryAsset.load(.isPlayable)
                try validatePlaybackSession(expectedSessionId)
                if retryPlayable {
                    playableAsset = retryAsset
                    if let idx = currentTracks.firstIndex(where: { $0.contentUrl == track.contentUrl }) {
                        currentTracks[idx] = AudioTrackInfo(
                            id: currentTracks[idx].id,
                            index: currentTracks[idx].index,
                            startOffset: currentTracks[idx].startOffset,
                            duration: currentTracks[idx].duration,
                            contentUrl: correctedURL.absoluteString,
                            mimeType: mimeType(forFileExtension: correctedURL.pathExtension),
                            title: currentTracks[idx].title
                        )
                    }
                } else {
                    Self.logLocalFileInfo(url)
                    throw PlaybackError.assetNotPlayable
                }
            } else {
                Self.logLocalFileInfo(url)
                throw PlaybackError.assetNotPlayable
            }
        }
        let playerItem = AVPlayerItem(asset: playableAsset)

        clearPlaybackItemObservers()
        playbackFailureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.logStreamingFailureContext(
                        error,
                        track: track,
                        url: url,
                        playerItem: playerItem,
                        phase: "AVPlayerItemFailedToPlayToEndTime"
                    )
                }
                self.schedulePlaybackRecovery(
                    track: track,
                    playerItem: playerItem,
                    phase: "failed to play to end",
                    delayNanoseconds: 250_000_000
                )
            }
        }
        playbackStalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                AppLogger.player.warning("Playback stalled on track \(track.index); monitoring for recovery")
                self.schedulePlaybackRecovery(
                    track: track,
                    playerItem: playerItem,
                    phase: "playback stalled",
                    delayNanoseconds: 3_000_000_000
                )
            }
        }

        #if targetEnvironment(simulator)
        AppLogger.player.warning("Skipping audio tap on simulator")
        #else
        if let assetTrack = try? await playableAsset.loadTracks(withMediaType: AVMediaType.audio).first {
            try validatePlaybackSession(expectedSessionId)
            let audioMix = AVMutableAudioMix()
            let parameters = AVMutableAudioMixInputParameters(track: assetTrack)
            if let tap = audioProcessor.createTap() {
                parameters.audioTapProcessor = tap
                AppLogger.player.info("Attached audio processing tap")
            }
            audioMix.inputParameters = [parameters]
            playerItem.audioMix = audioMix
        }
        #endif
        try validatePlaybackSession(expectedSessionId)

        if let player = self.player {
            player.replaceCurrentItem(with: playerItem)
        } else {
            let player = AVPlayer(playerItem: playerItem)
            self.player = player
        }

        guard let player = self.player else { return }
        activateNowPlayingSession(for: player)

        let startTime = Date()
        while playerItem.status != .readyToPlay && playerItem.status != .failed {
            if Date().timeIntervalSince(startTime) > AppConstants.Playback.mediaLoadTimeout {
                throw PlaybackError.mediaLoadTimeout
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            try validatePlaybackSession(expectedSessionId)
        }

        if playerItem.status == .failed {
            if let itemError = playerItem.error {
                logStreamingFailureContext(itemError, track: track, url: url, playerItem: playerItem, phase: "playerItemStatusFailed")
            }
            throw PlaybackError.playerItemFailed(underlying: playerItem.error)
        }

        AppLogger.player.info("Player item ready, duration: \(playerItem.duration.seconds)s")

        let itemDuration = playerItem.duration.seconds
        if itemDuration.isFinite && itemDuration > 0 && self.duration <= 0 {
            if let idx = currentTracks.firstIndex(where: { $0.contentUrl == track.contentUrl }),
                currentTracks[idx].duration <= 0
            {
                currentTracks[idx] = AudioTrackInfo(
                    id: currentTracks[idx].id,
                    index: currentTracks[idx].index,
                    startOffset: currentTracks[idx].startOffset,
                    duration: itemDuration,
                    contentUrl: currentTracks[idx].contentUrl,
                    mimeType: currentTracks[idx].mimeType,
                    title: currentTracks[idx].title
                )
            }
            let totalDuration: TimeInterval
            if currentTracks.count <= 1 {
                totalDuration = itemDuration
            } else {
                let sum = currentTracks.reduce(TimeInterval(0)) { acc, t in
                    if t.contentUrl == track.contentUrl {
                        return acc + max(itemDuration, t.duration)
                    }
                    return acc + max(t.duration, 0)
                }
                totalDuration = sum > 0 ? sum : currentTrackStartOffset + itemDuration
            }
            AppLogger.player.info("Updating duration from player item: \(totalDuration)s (\(currentTracks.count) track(s))")
            self.duration = totalDuration
            if var updatedBook = self.currentBook, (updatedBook.duration ?? 0) <= 0 {
                updatedBook.duration = totalDuration
                self.currentBook = updatedBook
                self.bookSession.currentBook = updatedBook
                self.libraryCache.mutateBook(uniqueId: updatedBook.uniqueId) { $0.duration = totalDuration }
            }
        }
        if itemDuration.isFinite && itemDuration > 0 {
            let chapterDuration: TimeInterval
            if self.duration > 0 {
                chapterDuration = self.duration
            } else if currentTracks.count > 1 {
                let sum = currentTracks.totalDuration
                chapterDuration = sum > 0 ? sum : currentTrackStartOffset + itemDuration
            } else {
                chapterDuration = itemDuration
            }
            normalizeChaptersIfNeeded(totalDuration: chapterDuration)
        }

        if seekTime > 0 {
            let safeSeek = min(seekTime, playerItem.duration.seconds - 0.1)
            AppLogger.player.info("Seeking to local position: \(safeSeek)s")
            let seekCMTime = CMTime(seconds: safeSeek, preferredTimescale: 1000)
            await player.seek(to: seekCMTime)
            try validatePlaybackSession(expectedSessionId)
        }

        setupTimeObserver(for: player)

        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
        }
        let endSessionId = currentSessionId
        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] notification in
            guard let object = notification.object as AnyObject? else { return }
            let endedItem = ObjectIdentifier(object)
            Task { @MainActor [weak self] in
                guard let self,
                    self.currentSessionId == endSessionId,
                    let currentItem = self.player?.currentItem,
                    ObjectIdentifier(currentItem) == endedItem
                else { return }
                self.advanceAfterPlaybackFinished(expectedSessionId: endSessionId)
            }
        }

        if isPlaying {
            player.play()
            player.rate = playbackSpeed
        }
    }

    private func validatePlaybackSession(_ expectedSessionId: String?) throws {
        if let expectedSessionId, currentSessionId != expectedSessionId {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    private func advanceAfterPlaybackFinished(expectedSessionId: String?) {
        guard currentSessionId == expectedSessionId else { return }
        debugLog(" [PlaybackManager] Finished playing track \(currentTrackIndex)")

        guard currentTrackIndex + 1 < currentTracks.count else {
            debugLog(" [PlaybackManager] Finished all tracks in book")
            let completedBook = currentBook
            if duration > 0 {
                currentTime = duration
            }
            isPlaying = false
            stopSyncTimer()
            syncProgress(forceLocalWrite: true)
            if let completedBook {
                playbackCompletionSubject.send(completedBook)
            }
            return
        }

        let nextIndex = currentTrackIndex + 1
        let nextTrack = currentTracks[nextIndex]
        let sessionId = expectedSessionId
        debugLog("⏭ [PlaybackManager] Advancing to track \(nextIndex)")

        Task {
            do {
                try await loadAndPlayTrack(nextTrack, expectedSessionId: sessionId)
                guard self.currentSessionId == sessionId else { return }
            } catch {
                if error is CancellationError { return }
                AppLogger.player.error("Failed to transition to next track: \(error)")
                await MainActor.run {
                    self.isPlaying = false
                    self.playbackError = "Unable to continue \"\(self.currentBook?.title ?? "this book")\": \(error.localizedDescription)"
                }
            }
        }
    }

    private func setupTimeObserver(for player: AVPlayer) {
        if let old = timeObserver {
            player.removeTimeObserver(old)
            timeObserver = nil
        }
        let interval = CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self = self, !self.isSeeking else { return }
                let oldTime = self.currentTime
                let localTime = CMTimeGetSeconds(time)
                let newTime = localTime + self.currentTrackStartOffset
                let now = Date()
                if self.playbackRecoveryAttempts > 0,
                    newTime >= self.playbackRecoveryBaseline + 5
                {
                    self.playbackRecoveryAttempts = 0
                    self.playbackRecoveryBaseline = newTime
                }
                if self.isAppActive {
                    self.currentTime = newTime
                } else if now.timeIntervalSince(self.lastBackgroundTimePublishAt) >= self.backgroundTimePublishInterval {
                    self.currentTime = newTime
                    self.lastBackgroundTimePublishAt = now
                }

                if !self.suspendNonEssentialBackgroundWork,
                    let book = self.currentBook,
                    now.timeIntervalSince(self.lastStatsTickAt) >= self.currentStatsTickInterval
                {
                    self.lastStatsTickAt = now
                    Task {
                        await ListeningStatsTracker.shared.recordTick(
                            bookId: book.stableId,
                            position: newTime,
                            playbackRate: Double(self.playbackSpeed),
                            isPlaying: self.isPlaying
                        )
                    }
                }

                if self.duration <= 0,
                    let item = player.currentItem
                {
                    let itemDur = item.duration.seconds
                    if itemDur.isFinite && itemDur > 0 {
                        let total: TimeInterval
                        if self.currentTracks.count <= 1 {
                            total = itemDur
                        } else {
                            let sum = self.currentTracks.totalDuration
                            total = sum > 0 ? sum : self.currentTrackStartOffset + itemDur
                        }
                        AppLogger.player.info("Late duration update from player: \(total)s (\(self.currentTracks.count) track(s))")
                        self.duration = total
                        if var updatedBook = self.currentBook, (updatedBook.duration ?? 0) <= 0 {
                            updatedBook.duration = total
                            self.currentBook = updatedBook
                            self.bookSession.currentBook = updatedBook
                            self.libraryCache.mutateBook(uniqueId: updatedBook.uniqueId) { $0.duration = total }
                        }
                        self.normalizeChaptersIfNeeded(totalDuration: total)
                    }
                }

                if self.isPlaying && abs(newTime - oldTime) < 2.0 {
                    self.timeListenedSinceLastSync += abs(newTime - oldTime)
                }
            }
        }
    }

    func play() {
        AppLogger.player.info("play() called")
        guard let player else {
            isPlaying = false
            AppLogger.player.info("play() called but player is nil")
            return
        }

        setupAudioSession()
        announcePlaybackOwnership()
        AppLogger.player.info("Setting player rate to \(playbackSpeed)x")
        player.rate = playbackSpeed
        isPlaying = true
        AppLogger.player.info("Now playing at \(playbackSpeed)x speed")

        startSyncTimer()
        updateNowPlayingInfo()
        lastStatsTickAt = .distantPast

        if let book = currentBook {
            Task {
                await ListeningStatsTracker.shared.startSession(
                    bookId: book.stableId,
                    position: currentTime,
                    playbackRate: Double(playbackSpeed),
                    duration: duration
                )
            }
        }
    }

    func pause() {
        pause(userInitiated: true)
    }

    private func pause(userInitiated: Bool) {
        AppLogger.player.info("pause() called")
        player?.pause()
        isPlaying = false
        stopSyncTimer()
        lastStatsTickAt = .distantPast
        AppLogger.player.info("Paused")

        guard userInitiated else { return }
        let pausedOverlayPlayback = isOverlayPlaybackActive
        let pausedBook = currentBook
        let pausedTime = currentTime
        let pausedDuration = duration
        syncProgress(forceLocalWrite: true, includeLocalState: pausedOverlayPlayback)

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self,
                !self.isPlaying,
                self.currentBook?.uniqueId == pausedBook?.uniqueId
            else { return }
            if !pausedOverlayPlayback {
                self.updateLocalState(to: pausedTime, force: true)
            }
            self.persistRecentPlaybackSnapshot()

            if let book = pausedBook {
                await ListeningStatsTracker.shared.endSession(
                    bookId: book.stableId,
                    finalPosition: pausedTime,
                    duration: pausedDuration
                )
            }
        }
    }

    func fadeOutAndPause(duration: TimeInterval = 3.0, steps: Int = 20) async {
        guard let player else {
            pause()
            return
        }

        let safeSteps = max(1, steps)
        let stepDelay = duration / Double(safeSteps)
        let originalVolume = player.volume

        for step in stride(from: safeSteps, through: 1, by: -1) {
            let volume = originalVolume * Float(step) / Float(safeSteps)
            player.volume = volume
            try? await Task.sleep(nanoseconds: UInt64(stepDelay * 1_000_000_000))
        }

        pause()
        player.volume = originalVolume
    }

    func outputVolume() -> Float {
        player?.volume ?? 1.0
    }

    func setOutputVolume(_ volume: Float) {
        player?.volume = max(0, min(1, volume))
    }

    func resume() {
        AppLogger.player.info("resume() called")
        play()
    }

    func stop(invalidatePendingOverlayPreparation: Bool = true) {
        AppLogger.player.info("stop() called")
        let wasOverlayPlayback = isOverlayPlaybackActive
        let stoppedBook = currentBook
        let finalPosition = currentTime
        let finalDuration = duration
        #if os(iOS)
        if invalidatePendingOverlayPreparation {
            MediaOverlayPlaybackService.shared.cancelPendingPlay()
            AlignedReadAloudSessionCoordinator.shared.cancel()
        }
        #endif

        player?.pause()
        isPlaying = false

        if let observer = timeObserver, let currentPlayer = player {
            AppLogger.player.info("Removing time observer")
            currentPlayer.removeTimeObserver(observer)
            timeObserver = nil
        }

        player = nil
        clearPlaybackItemObservers()
        resetPlaybackRecovery()
        clearNowPlayingSession()

        stopSyncTimer()
        lastStatsTickAt = .distantPast
        syncProgress(forceLocalWrite: true)
        if var b = self.bookSession.currentBook,
            b.uniqueId == stoppedBook?.uniqueId
        {
            b.currentTime = finalPosition
            self.bookSession.currentBook = b
        }
        persistRecentPlaybackSnapshot()

        let bookForStats = stoppedBook
        Task {
            if let book = bookForStats {
                await ListeningStatsTracker.shared.endSession(
                    bookId: book.stableId,
                    finalPosition: finalPosition,
                    duration: finalDuration
                )
            }
        }

        currentBook = nil
        currentProvider = nil
        currentSessionId = nil
        timeListenedSinceLastSync = 0
        currentTracks = []
        currentTrackIndex = 0
        currentTrackStartOffset = 0
        isLoading = false
        updateNowPlayingInfo()
        #if os(iOS)
        if wasOverlayPlayback {
            MediaOverlayPlaybackService.shared.clearActiveResult()
        }
        #endif
    }

    func stopOverlaySession(ifMatching sessionId: String) {
        guard currentSessionId == sessionId, isOverlayPlaybackActive else { return }
        stop(invalidatePendingOverlayPreparation: false)
    }

    private func activateNowPlayingSession(for player: AVPlayer) {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            if nowPlayingSession?.players.contains(where: { $0 === player }) != true {
                let session = MPNowPlayingSession(players: [player])
                session.automaticallyPublishesNowPlayingInfo = false
                nowPlayingSession = session
                NowPlayingCoordinator.shared.setNowPlayingSession(session, for: self)
            }
            nowPlayingSession?.becomeActiveIfPossible { _ in }
        }
        #endif
    }

    private func clearNowPlayingSession() {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            if let session = nowPlayingSession {
                session.players.forEach { session.removePlayer($0) }
            }
            nowPlayingSession = nil
            NowPlayingCoordinator.shared.clearNowPlayingSession(if: self)
        }
        #endif
    }

    func seek(to time: TimeInterval) {
        isSeeking = true
        currentTime = time

        if var b = self.bookSession.currentBook {
            b.currentTime = time
            self.bookSession.currentBook = b
        }

        let optimisticLocalTime = time - currentTrackStartOffset

        AppLogger.player.info("Seeking to global: \(time)s, local: \(optimisticLocalTime)s")

        guard let state = currentTracks.playbackState(at: time) else {
            AppLogger.player.info("Could not find track for seek time \(time)")
            isSeeking = false
            return
        }

        let targetIndex = state.index
        let targetTrack = state.track
        let localSeekTime = state.localTime

        if targetIndex != currentTrackIndex {
            AppLogger.player.info("Seeking requires track switch to index \(targetIndex)")
            let sessionId = currentSessionId
            Task {
                do {
                    try await loadAndPlayTrack(
                        targetTrack,
                        seekTime: localSeekTime,
                        expectedSessionId: sessionId
                    )

                    await MainActor.run {
                        guard self.currentSessionId == sessionId else { return }
                        self.currentTime = time
                        self.isSeeking = false
                        self.updateNowPlayingInfo()
                        self.syncProgress(forceLocalWrite: true)
                    }
                } catch {
                    if error is CancellationError { return }
                    AppLogger.player.error("Failed to seek to other track: \(error)")
                    await MainActor.run {
                        self.isSeeking = false
                    }
                }
            }
            return
        }

        let cmTime = CMTime(seconds: localSeekTime, preferredTimescale: CMTimeScale(NSEC_PER_SEC))

        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self = self else { return }

                self.isSeeking = false

                if finished {
                    let actualLocalTime = self.player?.currentTime().seconds ?? 0
                    let actualGlobalTime = actualLocalTime + self.currentTrackStartOffset
                    AppLogger.player.info("Seek completed to local: \(actualLocalTime)s, global: \(actualGlobalTime)s")
                    self.currentTime = actualGlobalTime

                    self.updateNowPlayingInfo()
                } else {
                    AppLogger.player.info("Seek did not complete")
                }
            }
        }

        syncProgress(forceLocalWrite: true)
    }

    private var hasReliableTrackTimeline: Bool {
        guard currentTracks.count > 1 else { return true }
        guard currentTracks.allSatisfy({ $0.duration > 0 }) else { return false }
        return zip(currentTracks, currentTracks.dropFirst()).allSatisfy { previous, next in
            next.startOffset > previous.startOffset
        }
    }

    private func seekRelativelyInQueue(by delta: TimeInterval) {
        guard !currentTracks.isEmpty else { return }

        var durations = currentTracks.map(\.duration)
        let index = min(max(currentTrackIndex, 0), currentTracks.count - 1)
        let localPosition =
            player?.currentTime().seconds.isFinite == true
            ? max(0, player?.currentTime().seconds ?? 0)
            : max(0, currentTime - currentTrackStartOffset)
        if let itemDuration = player?.currentItem?.duration.seconds,
            itemDuration.isFinite,
            itemDuration > 0
        {
            durations[index] = itemDuration
        }

        let target = resolveRelativeTrackSeek(
            durations: durations,
            currentIndex: index,
            currentPosition: localPosition,
            delta: delta
        )
        let targetTrack = currentTracks[target.index]
        let targetGlobalTime = targetTrack.startOffset + target.position

        isSeeking = true
        currentTime = targetGlobalTime
        if var book = self.bookSession.currentBook {
            book.currentTime = targetGlobalTime
            self.bookSession.currentBook = book
        }

        if target.index != currentTrackIndex {
            let sessionId = currentSessionId
            Task {
                do {
                    try await loadAndPlayTrack(
                        targetTrack,
                        seekTime: target.position,
                        expectedSessionId: sessionId
                    )
                    guard currentSessionId == sessionId else { return }
                    currentTime = targetGlobalTime
                    isSeeking = false
                    updateNowPlayingInfo()
                    syncProgress(forceLocalWrite: true)
                } catch {
                    if error is CancellationError { return }
                    AppLogger.player.error("Failed to seek to adjacent track: \(error)")
                    isSeeking = false
                }
            }
            return
        }

        let seekTime = CMTime(seconds: target.position, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player?.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSeeking = false
                if finished {
                    let actualLocalTime = self.player?.currentTime().seconds ?? target.position
                    self.currentTime = self.currentTrackStartOffset + actualLocalTime
                    self.updateNowPlayingInfo()
                }
            }
        }
        syncProgress(forceLocalWrite: true)
    }

    func resolveConflict(useServer: Bool) {
        guard let conflict = syncConflict, let book = currentBook, let provider = currentProvider else {
            syncConflict = nil
            return
        }

        let grimmoryStamp = pendingGrimmoryServerStamp
        let targetTime = useServer ? conflict.server : conflict.local
        syncConflict = nil

        if let grimmoryStamp {
            BookProgressStore.shared.saveServerStamp(for: book, grimmoryStamp)
            if !useServer {
                Task {
                    await SyncCoordinator.shared.pushProgress(
                        book: book,
                        forceImmediate: true,
                        domain: .audiobook
                    )
                }
            }
        }

        duration = book.duration ?? 0
        currentTime = targetTime

        isLoading = true

        Task {
            do {
                if let localTracks = makeLocalTracks(for: book), !localTracks.isEmpty, !NetworkPolicyService.shared.isConnected {
                    AppLogger.player.info("Offline conflict resolution: using \(localTracks.count) local file(s)")
                    self.currentSessionId = "local-\(book.id)"
                    let orderedTracks = normalizedTracks(localTracks)
                    self.currentTracks = orderedTracks
                    if let state = orderedTracks.playbackState(at: targetTime) {
                        self.currentTrackIndex = state.index
                        self.currentTrackStartOffset = state.track.startOffset
                        try await loadAndPlayTrack(state.track, seekTime: state.localTime)
                    } else {
                        self.currentTrackIndex = 0
                        self.currentTrackStartOffset = orderedTracks[0].startOffset
                        try await loadAndPlayTrack(orderedTracks[0], seekTime: 0)
                    }
                } else {
                    try await setupPlayer(for: book, provider: provider, resumeTime: targetTime)
                }
                await MainActor.run {
                    self.isLoading = false
                    self.play()
                }
            } catch {
                AppLogger.player.error("Failed to setup player after conflict resolution: \(error)")
                await MainActor.run {
                    self.isLoading = false
                }
            }
        }
    }

    private func makeLocalTracks(for book: Book) -> [AudioTrackInfo]? {
        let storage = LocalStorageManager.shared
        guard let localFiles = storage.localAudiobookFilesIfExists(for: book),
            !localFiles.isEmpty
        else {
            return nil
        }

        if localFiles.count == 1, let singleFile = localFiles.first {
            return [
                AudioTrackInfo(
                    index: 0,
                    startOffset: 0,
                    duration: book.duration ?? 0,
                    contentUrl: singleFile.absoluteString,
                    mimeType: mimeType(forFileExtension: singleFile.pathExtension)
                )
            ]
        }

        var result: [AudioTrackInfo] = []
        var runningOffset: TimeInterval = 0

        let fallbackPerTrackDuration: TimeInterval = {
            if let totalDuration = book.duration, totalDuration > 0, localFiles.count > 0 {
                return totalDuration / Double(localFiles.count)
            }
            return 3600
        }()

        for (idx, fileURL) in localFiles.enumerated() {
            let trackDuration: TimeInterval
            if let bookTracks = book.audioTracks,
                idx < bookTracks.count,
                bookTracks[idx].duration > 0
            {
                trackDuration = bookTracks[idx].duration
            } else {
                trackDuration = fallbackPerTrackDuration
            }

            result.append(
                AudioTrackInfo(
                    index: idx,
                    startOffset: runningOffset,
                    duration: trackDuration,
                    contentUrl: fileURL.absoluteString,
                    mimeType: mimeType(forFileExtension: fileURL.pathExtension)
                )
            )
            runningOffset += trackDuration
        }

        return result.isEmpty ? nil : result
    }

    private func makeLocalTrack(for book: Book) -> AudioTrackInfo? {
        return makeLocalTracks(for: book)?.first
    }

    private func buildLocalTrackInfos(from book: Book) -> [AudioTrackInfo]? {
        guard let tracks = book.audioTracks, !tracks.isEmpty else { return nil }

        let sortedTracks = tracks.sorted { lhs, rhs in
            if lhs.index == rhs.index {
                return lhs.startOffset < rhs.startOffset
            }
            return lhs.index < rhs.index
        }

        var result: [AudioTrackInfo] = []
        for track in sortedTracks {
            guard let trackPath = track.filePath else { continue }
            let resolvedURL = Self.resolveLocalPath(trackPath)
            guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
                AppLogger.player.warning(
                    "Track file not found: \(DiagnosticLogSanitizer.fileDescriptor(for: resolvedURL))"
                )
                continue
            }

            result.append(
                AudioTrackInfo(
                    index: track.index,
                    startOffset: track.startOffset,
                    duration: track.duration,
                    contentUrl: resolvedURL.absoluteString,
                    mimeType: mimeType(forFileExtension: resolvedURL.pathExtension)
                )
            )
        }

        return result.isEmpty ? nil : result
    }

    static func resolveLocalPath(_ storedPath: String) -> URL {
        if FileManager.default.fileExists(atPath: storedPath) {
            return URL(fileURLWithPath: storedPath)
        }

        let markers = ["/Documents/", "/Documents"]
        for marker in markers {
            if let range = storedPath.range(of: marker) {
                let relativePart = String(storedPath[range.upperBound...])
                if !relativePart.isEmpty {
                    let resolved = URL.documentsDirectory.appendingPathComponent(relativePart)
                    if FileManager.default.fileExists(atPath: resolved.path) {
                        return resolved
                    }
                }
            }
        }

        return URL(fileURLWithPath: storedPath)
    }

    private func mimeType(forFileExtension ext: String) -> String {
        switch ext.lowercased() {
        case "m4b", "m4a", "mp4":
            return "audio/mp4"
        case "aac":
            return "audio/aac"
        case "flac":
            return "audio/flac"
        case "ogg":
            return "audio/ogg"
        case "wav":
            return "audio/wav"
        default:
            return "audio/mpeg"
        }
    }

    static func correctFileExtensionIfNeeded(for fileURL: URL) -> URL? {
        guard let detectedExt = UnifiedDownloadService.detectExtensionFromMagicBytes(at: fileURL) else {
            return nil
        }
        let currentExt = fileURL.pathExtension.lowercased()
        guard detectedExt != currentExt else { return nil }

        AppLogger.player.info("Format mismatch: file has .\(currentExt) extension but content is .\(detectedExt)")
        let correctedURL = fileURL.deletingPathExtension().appendingPathExtension(detectedExt)
        do {
            if FileManager.default.fileExists(atPath: correctedURL.path) {
                try FileManager.default.removeItem(at: correctedURL)
            }
            try FileManager.default.moveItem(at: fileURL, to: correctedURL)
            return correctedURL
        } catch {
            AppLogger.player.error("Failed to rename file: \(error.localizedDescription)")
            return nil
        }
    }

    static func logLocalFileInfo(_ url: URL) {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
            let size = attrs[.size] as? Int64
        {
            AppLogger.player.info("File size: \(size) bytes (\(size / 1024)KB)")
        }
        if let handle = try? FileHandle(forReadingFrom: url),
            let header = try? handle.read(upToCount: 16)
        {
            let hex = header.map { String(format: "%02X", $0) }.joined(separator: " ")
            AppLogger.player.info("File header bytes: \(hex)")
            try? handle.close()
        }
    }

    private func isZipFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { handle.closeFile() }
        let header = handle.readData(ofLength: 4)
        return header.count >= 4
            && header[0] == 0x50
            && header[1] == 0x4B
            && header[2] == 0x03
            && header[3] == 0x04
    }

    private func extractZipAndRebuild(at zipURL: URL, destinationDir: URL) throws {
        let unzipDir = destinationDir.appendingPathComponent("temp_unzip")
        try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)

        try Zip.unzipFile(zipURL, destination: unzipDir, overwrite: true, password: nil)

        let audioExtensions = Set(["m4b", "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus"])
        var extractedCount = 0
        let enumerator = FileManager.default.enumerator(at: unzipDir, includingPropertiesForKeys: nil)

        while let itemURL = enumerator?.nextObject() as? URL {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: itemURL.path, isDirectory: &isDir), !isDir.boolValue {
                let ext = itemURL.pathExtension.lowercased()
                if audioExtensions.contains(ext) {
                    let outputURL = destinationDir.appendingPathComponent("chapter_\(extractedCount).\(ext)")
                    try? FileManager.default.removeItem(at: outputURL)
                    try? FileManager.default.moveItem(at: itemURL, to: outputURL)
                    extractedCount += 1
                }
            }
        }

        try? FileManager.default.removeItem(at: unzipDir)
        try? FileManager.default.removeItem(at: zipURL)
        if extractedCount == 0 {
            throw PlaybackError.downloadedFileEmpty(path: zipURL.path)
        }
    }

    func skipForward(seconds: TimeInterval? = nil) {
        let interval = seconds ?? skipForwardInterval
        if hasReliableTrackTimeline {
            seek(to: currentTime + interval)
        } else {
            seekRelativelyInQueue(by: interval)
        }
    }

    func skipBackward(seconds: TimeInterval? = nil) {
        let interval = seconds ?? skipBackwardInterval
        if hasReliableTrackTimeline {
            seek(to: max(0, currentTime - interval))
        } else {
            seekRelativelyInQueue(by: -interval)
        }
    }

    func setPlaybackSpeed(_ speed: Float) {
        let clamped = clampedPlaybackSpeed(speed)
        playbackSpeed = clamped

        if let book = currentBook, !book.isPodcastEpisode {
            PlaybackSpeedMemory.shared.remember(Double(clamped), forStableId: book.stableId)
        }
    }

    #if DEBUG

    func debugApplyPerBookSpeed(for book: Book) {
        currentBook = book
        switchSpeedForCurrentBook()
    }
    #endif

    private func statusDescription(_ status: AVPlayerItem.Status) -> String {
        switch status {
        case .unknown: return "Unknown"
        case .readyToPlay: return "Ready to Play"
        case .failed: return "Failed"
        @unknown default: return "Unknown (\(status.rawValue))"
        }
    }

    private func startSyncTimer() {
        syncTimer?.invalidate()
        let interval = currentProgressSyncInterval
        syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncProgress()
            }
        }
        syncTimer?.tolerance = min(5.0, interval * 0.25)
    }

    private func stopSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    private func syncProgress(forceLocalWrite: Bool = false, includeLocalState: Bool = true) {
        guard let book = currentBook else { return }
        refreshCurrentTimeFromPlayer()
        let time = currentTime
        let finished = isFinishedLocal()
        let sessionId = currentSessionId

        if includeLocalState {
            updateLocalState(to: time, force: forceLocalWrite)
        }

        guard currentProvider is any AudiobookProgressPushing else {
            debugLog(" [PlaybackManager] No remote provider; saved local progress only")
            return
        }

        guard UserProgressStore.shared.syncProgressToServer else {
            debugLog(" [PlaybackManager] Server sync disabled (syncProgressToServer=false)")
            return
        }

        Task {
            let listenedTime = timeListenedSinceLastSync
            await SyncCoordinator.shared.pushAudiobookProgress(
                book: book,
                position: time,
                sessionId: sessionId,
                isFinished: finished,
                timeListened: listenedTime,
                forceImmediate: true
            )
            self.timeListenedSinceLastSync = 0
            if book.source == .storyteller {
                BookProgressStore.shared.saveServerStamp(for: book, Date())
            }
        }
    }

    private func updateLocalState(to time: TimeInterval, force: Bool = false) {
        guard let book = currentBook else { return }
        let finished = isFinishedLocal()
        let persistedDuration = duration > 0 ? duration : (book.duration ?? 0)

        if time < 1 && !force {
            if let existing = BookProgressStore.shared.loadProgress(for: book),
                existing.progress > 5
            {
                return
            }
        }

        let now = Date()
        if !force {
            let delta = abs(time - lastLocalPersistedTime)
            let elapsed = now.timeIntervalSince(lastLocalPersistedAt)
            let finishedChanged = (lastLocalPersistedFinished == nil) || (lastLocalPersistedFinished != finished)
            guard delta >= localProgressMinDelta || elapsed >= localProgressMinInterval || finishedChanged else {
                return
            }
        }

        let progress = UserMediaProgress(
            id: UUID().uuidString,
            libraryItemId: book.isPodcastEpisode ? (book.podcastLibraryItemId ?? book.id) : book.id,
            providerId: book.providerId,
            episodeId: book.episodeId,
            currentTime: time,
            progress: persistedDuration > 0 ? time / persistedDuration : 0,
            isFinished: finished,
            duration: persistedDuration,
            lastUpdate: now,
            ebookProgress: nil
        )

        UserProgressStore.shared.update(progress)
        BookProgressStore.shared.saveProgress(
            for: book,
            progress: time,
            duration: persistedDuration,
            at: now
        )
        lastLocalPersistedTime = time
        lastLocalPersistedAt = now
        lastLocalPersistedFinished = finished

        #if os(iOS)

        if isOverlayPlaybackActive {
            MediaOverlayPlaybackService.shared.syncEbookPositionFromAudio(
                audioTime: time,
                book: book,
                authoritative: force
            )
            return
        }
        #endif

        Task {
            await LinkedBookProgressCoordinator.shared.recordAudiobookProgress(
                book: book,
                currentTime: time,
                isFinished: finished,
                observedAt: now,
                authoritative: force
            )
        }

        let fanBook = book
        let fanFraction = persistedDuration > 0 ? time / persistedDuration : 0
        Task { await WorkProgressSync.shared.fanOut(from: fanBook, fraction: fanFraction, isFinished: finished, force: force) }
    }

    private func refreshCurrentTimeFromPlayer() {
        guard !isSeeking, let player else { return }
        let localTime = player.currentTime().seconds
        guard localTime.isFinite, localTime >= 0 else { return }
        let globalTime = max(0, localTime + currentTrackStartOffset)
        guard abs(globalTime - currentTime) > 0.25 else { return }
        currentTime = globalTime
        if var book = currentBook {
            book.currentTime = globalTime
            currentBook = book
            self.bookSession.currentBook = book
        }
    }

    private func isFinishedLocal() -> Bool {
        guard duration > 0 else { return false }
        return currentTime >= (duration - 5)
    }

}

extension PlaybackManager: RemoteCommandTarget {
    func remotePlay() { play() }
    func remotePause() { pause() }
    func remoteToggle() { isPlaying ? pause() : play() }
    func remoteNext() { skipForward() }
    func remotePrevious() { skipBackward() }
    func remoteSkipForward(by seconds: TimeInterval?) { skipForward(seconds: seconds) }
    func remoteSkipBackward(by seconds: TimeInterval?) { skipBackward(seconds: seconds) }
    func remoteSeek(to positionTime: TimeInterval) { seek(to: positionTime) }
    var remoteSkipForwardInterval: TimeInterval { skipForwardInterval }
    var remoteSkipBackwardInterval: TimeInterval { skipBackwardInterval }
}
