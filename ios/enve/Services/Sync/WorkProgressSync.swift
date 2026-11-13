import Foundation

@MainActor
final class WorkProgressSync {
    static let shared = WorkProgressSync(profileSession: .owner)

    private unowned let profileSession: ProfileSession

    init(profileSession: ProfileSession) { self.profileSession = profileSession }

    private var lastFanOut: [String: Date] = [:]
    private let minInterval: TimeInterval = 15

    func fanOut(from book: Book, fraction rawFraction: Double, isFinished: Bool, force: Bool = false) async {
        guard profileSession.progress.syncProgressToServer else { return }
        let editionKey = WorkIdentity.editionKey(for: book)
        guard !editionKey.isEmpty else { return }

        let fraction = isFinished ? 1 : min(max(rawFraction, 0), 1)
        guard fraction > 0.001 else { return }

        if !force, let last = lastFanOut[editionKey], Date().timeIntervalSince(last) < minInterval { return }
        lastFanOut[editionKey] = Date()

        let siblings = await profileSession.bookStore.books(editionKey: editionKey)
            .filter { $0.stableId != book.stableId }
        let sourceIsDownloaded = book.mediaType == .audiobook && profileSession.localStorage.isAudiobookDownloaded(book)
        for sibling in siblings {
            guard profileSession.pendingSync.entries[book.stableId]?.downloadedBaseline == nil else { return }
            await applyAndPush(to: sibling, fraction: fraction, finished: isFinished, protectAudiobook: sourceIsDownloaded)
        }

    }

    private func applyAndPush(to target: Book, fraction: Double, finished: Bool, protectAudiobook: Bool) async {
        guard !target.hasEPUB3MediaOverlay else { return }
        let existing = WorkGrouping.progressFraction(target)
        guard finished || fraction > existing + 0.005 else { return }

        let duration = target.duration ?? 0
        if protectAudiobook, target.mediaType == .audiobook {
            let local = profileSession.bookProgress.loadProgress(for: target)
            let position = local?.progress ?? target.currentTime
            let updatedAt = local.map { Date(timeIntervalSince1970: $0.lastUpdated) }
                ?? (position > 0 || target.isFinished ? target.lastUpdate : .distantPast)
            profileSession.sync.protectDownloadedProgress(
                for: target, position: position, updatedAt: updatedAt, duration: duration
            )
        }
        var updated = target
        if target.mediaType == .ebook {
            updated.ebookProgress = finished ? 1 : fraction
        } else {
            updated.currentTime = finished ? duration : fraction * duration
        }
        updated.isFinished = finished
        updated.lastUpdate = Date()

        if updated.mediaType == .audiobook {
            profileSession.bookProgress.saveProgress(for: updated, progress: updated.currentTime, duration: duration)
        }
        await profileSession.bookStore.upsertBooks([updated])

        await profileSession.sync.pushProgress(
            book: updated,
            forceImmediate: true,
            domain: updated.mediaType == .ebook ? .ebook : .audiobook
        )
    }
}
