import Foundation

extension CloudKitProgressSync: SyncSink {
    var id: String { "cloudkit.progress" }
    var displayName: String { "iCloud" }

    func isApplicable(to book: Book, domain: ProgressSyncDomain) -> Bool {
        guard !domain.usesEbookProgress else { return false }
        return SyncCoordinator.shared.isCloudKitAvailable
    }

    func pull(book: Book, domain: ProgressSyncDomain) async -> SyncSnapshot? {
        guard !domain.usesEbookProgress else { return nil }
        let identity = CanonicalBookIdentity(from: book)
        guard let record = try? await fetchProgress(for: identity) else { return nil }
        let dur = book.duration ?? 0
        let progress = dur > 0 ? record.playbackPosition / dur : 0
        return SyncSnapshot(
            progress: progress,
            positionSeconds: record.playbackPosition,
            locator: nil,
            lastUpdate: record.lastUpdated,
            isFinished: record.completed,
            source: "iCloud"
        )
    }

    func push(_ update: ProgressUpdate) async throws {
        guard update.domain == .audiobook else { return }
        guard update.positionSeconds > 0 else { return }
        let identity = CanonicalBookIdentity(from: update.book)
        let duration = update.book.duration ?? 0
        let completed = duration > 0 && update.positionSeconds >= duration * 0.99
        try await saveProgress(
            identity: identity,
            position: update.positionSeconds,
            playbackRate: update.playbackRate,
            completed: completed
        )
    }
}
