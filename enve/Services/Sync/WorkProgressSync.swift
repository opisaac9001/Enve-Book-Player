import Foundation

@MainActor
final class WorkProgressSync {
    static let shared = WorkProgressSync()

    private init() {}

    private var lastFanOut: [String: Date] = [:]
    private let minInterval: TimeInterval = 15

    func fanOut(from book: Book, fraction rawFraction: Double, isFinished: Bool, force: Bool = false) async {
        guard UserProgressStore.shared.syncProgressToServer else { return }
        let editionKey = WorkIdentity.editionKey(for: book)
        guard !editionKey.isEmpty else { return }

        let fraction = isFinished ? 1 : min(max(rawFraction, 0), 1)
        guard fraction > 0.001 else { return }

        if !force, let last = lastFanOut[editionKey], Date().timeIntervalSince(last) < minInterval { return }
        lastFanOut[editionKey] = Date()

        let siblings = await AppState.shared.bookStore.books(editionKey: editionKey)
            .filter { $0.stableId != book.stableId }
        for sibling in siblings {
            await applyAndPush(to: sibling, fraction: fraction, finished: isFinished)
        }

    }

    private func applyAndPush(to target: Book, fraction: Double, finished: Bool) async {
        guard !target.hasEPUB3MediaOverlay else { return }
        let existing = WorkGrouping.progressFraction(target)
        guard finished || fraction > existing + 0.005 else { return }

        let duration = target.duration ?? 0
        var updated = target
        if target.mediaType == .ebook {
            updated.ebookProgress = finished ? 1 : fraction
        } else {
            updated.currentTime = finished ? duration : fraction * duration
        }
        updated.isFinished = finished
        updated.lastUpdate = Date()

        if updated.mediaType == .audiobook {
            BookProgressStore.shared.saveProgress(for: updated, progress: updated.currentTime, duration: duration)
        }
        await AppState.shared.bookStore.upsertBooks([updated])

        await SyncCoordinator.shared.pushProgress(
            book: updated,
            forceImmediate: true,
            domain: updated.mediaType == .ebook ? .ebook : .audiobook
        )
    }
}
