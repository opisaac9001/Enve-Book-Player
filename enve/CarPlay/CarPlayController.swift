@preconcurrency import CarPlay
import Combine
import Foundation

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

extension CarPlayEnvironment {
    static func live() -> CarPlayEnvironment {
        let composition = ActivePlayback.composition
        let library = AppState.shared
        let downloads = LocalCarPlayDownloadState()
        return CarPlayEnvironment(
            controller: composition.controller,
            nowPlayingUpdater: composition.nowPlayingUpdater,
            conflictResolver: composition.conflictResolver,
            playback: CarPlayPlaybackService(
                controller: composition.controller,
                nowPlayingUpdater: composition.nowPlayingUpdater,
                bookStarter: EnveEngine.shared.playback,
                library: library,
                chapterSource: PlayerCarPlayChapterSource(),
                downloads: downloads
            ),
            catalog: AppState.shared.bookStore,
            connections: AppState.shared.providerConnections,
            library: library,
            progress: BookProgressStore.shared,
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
    var playerBook: Book? { PlayerViewModel.shared.currentBook }
    var playerChapters: [Chapter] { PlayerViewModel.shared.chapters }

    func cachedChapters(bookId: String) -> [Chapter] {
        ReaderArtifactsStore.shared.loadCachedChapters(bookId: bookId) ?? []
    }
}

private final class LocalCarPlayDownloadState: CarPlayDownloadState {
    func downloadedAudiobookIds() async -> Set<String> {
        let storage = LocalStorageManager.shared
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
        LocalStorageManager.shared.isAudiobookDownloaded(book, downloadedIds: downloadedIds)
    }

    func hasActiveDownload(_ book: Book) -> Bool {
        UnifiedDownloadService.shared.tasks.contains { $0.isActive && $0.bookId == book.downloadKey }
    }

    func hasLocalReadaloudEbook(_ book: Book) -> Bool {
        LocalEbookImporter.shared.resolveEbookForOverlay(book: book) != nil
    }
}
