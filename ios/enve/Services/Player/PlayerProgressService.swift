import Combine
import Foundation
import Logging

public class PlayerProgressService {
    static let shared = PlayerProgressService(
        providerConnections: AppState.shared.providerConnections
    )

    private let storageService: StorageService
    private let plexService: PlexService
    private let audiobookshelfService: AudiobookshelfService
    private let providerConnections: any ProviderConnectionAccessing

    private var progressSyncTimer: Timer?

    public var absSessionActive = false

    private unowned let profileSession: ProfileSession

    init(
        storageService: StorageService = StorageService(),
        plexService: PlexService = PlexService(),
        audiobookshelfService: AudiobookshelfService = AudiobookshelfService(),
        providerConnections: any ProviderConnectionAccessing,
        profileSession: ProfileSession = .owner
    ) {
        self.profileSession = profileSession
        self.storageService = storageService
        self.plexService = plexService
        self.audiobookshelfService = audiobookshelfService
        self.providerConnections = providerConnections
    }

    public func saveProgress(book: Book, position: TimeInterval, duration: TimeInterval) {
        profileSession.bookProgress.saveProgress(for: book, progress: position, duration: duration)
    }

    public func loadProgress(for book: Book) -> (position: TimeInterval, duration: TimeInterval)? {
        if let saved = profileSession.bookProgress.loadProgress(for: book) {
            return (saved.progress, saved.duration)
        }
        return nil
    }

    public func saveLastPlayedBookId(_ id: String) {
        profileSession.playerState.saveLastPlayedBookId(id)
    }

    public func syncProgressToRemote(book: Book, progress: TimeInterval) async {
        await profileSession.sync.persistCurrentPlayback(book: book, position: progress)
        guard profileSession.serverSyncEnabled else { return }
        let duration = book.duration ?? profileSession.playback.player.duration
        guard duration > 0 else { return }
        if book.source == .audiobookshelf, absSessionActive { return }
        await profileSession.sync.pushAudiobookProgress(
            book: book,
            position: progress,
            sessionId: nil,
            isFinished: progress >= duration * Book.finishedProgressThreshold,
            timeListened: 0
        )
    }

    public func checkProgressConflict(
        book: Book,
        localProgress: TimeInterval,
        serverPositionAlreadyResolved: Bool = false
    ) async -> ProgressConflict? {
        guard profileSession.serverSyncEnabled else { return nil }
        var remoteProgress: TimeInterval?
        var remoteName: String = ""

        if let cloudProgress = await profileSession.sync.getCloudProgress(for: book) {
            remoteProgress = cloudProgress.position
            remoteName = cloudProgress.deviceName ?? "iCloud"
        }

        if profileSession.serverSyncEnabled, book.source == .plex,
            let serverUrl = profileSession.plexAuth.loadServerUrl(),
            let token = profileSession.plexAuth.loadToken(),
            let plexResult = try? await plexService.fetchProgress(serverUrl: serverUrl, token: token, ratingKey: book.ratingKey)
        {
            let plexSeconds = plexResult.offset
            if remoteProgress == nil || abs(plexSeconds - (remoteProgress ?? 0)) > 30 {
                remoteProgress = plexSeconds
                remoteName = "Plex"
            }
        }

        if profileSession.serverSyncEnabled, book.source == .audiobookshelf && !serverPositionAlreadyResolved,
            let backendId = book.backendId,
            let backend = await MainActor.run(body: {
                providerConnections.backend(id: backendId)
            }),
            let absProgress = try? await audiobookshelfService.getProgress(
                libraryItemId: book.partKey ?? book.id,
                backend: backend
            )
        {
            let serverTime = absProgress.currentTime ?? 0
            if serverTime > 0 && (remoteProgress == nil || abs(serverTime - (remoteProgress ?? 0)) > 30) {
                remoteProgress = serverTime
                remoteName = backend.name
            }
        }

        if profileSession.serverSyncEnabled, book.source == .storyteller && !serverPositionAlreadyResolved,
            let provider = await MainActor.run(body: {
                providerConnections.provider(for: book.providerId) as? StorytellerProvider
            }),
            let result = try? await provider.fetchAudiobookProgress(for: book)
        {
            let serverTime = result.positionSeconds
            if serverTime > 0 && (remoteProgress == nil || abs(serverTime - (remoteProgress ?? 0)) > 30) {
                remoteProgress = serverTime
                remoteName = "Storyteller"
            }
        }

        guard profileSession.serverSyncEnabled else { return nil }
        let conflictThreshold: TimeInterval = 30
        guard let remote = remoteProgress, abs(remote - localProgress) > conflictThreshold else {
            return nil
        }

        if localProgress < 5 {
            AppLogger.player.info("Auto-accepting remote (local is at start): \(Int(remote))s from \(remoteName)")
            return ProgressConflict(
                localProgress: localProgress,
                remoteProgress: remote,
                remoteName: remoteName,
                onChooseLocal: {},
                onChooseRemote: {},
                autoAcceptRemote: true
            )
        }

        if remote > localProgress {
            AppLogger.player.info("Remote is ahead - auto-accepting: \(Int(localProgress))s -> \(Int(remote))s from \(remoteName)")
            return ProgressConflict(
                localProgress: localProgress,
                remoteProgress: remote,
                remoteName: remoteName,
                onChooseLocal: {},
                onChooseRemote: {},
                autoAcceptRemote: true
            )
        }

        return ProgressConflict(
            localProgress: localProgress,
            remoteProgress: remote,
            remoteName: remoteName,
            onChooseLocal: {},
            onChooseRemote: {}
        )
    }

    public func startProgressSync(currentBook: Book?, isPlaying: Bool, progressProvider: @escaping @MainActor @Sendable () -> TimeInterval)
    {
        progressSyncTimer?.invalidate()

        guard isPlaying, let book = currentBook else { return }

        let interval = profileSession.preferences.loadPreferences().syncInterval
        progressSyncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                let currentProgress = progressProvider()
                await self?.syncProgressToRemote(book: book, progress: currentProgress)
            }
        }
    }

    public func stopProgressSync() {
        progressSyncTimer?.invalidate()
        progressSyncTimer = nil
    }
}
