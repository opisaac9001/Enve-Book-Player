import Foundation
import Testing

@testable import enve

@MainActor
struct PlaybackHistoryStoreTests {
    @Test func retentionKeepsTheNewestTwoHundredFromTheLastWeek() async {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let clock = TestClock()
        let store = PlaybackHistoryStore(fileURL: url, writeDelay: .zero, now: { clock.date })

        for index in 0..<205 {
            store.record(.playbackStarted, bookStableId: "book-\(index)", title: "Book \(index)")
            clock.advance(60)
        }
        #expect(store.entries.count == PlaybackHistoryStore.maximumEntries)
        #expect(store.entries.first?.bookStableId == "book-204")
        #expect(store.entries.last?.bookStableId == "book-5")

        clock.advance(PlaybackHistoryStore.retention - 205 * 60 + 330)
        store.record(.progressSynced, bookStableId: "fresh", title: "Fresh")
        #expect(!store.entries.contains { $0.bookStableId == "book-5" })
        #expect(store.entries.contains { $0.bookStableId == "book-6" })
        #expect(store.entries.first?.bookStableId == "fresh")

        await store.flush()
        clock.advance(PlaybackHistoryStore.retention + 1)
        let reloaded = PlaybackHistoryStore(fileURL: url, writeDelay: .zero, now: { clock.date })
        #expect(reloaded.entries.isEmpty)
    }

    @Test func recurringIdenticalEventsFoldIntoOneRow() {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let clock = TestClock()
        let store = PlaybackHistoryStore(fileURL: url, writeDelay: .zero, now: { clock.date })

        store.record(.progressSynced, bookStableId: "a", title: "A")
        clock.advance(120)
        store.record(.syncQueued, bookStableId: "a", title: "A")
        clock.advance(120)
        store.record(.progressSynced, bookStableId: "a", title: "A")
        let foldedAt = clock.date
        clock.advance(1)
        store.record(.progressSynced, bookStableId: "b", title: "B")

        #expect(store.entries.map(\.kind) == [.progressSynced, .progressSynced, .syncQueued])
        #expect(store.entries.map(\.bookStableId) == ["b", "a", "a"])
        #expect(store.entries[1].repeatCount == 2)
        #expect(store.entries[1].occurredAt == foldedAt)

        clock.advance(PlaybackHistoryStore.repeatWindow + 1)
        store.record(.progressSynced, bookStableId: "a", title: "A")
        #expect(store.entries.filter { $0.bookStableId == "a" && $0.kind == .progressSynced }.count == 2)
    }

    @Test func entriesSurviveReload() async {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let clock = TestClock()
        let store = PlaybackHistoryStore(fileURL: url, writeDelay: .seconds(60), now: { clock.date })

        store.record(.conflictDetected, bookStableId: "a", title: "A", detail: .positions(local: 65, server: 3_725))
        clock.advance(1)
        store.record(.playbackFailed, bookStableId: "b", title: "B")
        await store.flush()

        let reloaded = PlaybackHistoryStore(fileURL: url, now: { clock.date })
        #expect(reloaded.entries == store.entries)
        #expect(reloaded.entries.last?.summary == "This device 1:05 · Server 1:02:05")
    }

    @Test func profilesKeepSeparateHistories() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = locations(FamilyProfile.ownerID, root: root)
        let child = locations(UUID().uuidString, root: root)

        let ownerStore = PlaybackHistoryStore(storage: owner)
        let childStore = PlaybackHistoryStore(storage: child)
        ownerStore.record(.progressSynced, bookStableId: "shared-id", title: "Owner book")
        childStore.record(.playbackFailed, bookStableId: "shared-id", title: "Child book")
        await ownerStore.flush()
        await childStore.flush()

        #expect(PlaybackHistoryStore(storage: owner).entries.map(\.bookTitle) == ["Owner book"])
        #expect(PlaybackHistoryStore(storage: child).entries.map(\.bookTitle) == ["Child book"])

