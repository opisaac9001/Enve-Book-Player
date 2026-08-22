import Foundation
import Testing

@testable import enve

@MainActor
struct UnifiedDownloadQueueStoreTests {
    @Test func queueRoundTripsThroughStorage() throws {
        let suite = makeSuiteName()
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UnifiedDownloadQueueStore(defaults: defaults, key: "queue")

        var downloading = makeTask(bookId: "book-1", status: .downloading, updatedAt: Date())
        downloading.progress = 0.42
        downloading.bytesDownloaded = 4_200
        downloading.totalBytes = 10_000
        let failed = makeTask(
            bookId: "book-2",
            status: .failed,
            updatedAt: Date(),
            errorMessage: "Server returned error"
        )

        store.save([downloading, failed])
        let restored = store.load()

        #expect(restored.map(\.id) == [downloading.id, failed.id])
        #expect(restored[0].status == .downloading)
        #expect(restored[0].progress == 0.42)
        #expect(restored[0].bytesDownloaded == 4_200)
        #expect(restored[0].totalBytes == 10_000)
        #expect(restored[1].errorMessage == "Server returned error")
    }

    @Test func recoveryKeepsUnfinishedTasksAndDropsStaleFinishedOnes() throws {
        let suite = makeSuiteName()
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UnifiedDownloadQueueStore(defaults: defaults, key: "queue")

        let stale = Date().addingTimeInterval(-UnifiedDownloadQueueStore.finishedTaskRetention - 60)
        let recent = Date().addingTimeInterval(-60)
        store.save([
            makeTask(bookId: "stale-completed", status: .completed, updatedAt: stale),
            makeTask(bookId: "stale-cancelled", status: .cancelled, updatedAt: stale),
            makeTask(bookId: "stale-failed", status: .failed, updatedAt: stale),
            makeTask(bookId: "stale-queued", status: .queued, updatedAt: stale),
            makeTask(bookId: "stale-paused", status: .paused, updatedAt: stale),
            makeTask(bookId: "recent-completed", status: .completed, updatedAt: recent),
        ])

        let restored = store.load()

        #expect(restored.map(\.bookId) == ["stale-failed", "stale-queued", "stale-paused", "recent-completed"])
    }

    @Test func emptyAndUnreadableStorageLoadAnEmptyQueue() throws {
        let suite = makeSuiteName()
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UnifiedDownloadQueueStore(defaults: defaults, key: "queue")

        #expect(store.load().isEmpty)

        defaults.set(Data("not a queue".utf8), forKey: "queue")

        #expect(store.load().isEmpty)
    }

    private func makeSuiteName() -> String {
        "UnifiedDownloadQueueStoreTests.\(UUID().uuidString)"
    }

    private func makeTask(
        bookId: String,
        status: BookDownloadTask.DownloadStatus,
        updatedAt: Date,
        errorMessage: String? = nil
    ) -> BookDownloadTask {
        BookDownloadTask(
            id: UUID().uuidString,
            bookId: bookId,
            title: "Task \(bookId)",
            source: .audiobookshelf,
            status: status,
            progress: 0,
            bytesDownloaded: 0,
            totalBytes: 0,
            errorMessage: errorMessage,
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }
}
