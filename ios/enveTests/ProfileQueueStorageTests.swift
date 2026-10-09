import Foundation
import Testing

@testable import enve

@MainActor
struct ProfileQueueStorageTests {
    @Test func queuesKeepTheirCapturedProfileAfterOtherProfilesOpen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let owner = locations(FamilyProfile.ownerID, root: root)
        let child = locations(UUID().uuidString, root: root)
        let otherChild = locations(UUID().uuidString, root: root)
        let childDefaults = try child.openPreferences()
        let otherDefaults = try otherChild.openPreferences()
        defer {
            childDefaults.removePersistentDomain(forName: child.preferencesDomain!)
            otherDefaults.removePersistentDomain(forName: otherChild.preferencesDomain!)
            try? FileManager.default.removeItem(at: root)
        }

        let ownerPlayback = try PlaybackQueueStore(storage: owner)
        ownerPlayback.addLast(book("owner"))
        let childPlayback = try PlaybackQueueStore(storage: child)
        let otherPlayback = try PlaybackQueueStore(storage: otherChild)
        childPlayback.addLast(book("child-late-write"))
        otherPlayback.addLast(book("other-child"))
        #expect(try PlaybackQueueStore(storage: owner).entries.map(\.book.id) == ["owner"])
        #expect(try PlaybackQueueStore(storage: child).entries.map(\.book.id) == ["child-late-write"])
        #expect(try PlaybackQueueStore(storage: otherChild).entries.map(\.book.id) == ["other-child"])

        let childDownloads = try UnifiedDownloadQueueStore(storage: child)
        let otherDownloads = try UnifiedDownloadQueueStore(storage: otherChild)
        childDownloads.save([task("child")])
        otherDownloads.save([task("other")])
        #expect(try UnifiedDownloadQueueStore(storage: child).load().map(\.bookId) == ["child"])
        #expect(try UnifiedDownloadQueueStore(storage: otherChild).load().map(\.bookId) == ["other"])

        let ownerMetadata = try DownloadPersistence(storage: owner)
        let childMetadata = try DownloadPersistence(storage: child)
        let otherMetadata = try DownloadPersistence(storage: otherChild)
        try ownerMetadata.saveMetadataDownloadQueue(metadataQueue("owner"))
        try otherMetadata.saveMetadataDownloadQueue(metadataQueue("other"))
        try childMetadata.saveMetadataDownloadQueue(metadataQueue("child-late-write"))
        #expect(try DownloadPersistence(storage: owner).loadMetadataDownloadQueue().items.map(\.bookId) == ["owner"])
        #expect(try DownloadPersistence(storage: child).loadMetadataDownloadQueue().items.map(\.bookId) == ["child-late-write"])
        #expect(try DownloadPersistence(storage: otherChild).loadMetadataDownloadQueue().items.map(\.bookId) == ["other"])
    }

    @Test func corruptChildQueuesAreRejectedAndLateWritesPreserveTheirBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let child = locations(UUID().uuidString, root: root)
        let defaults = try child.openPreferences()
        defer {
            defaults.removePersistentDomain(forName: child.preferencesDomain!)
            try? FileManager.default.removeItem(at: root)
        }
        let downloads = try UnifiedDownloadQueueStore(storage: child)
        let metadata = try DownloadPersistence(storage: child)
        let playback = try PlaybackQueueStore(storage: child)
        let corrupt = Data("corrupt queue".utf8)
        let metadataURL = child.documentsDirectory.appendingPathComponent("DownloadQueues/metadata_downloads.json")
        let playbackURL = child.applicationSupportDirectory.appendingPathComponent("Enve/playback-queue.json")
        for file in [metadataURL, playbackURL] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try corrupt.write(to: file)
        }
        defaults.set(corrupt, forKey: "UnifiedDownloadQueue")

        #expect(throws: (any Error).self) { try UnifiedDownloadQueueStore(storage: child) }
        #expect(throws: (any Error).self) { try DownloadPersistence(storage: child) }
        #expect(throws: (any Error).self) { try PlaybackQueueStore(storage: child) }
        downloads.save([task("late")])
        #expect(throws: (any Error).self) { try metadata.saveMetadataDownloadQueue(metadataQueue("late")) }
        playback.addLast(book("late"))
        #expect(defaults.data(forKey: "UnifiedDownloadQueue") == corrupt)
        #expect(try Data(contentsOf: metadataURL) == corrupt)
        #expect(try Data(contentsOf: playbackURL) == corrupt)
    }

    private func locations(_ id: String, root: URL) -> ProfileStorageLocations {
        ProfileStorageLocations(
            profileID: id,
            documentsDirectory: root.appendingPathComponent("Documents"),
            applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
            cachesDirectory: root.appendingPathComponent("Caches"),
            legacyPlaybackStoreURL: root.appendingPathComponent("PlaybackState.store")
        )
    }

    private func book(_ id: String) -> Book {
        Book(id: id, title: id, duration: 600, providerId: UUID(), libraryId: "library")
    }

    private func task(_ id: String) -> BookDownloadTask {
        BookDownloadTask.create(bookId: id, title: id, source: .audiobookshelf)
    }

    private func metadataQueue(_ id: String) -> DownloadQueue {
        var queue = DownloadQueue()
        queue.addItem(.newBook(
            bookId: id,
            title: id,
            remoteURL: URL(string: "https://example.com/book")!,
            destinationPath: "book"
        ))
        return queue
    }
}