        childStore.clear()
        await childStore.flush()
        #expect(PlaybackHistoryStore(storage: child).entries.isEmpty)
        #expect(PlaybackHistoryStore(storage: owner).entries.count == 1)
    }

    @Test func syncEventsMapOnlyToClaimsTheEventSupports() {
        #expect(PlaybackHistoryStore.content(for: .pullStarted(bookId: "a")) == nil)
        #expect(PlaybackHistoryStore.content(for: .pushStarted(bookId: "a")) == nil)
        #expect(PlaybackHistoryStore.content(for: .pullCompleted(bookId: "a", applied: false)) == nil)
        #expect(PlaybackHistoryStore.content(for: .pullCompleted(bookId: "a", applied: true))?.kind == .remoteProgressApplied)
        #expect(PlaybackHistoryStore.content(for: .pullFailed(bookId: "a", error: "x"))?.kind == .progressCheckFailed)
        #expect(PlaybackHistoryStore.content(for: .pushCompleted(bookId: "a"))?.kind == .progressSynced)
        #expect(PlaybackHistoryStore.content(for: .pushFailed(bookId: "a", error: "x", retryable: true))?.kind == .syncQueued)
        #expect(PlaybackHistoryStore.content(for: .pushFailed(bookId: "a", error: "x", retryable: false))?.kind == .syncFailed)

        let conflict = PlaybackHistoryStore.content(
            for: .conflictDetected(bookId: "a", localProgress: 0.42, remoteProgress: 0.574, remoteSource: "Server")
        )
        #expect(conflict?.kind == .conflictDetected)
        #expect(conflict?.detail == .progress(local: 0.42, remote: 0.574))
    }

    @Test func rawErrorTextIsNeverPersisted() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = PlaybackHistoryStore(fileURL: url, writeDelay: .zero)
        let book = Book(id: "item", title: "  The Long Way  ", duration: 600, providerId: UUID(), libraryId: "library")
        let leakingError = "https://192.168.1.20:13378/api/items?token=secret-token"

        store.record(.pushFailed(bookId: book.stableId, error: leakingError, retryable: true), book: book)
        store.record(.pullFailed(bookId: book.stableId, error: leakingError), book: book)
        await store.flush()

        let stored = try String(contentsOf: url, encoding: .utf8)
        #expect(!stored.contains("secret-token"))
        #expect(!stored.contains("192.168.1.20"))
        #expect(store.entries.map(\.bookTitle) == ["The Long Way", "The Long Way"])
        #expect(store.entries.allSatisfy { $0.bookStableId == book.stableId })
        #expect(store.entries.compactMap(\.summary).allSatisfy { !$0.contains("secret") })
    }

    @Test func titlesAreBoundedAndBlankTitlesAreLabelled() {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let clock = TestClock()
        let store = PlaybackHistoryStore(fileURL: url, writeDelay: .zero, now: { clock.date })

        store.record(.playbackStarted, bookStableId: "long", title: String(repeating: "a", count: 500))
        clock.advance(1)
        store.record(.playbackStarted, bookStableId: "blank", title: " \n ")

        #expect(store.entries[0].bookTitle == "Untitled")
        #expect(store.entries[1].bookTitle.count == PlaybackHistoryStore.maximumTitleLength)
    }

    @Test func clearingOneBookLeavesOthers() async {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = PlaybackHistoryStore(fileURL: url, writeDelay: .zero)

        store.record(.playbackStarted, bookStableId: "a", title: "A")
        store.record(.progressSynced, bookStableId: "b", title: "B")
        store.clear(bookStableId: "a")
        await store.flush()

        #expect(PlaybackHistoryStore(fileURL: url).entries.map(\.bookStableId) == ["b"])
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("playback-history.json")
    }

    private func locations(_ id: String, root: URL) -> ProfileStorageLocations {
        ProfileStorageLocations(
            profileID: id,
            documentsDirectory: root.appendingPathComponent("Documents"),
            applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
            cachesDirectory: root.appendingPathComponent("Caches")
        )
    }
}

@MainActor
private final class TestClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)

    func advance(_ seconds: TimeInterval) {
        date = date.addingTimeInterval(seconds)
    }
}
