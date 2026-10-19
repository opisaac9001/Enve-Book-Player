import Foundation
import SwiftData
import Testing

@testable import enve

@MainActor
struct ComicCatalogMigrationTests {
    @Test func versionOneStoreMigratesWithStateIntactAndAcceptsComicMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("BookStore.sqlite")
        let offlineFile = root.appendingPathComponent("issue-1.cbz")
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: offlineFile)

        let providerId = UUID()
        let uniqueId = "\(providerId)_issue-1"
        let stableId = "komga:\(providerId.uuidString):issue-1"
        let audiobookStableId = "audiobookshelf:server:audio-1"
        let locator = #"{"href":"page-12","locations":{"totalProgression":0.4}}"#
        let lastUpdate = Date(timeIntervalSince1970: 1_800_000_000)
        let syncedAt = Date(timeIntervalSince1970: 1_800_000_100)

        do {
            let schema = Schema(versionedSchema: BookStoreSchemaV1.self)
            let configuration = ModelConfiguration("BookStore", schema: schema, url: storeURL, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)

            let record = BookStoreSchemaV1.BookRecord()
            record.uniqueId = uniqueId
            record.stableId = stableId
            record.bookId = "issue-1"
            record.ratingKey = "issue-1"
            record.title = "Saga - 1"
            record.source = "komga"
            record.backendId = providerId.uuidString
            record.mediaType = "ebook"
            record.ebookFormat = "cbz"
            record.series = "Saga"
            record.seriesSequence = "1"
            record.providerId = providerId.uuidString
            record.libraryId = "comics"
            record.ebookProgress = 0.4
            record.epubLocator = locator
            record.lastUpdate = lastUpdate
            record.ebookFileURLPath = offlineFile.path
            context.insert(record)

            let hidden = BookStoreSchemaV1.BookRecord()
            hidden.uniqueId = "\(providerId)_issue-2"
            hidden.stableId = "komga:\(providerId.uuidString):issue-2"
            hidden.bookId = "issue-2"
            hidden.title = "Saga - 2"
            hidden.source = "komga"
            hidden.mediaType = "ebook"
            hidden.ebookFormat = "cbz"
            hidden.providerId = providerId.uuidString
            hidden.libraryId = "comics"
            hidden.isHidden = true
            context.insert(hidden)

            context.insert(MediaProgressRecord(
                bookUniqueId: uniqueId,
                stableId: stableId,
                currentTime: 0,
                duration: 0,
                ebookProgress: 0.4,
                epubLocator: locator,
                isFinished: false,
                lastUpdate: lastUpdate,
                hideFromContinue: false
            ))
            context.insert(LinkedBookPairRecord(ebookStableId: stableId, audiobookStableId: audiobookStableId, chapterOffset: 2))
            context.insert(BookmarkRecord(
                id: "bookmark-1",
                bookStableId: stableId,
                title: "Splash page",
                position: 12,
                timestamp: lastUpdate,
                note: "Keep",
                locator: locator,
                mediaType: "ebook",
                chapterTitle: nil,
                remoteID: nil,
                isRemotePlaceholder: false
            ))
            context.insert(LibrarySyncCursor(
                providerId: providerId.uuidString,
                libraryId: "comics",
                lastSyncedAt: syncedAt,
                lastFullReconciledAt: syncedAt
            ))
            try context.save()
        }
        _ = try BookStoreSQLTuner.apply(to: storeURL)

        let store = try openCurrentStore(at: storeURL)
        let migrated = try #require(await store.book(uniqueId: uniqueId))
        #expect(migrated.id == "issue-1")
        #expect(migrated.stableId == stableId)
        #expect(migrated.ebookProgress == 0.4)
        #expect(migrated.epubLocator == locator)
        #expect(migrated.lastUpdate == lastUpdate)
        #expect(migrated.ebookFileURL?.path == offlineFile.path)
        #expect(migrated.comicMetadata == nil)
        #expect(migrated.isComic)
        #expect(await store.bookCount() == 2)
        #expect(await store.allBookUniqueIds() == [uniqueId])

        let progress = try #require(await store.progress(forBookUniqueId: uniqueId))
        #expect(progress.ebookProgress == 0.4)
        #expect(progress.epubLocator == locator)
        #expect(await store.linkedAudiobookStableId(forEbookStableId: stableId) == audiobookStableId)
        #expect(await store.bookmarks(forBookStableId: stableId).map(\.id) == ["bookmark-1"])
        #expect(await store.loadCursor(providerId: providerId, libraryId: "comics")?.lastSyncedAt == syncedAt)

        let metadata = ComicMetadata(
            seriesID: "series-1",
            section: .volumes,
            volumeID: "volume-1",
            volumeTitle: "Volume 1",
            volumeOrder: 1,
            issueLabel: "Issue 1",
            issueOrder: 1
        )
        var refreshed = migrated
        refreshed.comicMetadata = metadata
        refreshed.ebookProgress = 0
        refreshed.epubLocator = nil
        refreshed.lastUpdate = .distantPast
        await store.upsertBooks([refreshed])

        let reopened = try openCurrentStore(at: storeURL)
        let restored = try #require(await reopened.book(uniqueId: uniqueId))
        #expect(restored.comicMetadata == metadata)
        #expect(restored.ebookProgress == 0.4)
        #expect(restored.epubLocator == locator)
        #expect(restored.ebookFileURL?.path == offlineFile.path)
        #expect(restored.id == migrated.id)
        #expect(restored.stableId == migrated.stableId)
    }

    private func openCurrentStore(at url: URL) throws -> SwiftDataBookStore {
        let schema = Schema(versionedSchema: BookStoreSchemaV2.self)
        let configuration = ModelConfiguration("BookStore", schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: BookStoreMigrationPlan.self,
            configurations: [configuration]
        )
        return SwiftDataBookStore(container: container)
    }
}
