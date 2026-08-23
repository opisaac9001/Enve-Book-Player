import Combine
import Foundation

@MainActor
protocol RecentlyPlayedProgressAPI: AnyObject {
    func allProgress(backend: BackendConfig) async throws -> [ABSMediaProgress]
    func pushAudiobookProgress(
        libraryItemId: String,
        currentTime: TimeInterval,
        duration: TimeInterval,
        isFinished: Bool,
        backend: BackendConfig
    ) async throws
    func pushEbookProgress(libraryItemId: String, progress: Double, isFinished: Bool, backend: BackendConfig) async throws
}

@MainActor
final class AudiobookshelfRecentlyPlayedProgressAPI: RecentlyPlayedProgressAPI {
    private let service: AudiobookshelfService

    init(service: AudiobookshelfService) {
        self.service = service
    }

    func allProgress(backend: BackendConfig) async throws -> [ABSMediaProgress] {
        try await service.getAllProgress(backend: backend)
    }

    func pushAudiobookProgress(
        libraryItemId: String,
        currentTime: TimeInterval,
        duration: TimeInterval,
        isFinished: Bool,
        backend: BackendConfig
    ) async throws {
        try await service.updateProgress(
            libraryItemId: libraryItemId,
            currentTime: currentTime,
            duration: duration,
            isFinished: isFinished,
            backend: backend
        )
    }

    func pushEbookProgress(libraryItemId: String, progress: Double, isFinished: Bool, backend: BackendConfig) async throws {
        try await service.updateEbookProgress(
            libraryItemId: libraryItemId,
            ebookProgress: progress,
            isFinished: isFinished,
            backend: backend
        )
    }
}

@MainActor
protocol RecentlyPlayedProgressCaching: AnyObject {
    func loadProgress(for book: Book) -> (progress: TimeInterval, duration: TimeInterval, lastUpdated: TimeInterval)?
    func saveProgress(for book: Book, progress: TimeInterval, duration: TimeInterval, at date: Date)
    func saveRecentlyPlayed(_ book: Book, date: Date)
}

extension BookProgressStore: RecentlyPlayedProgressCaching {}

@MainActor
protocol RecentlyPlayedLibraryCaching: AnyObject {
    var allBooks: [Book] { get set }
    var allBooksChanged: PassthroughSubject<Void, Never> { get }

    func performAllBooksBatch(_ body: () -> Void)
    func withAllBooksTransaction(_ body: () async -> Void) async

    @discardableResult
    func mutateBook(stableId: String, _ transform: (inout Book) -> Void) -> Book?
}

extension AppState: RecentlyPlayedLibraryCaching {}

@MainActor
protocol EbookLinkPersisting: AnyObject {
    @discardableResult
    func saveLinks() -> Task<Void, Never>?
}

extension EbookLinkStore: EbookLinkPersisting {}

@MainActor
protocol SyncStrategyProviding: AnyObject {
    var syncStrategies: [any ProviderSyncStrategy] { get }
}

extension PluginRegistry: SyncStrategyProviding {}
