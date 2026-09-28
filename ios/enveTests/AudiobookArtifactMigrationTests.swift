import Foundation
import SwiftData
import Testing

@testable import enve

@MainActor
struct AudiobookArtifactMigrationTests {
    private let originalId = "grimmory:grim:42"
    private let companionId = "grimmory:grim:grimmory-ab-42"

    @Test func bookStoreMigrationMergesDedupesAndRekeysAudiobookBookmarks() async throws {
        let store = try makeStore()
        let audio = Bookmark(id: "audio-mark", bookId: originalId, position: 90, title: "Audio", mediaType: .audiobook)
        let duplicate = Bookmark(id: "shared-mark", bookId: originalId, position: 120, title: "Shared", mediaType: .audiobook)
        let ebook = Bookmark(id: "ebook-mark", bookId: originalId, position: 0.4, title: "Ebook", mediaType: .ebook)
        await store.importLegacyBookmarks([audio, duplicate, ebook], bookStableId: originalId)
        let kept = Bookmark(id: "shared-mark", bookId: companionId, position: 121, title: "Kept", mediaType: .audiobook)
        await store.importLegacyBookmarks([kept], bookStableId: companionId)

        let migrated = await store.migrateAudiobookArtifacts(fromBookStableId: originalId, toBookStableId: companionId)

        #expect(migrated)
        let destination = await store.bookmarks(forBookStableId: companionId)
        #expect(Set(destination.map(\.id)) == ["audio-mark", "shared-mark"])
        #expect(destination.allSatisfy { $0.bookId == companionId && $0.mediaType == .audiobook })
        #expect(destination.first { $0.id == "shared-mark" }?.title == "Kept")
        #expect(await store.bookmarks(forBookStableId: originalId).map(\.id) == ["ebook-mark"])
    }

    @Test func bookStoreMigrationMovesTheChapterCacheOnlyIntoAnEmptyCompanion() async throws {
        let store = try makeStore()
        await store.cacheChapters([Chapter(id: "c1", start: 0, end: 60, title: "One", index: 0)], forBookStableId: originalId)

        await store.migrateAudiobookArtifacts(fromBookStableId: originalId, toBookStableId: companionId)

        #expect(await store.cachedChapters(forBookStableId: companionId)?.map(\.id) == ["c1"])
        #expect(await store.cachedChapters(forBookStableId: originalId) == nil)

        await store.cacheChapters([Chapter(id: "stale", start: 0, end: 30, title: "Stale", index: 0)], forBookStableId: originalId)
        await store.migrateAudiobookArtifacts(fromBookStableId: originalId, toBookStableId: companionId)

        #expect(await store.cachedChapters(forBookStableId: companionId)?.map(\.id) == ["c1"])
        #expect(await store.cachedChapters(forBookStableId: originalId) == nil)
    }

    @Test func progressMigrationPrefersTheNewestValueAndClearsTheSource() {
        let (defaults, suite) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let progressStore = BookProgressStore(defaults: defaults)
        let original = makeGrimmoryBook(id: "42", mediaType: .ebook)
        let companion = makeGrimmoryBook(id: "grimmory-ab-42", mediaType: .audiobook)

        progressStore.saveProgress(for: original, progress: 120, duration: 600, at: Date(timeIntervalSince1970: 1_000))
        progressStore.saveProgress(for: companion, progress: 300, duration: 600, at: Date(timeIntervalSince1970: 2_000))
        progressStore.saveServerStamp(for: original, Date(timeIntervalSince1970: 1_000))
        progressStore.migrateAudiobookArtifacts(fromStableId: original.stableId, to: companion)

        #expect(progressStore.loadProgress(bookId: companion.stableId)?.progress == 300)
        #expect(progressStore.loadProgress(bookId: original.stableId) == nil)
        #expect(progressStore.loadServerStamp(for: companion) == Date(timeIntervalSince1970: 1_000))
        #expect(progressStore.loadServerStamp(for: original) == nil)

        progressStore.saveProgress(for: original, progress: 480, duration: 600, at: Date(timeIntervalSince1970: 3_000))
        progressStore.migrateAudiobookArtifacts(fromStableId: original.stableId, to: companion)

        #expect(progressStore.loadProgress(bookId: companion.stableId)?.progress == 480)
        #expect(progressStore.loadProgress(bookId: original.stableId) == nil)
    }

    @Test func progressMigrationRewritesTheRecentlyPlayedSnapshotIdentity() throws {
        let (defaults, suite) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let progressStore = BookProgressStore(defaults: defaults)
        let original = makeGrimmoryBook(id: "42", mediaType: .ebook)
        let companion = makeGrimmoryBook(id: "grimmory-ab-42", mediaType: .audiobook)
        let snapshot = RecentlyPlayedSnapshot(stableId: original.stableId, book: original, lastUpdated: 1_000)
        defaults.set(try JSONEncoder().encode([snapshot]), forKey: "recentlyPlayedBooks")

        progressStore.migrateAudiobookArtifacts(fromStableId: original.stableId, to: companion)

        let snapshots = progressStore.loadSnapshots()
        #expect(snapshots.map(\.stableId) == [companion.stableId])
        #expect(snapshots.first?.book.id == companion.id)
        #expect(snapshots.first?.lastUpdated == 1_000)
    }

    @Test func legacyStoreMigrationMergesDedupesAndRekeysAudiobookBookmarks() {
        let (defaults, suite) = makeDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = ReaderArtifactsStore(defaults: defaults)
        let audio = Bookmark(id: "audio-mark", bookId: originalId, position: 90, title: "Audio", mediaType: .audiobook)
        let duplicate = Bookmark(id: "shared-mark", bookId: originalId, position: 120, title: "Shared", mediaType: .audiobook)
        let ebook = Bookmark(id: "ebook-mark", bookId: originalId, position: 0.4, title: "Ebook", mediaType: .ebook)
        store.saveBookmarks(bookId: originalId, bookmarks: [audio, duplicate, ebook])
        let kept = Bookmark(id: "shared-mark", bookId: companionId, position: 121, title: "Kept", mediaType: .audiobook)
        store.saveBookmarks(bookId: companionId, bookmarks: [kept])

        store.migrateAudiobookArtifacts(fromBookId: originalId, toBookId: companionId)

        let destination = store.loadBookmarks(bookId: companionId)
        #expect(destination.map(\.id) == ["shared-mark", "audio-mark"])
        #expect(destination.allSatisfy { $0.bookId == companionId && $0.mediaType == .audiobook })
        #expect(destination.first { $0.id == "shared-mark" }?.title == "Kept")
        #expect(store.loadBookmarks(bookId: originalId).map(\.id) == ["ebook-mark"])
    }

    private func makeStore() throws -> SwiftDataBookStore {
        let schema = Schema([
            BookRecord.self,
            MediaProgressRecord.self,
            LinkedBookPairRecord.self,
            BookmarkRecord.self,
            AnnotationRecord.self,
            ChapterCacheRecord.self,
        ])
        let config = ModelConfiguration(
            "AudiobookArtifactMigrationTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return SwiftDataBookStore(container: try ModelContainer(for: schema, configurations: [config]))
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "AudiobookArtifactMigrationTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func makeGrimmoryBook(id: String, mediaType: AppMediaType) -> Book {
        Book(
            id: id,
            title: "Grimmory \(id)",
            source: .booklore,
            backendId: "grim",
            mediaType: mediaType,
            providerId: UUID(uuidString: "2C1F5F1E-6C5B-4E3E-9C2A-9F52A0F6A222")!,
            libraryId: "library"
        )
    }
}
