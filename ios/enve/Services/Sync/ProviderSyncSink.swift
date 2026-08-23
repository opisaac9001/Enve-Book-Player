import Foundation

@MainActor
final class ProviderSyncSink: SyncSink {
    static let identifier = "library.provider"

    let id = identifier
    let displayName = "Library Provider"

    private let providerResolver: any LibraryProviderResolving

    init(providerResolver: any LibraryProviderResolving) {
        self.providerResolver = providerResolver
    }

    func isApplicable(to book: Book, domain: ProgressSyncDomain) -> Bool {
        guard let provider = providerResolver.provider(for: book) else { return false }
        let supportsDomain = domain.usesEbookProgress
            ? provider is any EbookProgressPulling || provider is any EbookProgressPushing
            : provider is any AudiobookProgressPulling || provider is any AudiobookProgressPushing
        return supportsDomain
            && (provider.syncCapability.contains(.pullProgress) || provider.syncCapability.contains(.pushProgress))
    }

    func pull(book: Book, domain: ProgressSyncDomain) async -> SyncSnapshot? {
        guard let provider = providerResolver.provider(for: book) else { return nil }
        guard provider.syncCapability.contains(.pullProgress) else { return nil }
        let sourceName = provider.connection.name.isEmpty ? provider.connection.type.rawValue : provider.connection.name

        if domain.usesEbookProgress {
            if book.isStorytellerReadAloud {
                guard let storyteller = provider as? StorytellerProvider,
                    let authoritative = await StorytellerPositionSyncService.shared.authoritativePosition(
                        for: book,
                        through: storyteller
                    )
                else { return nil }
                return SyncSnapshot(
                    progress: authoritative.position.progression,
                    positionSeconds: 0,
                    locator: authoritative.position.locatorJSON,
                    lastUpdate: authoritative.position.observedAt,
                    isFinished: authoritative.position.progression >= 0.99,
                    source: sourceName
                )
            }
            guard let progressProvider = provider as? any EbookProgressPulling else { return nil }
            guard let result = try? await progressProvider.fetchEbookProgressState(for: book),
                result.readState != .notReading
            else { return nil }
            return SyncSnapshot(
                progress: result.progress,
                positionSeconds: 0,
                locator: result.locator,
                lastUpdate: result.updatedAt ?? .distantPast,
                isFinished: result.readState.isAbandoned || result.readState.isFinished || result.progress >= 0.99,
                source: sourceName
            )
        } else {
            guard let progressProvider = provider as? any AudiobookProgressPulling else { return nil }
            guard let result = try? await progressProvider.fetchAudiobookProgressState(for: book),
                result.readState != .notReading
            else { return nil }
            let dur = book.duration ?? 1
            let prog = dur > 0 ? result.positionSeconds / dur : result.percentage
            return SyncSnapshot(
                progress: prog,
                positionSeconds: result.positionSeconds,
                locator: nil,
                lastUpdate: result.updatedAt ?? .distantPast,
                isFinished: result.readState.isAbandoned || result.readState.isFinished || result.percentage >= 0.99 || prog >= 0.99,
                source: sourceName
            )
        }
    }

    func push(_ update: ProgressUpdate) async throws {
        guard let provider = providerResolver.provider(for: update.book) else { return }
        guard provider.syncCapability.contains(.pushProgress) else { return }

        if update.domain == .ebook {
            if update.book.isStorytellerReadAloud,
                let storyteller = provider as? StorytellerProvider
            {
                if update.isFinished {
                    try await StorytellerPositionSyncService.shared.finish(
                        book: update.book,
                        observedAt: update.book.lastUpdate,
                        through: storyteller
                    )
                } else if update.progress <= 0.001 {
                    try await StorytellerPositionSyncService.shared.reset(
                        book: update.book,
                        observedAt: update.book.lastUpdate,
                        through: storyteller
                    )
                } else {
                    guard let locator = update.locator else { throw ProviderError.invalidResponse }
                    try await StorytellerPositionSyncService.shared.submit(
                        book: update.book,
                        locatorJSON: locator,
                        observedAt: update.book.lastUpdate,
                        through: storyteller
                    )
                }
                return
            }
            if let provider = provider as? any EngineAwareEbookProgressProvider {
                try await provider.updateEbookProgress(
                    for: update.book,
                    progress: update.progress,
                    epubLocator: update.locator,
                    sourceEngine: update.sourceEngine
                )
            } else {
                guard let progressProvider = provider as? any EbookProgressPushing else {
                    throw ProviderError.notImplemented
                }
                try await progressProvider.updateEbookProgress(
                    for: update.book,
                    progress: update.progress,
                    epubLocator: update.locator
                )
            }
        } else {
            guard let progressProvider = provider as? any AudiobookProgressPushing else {
                throw ProviderError.notImplemented
            }
            try await progressProvider.updatePlaybackProgress(
                book: update.book,
                sessionId: update.sessionId,
                currentTime: update.positionSeconds,
                isFinished: update.isFinished,
                timeListened: update.timeListened
            )
        }
    }
}
