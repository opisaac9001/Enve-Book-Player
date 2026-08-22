import Foundation

struct BookSyncProviderSummary: Sendable {
    let name: String
}

struct BookSyncStatusUpdate: Sendable {
    let phase: BookSyncStatusPhase
    let message: String
}

enum BookSyncStatusPhase: Equatable, Sendable {
    case idle
    case syncing
    case error(String)
}

@MainActor
@Observable
final class SyncEngine {
    private let appState: AppState
    private let coordinator: SyncCoordinator

    init(
        appState: AppState = .shared,
        coordinator: SyncCoordinator = .shared
    ) {
        self.appState = appState
        self.coordinator = coordinator
    }

    var lastSyncDate: Date? {
        coordinator.lastSyncDate
    }

    var isSyncing: Bool {
        coordinator.isSyncing
    }

    var pendingSyncCount: Int {
        coordinator.pendingSyncCount
    }

    var syncEnabled: Bool {
        coordinator.syncEnabled
    }

    func manualSync() async {
        await coordinator.manualSync()
    }

    func providerSummary(for book: Book) -> BookSyncProviderSummary? {
        guard let provider = appState.getProvider(book.providerId), provider.syncCapability != .none else {
            return nil
        }
        let connection = provider.connection
        return BookSyncProviderSummary(name: connection.name.isEmpty ? connection.type.rawValue : connection.name)
    }

    func pushProgress(for book: Book) async {
        let domain: ProgressSyncDomain
        if book.hasEPUB3MediaOverlay {
            domain = book.epubLocatorIsAudio ? .audiobook : .ebook
        } else {
            domain = book.mediaType == .ebook ? .ebook : .audiobook
        }
        await coordinator.pushProgress(
            book: book,
            forceImmediate: true,
            domain: domain
        )
    }

    func statusUpdates(for book: Book) -> AsyncStream<BookSyncStatusUpdate> {
        let events = coordinator.subscribe(book: book)
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                for await event in events {
                    continuation.yield(Self.statusUpdate(for: event))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func statusUpdate(for event: SyncEvent) -> BookSyncStatusUpdate {
        switch event {
        case .pullStarted:
            return BookSyncStatusUpdate(phase: .syncing, message: "Checking the server...")
        case .pullCompleted(_, let applied):
            return BookSyncStatusUpdate(phase: .idle, message: applied ? "Brought back newer progress" : "Up to date")
        case .pushStarted:
            return BookSyncStatusUpdate(phase: .syncing, message: "Sending your progress...")
        case .pushCompleted:
            return BookSyncStatusUpdate(phase: .idle, message: "Saved to the server")
        case .pushFailed(_, let error, _):
            return BookSyncStatusUpdate(phase: .error(error), message: "Couldn't sync")
        case .conflictDetected:
            return BookSyncStatusUpdate(phase: .error("Conflict"), message: "Two positions disagree")
        }
    }
}
