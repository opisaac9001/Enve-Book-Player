@preconcurrency import CarPlay
import Combine
import Foundation
import Logging

final class CarPlayController {
    private let interfaceController: CPInterfaceController
    private let environment: CarPlayEnvironment
    private var tabBar: CarPlayTabBar?
    private var nowPlaying: CarPlayNowPlaying?
    private(set) var isConnected = true

    init(interfaceController: CPInterfaceController, environment: CarPlayEnvironment) {
        self.interfaceController = interfaceController
        self.environment = environment
    }

    func invalidate() {
        isConnected = false
        nowPlaying?.invalidate()
    }

    func start() {
        Task { @MainActor in
            guard self.isConnected else { return }
            let nowPlaying = CarPlayNowPlaying(
                interfaceController: self.interfaceController,
                environment: self.environment
            )
            self.nowPlaying = nowPlaying

            let tabBar = CarPlayTabBar(
                interfaceController: self.interfaceController,
                environment: self.environment,
                nowPlaying: nowPlaying
            )
            self.tabBar = tabBar

            tabBar.buildAndSetRoot()

            if self.environment.controller.snapshot.currentBook != nil {
                nowPlaying.showNowPlaying()
            }
        }
    }
}

@MainActor
func carPlayInterfaceCompletion(
    _ operation: String,
    then followUp: (() -> Void)? = nil
) -> (Bool, (any Error)?) -> Void {
    { success, error in
        if !success {
            if let error {
                AppLogger.carplay.error("[CarPlay] \(operation) failed: \(error)")
            } else {
                AppLogger.carplay.error("[CarPlay] \(operation) failed")
            }
        }
        followUp?()
    }
}

extension CarPlayEnvironment {
    static func live(profileSession: ProfileSession = .owner) -> CarPlayEnvironment {
        let composition = profileSession.playback.composition
        let library = profileSession.appState
        let downloads = LocalCarPlayDownloadState(profileSession: profileSession)
        return CarPlayEnvironment(
            controller: composition.controller,
            nowPlayingUpdater: composition.nowPlayingUpdater,
            conflictResolver: composition.conflictResolver,
            playback: CarPlayPlaybackService(
                controller: composition.controller,
                nowPlayingUpdater: composition.nowPlayingUpdater,
                bookStarter: profileSession.engine.playback,
                library: library,
                chapterSource: PlayerCarPlayChapterSource(profileSession: profileSession),
                downloads: downloads
            ),
            catalog: profileSession.bookStore,
            connections: profileSession.providerConnections,
            library: library,
            progress: profileSession.bookProgress,
            downloads: downloads
        )
    }
}

extension PlaybackEngine: CarPlayReadAloudStarting {}

extension ProviderConnectionStore: CarPlayConnectionObserving {
    var connectionsChanged: AnyPublisher<Void, Never> {
        changes.map { _ in () }.eraseToAnyPublisher()
    }
}

extension AppState: CarPlayLibraryReading {
    var cachedBookCount: Int { hotCache.count }

    var libraryChanged: AnyPublisher<Void, Never> {
        allBooksChanged.eraseToAnyPublisher()
    }
}

extension BookProgressStore: CarPlayProgressReading {
    func lastProgressUpdate(stableId: String) -> TimeInterval? {
        loadProgress(bookId: stableId)?.lastUpdated
    }

    func recentlyPlayed() -> [Book] {
        loadRecentlyPlayed()
    }
}

private final class PlayerCarPlayChapterSource: CarPlayChapterSource {
    private let profileSession: ProfileSession
    init(profileSession: ProfileSession) { self.profileSession = profileSession }
    var playerBook: Book? { profileSession.playback.player.currentBook }
    var playerChapters: [Chapter] { profileSession.playback.player.chapters }

    func cachedChapters(bookId: String) -> [Chapter] {
        profileSession.readerArtifacts.loadCachedChapters(bookId: bookId) ?? []
    }
}

private final class LocalCarPlayDownloadState: CarPlayDownloadState {
    private let profileSession: ProfileSession
    init(profileSession: ProfileSession) { self.profileSession = profileSession }
    func downloadedAudiobookIds() async -> Set<String> {
        let storage = profileSession.localStorage
        return await Task.detached(priority: .userInitiated) {
            Set(storage.downloadedAudiobookIds())
        }.value
    }

    func downloadedAudiobooks(from candidates: [Book], downloadedIds: Set<String>) async -> [Book] {
        await Task.detached(priority: .userInitiated) {
            CarPlayCatalog.downloadedAudiobooks(candidates, downloadedIds: downloadedIds) {
                LocalStorageManager.sanitizedId(for: $0.downloadKey)
            }
        }.value
    }

    func isAudiobookDownloaded(_ book: Book, downloadedIds: Set<String>) -> Bool {
        profileSession.localStorage.isAudiobookDownloaded(book, downloadedIds: downloadedIds)
    }

    func hasActiveDownload(_ book: Book) -> Bool {
        profileSession.downloads.tasks.contains { $0.isActive && $0.bookId == book.downloadKey }
    }

    func hasLocalReadaloudEbook(_ book: Book) -> Bool {
        profileSession.ebooks.resolveEbookForOverlay(book: book) != nil
    }
}
