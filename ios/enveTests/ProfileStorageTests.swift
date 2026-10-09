import Foundation
import SwiftData
import Testing

@testable import enve

@MainActor
struct ProfileStorageTests {
    @Test func ownerKeepsExistingDatabaseAndFileLocations() {
        let storage = ProfileStorageLocations.owner
        #expect(storage.profileID == FamilyProfile.ownerID)
        #expect(storage.documentsDirectory == URL.documentsDirectory)
        #expect(storage.applicationSupportDirectory == URL.applicationSupportDirectory)
        #expect(storage.cachesDirectory == URL.cachesDirectory)
        #expect(storage.bookStoreURL == URL.documentsDirectory.appendingPathComponent("BookStore.sqlite"))
        let schema = Schema([
            PlaybackState.self, AudiobookBookmark.self, MetadataOverride.self, SyncedPlaybackState.self,
        ])
        let legacy = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        #expect(storage.playbackStoreURL == legacy.url)
    }

    @Test func profileLocationsUseDurableIdentity() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let id = UUID().uuidString
        let first = locations(profileID: id, root: root)
        let second = locations(profileID: id, root: root)
        let owner = locations(profileID: FamilyProfile.ownerID, root: root)
        #expect(first.bookStoreURL == second.bookStoreURL)
        #expect(first.playbackStoreURL == second.playbackStoreURL)
        #expect(first.documentsDirectory != owner.documentsDirectory)
        #expect(first.applicationSupportDirectory != owner.applicationSupportDirectory)
        #expect(first.cachesDirectory != owner.cachesDirectory)
        #expect(first.bookStoreURL != first.playbackStoreURL)
    }

    @Test func profileDatabasesKeepIdenticalBooksAndPositionsIndependent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ownerDefaultsName = "com.enve.tests.profiles.owner.\(UUID().uuidString)"
        let childDefaultsName = "com.enve.tests.profiles.child.\(UUID().uuidString)"
        let ownerDefaults = try #require(UserDefaults(suiteName: ownerDefaultsName))
        let childDefaults = try #require(UserDefaults(suiteName: childDefaultsName))
        defer {
            try? FileManager.default.removeItem(at: root)
            ownerDefaults.removePersistentDomain(forName: ownerDefaultsName)
            childDefaults.removePersistentDomain(forName: childDefaultsName)
        }
        let ownerLocations = locations(profileID: FamilyProfile.ownerID, root: root)
        let childLocations = locations(profileID: UUID().uuidString, root: root)
        let owner = try BookStoreManager(storage: ownerLocations, defaults: ownerDefaults)
        let child = try BookStoreManager(storage: childLocations, defaults: childDefaults)
        let book = Book(
            id: "42", title: "Owner title", source: .local,
            backendId: "same-account", providerId: UUID(), libraryId: "library"
        )
        await owner.repository.upsertBooks([book])
        #expect(await child.repository.bookCount() == 0)
        var childBook = book
        childBook.title = "Child title"
        await child.repository.upsertBooks([childBook])
        #expect(await owner.repository.book(uniqueId: book.uniqueId)?.title == "Owner title")
        #expect(await child.repository.book(uniqueId: book.uniqueId)?.title == "Child title")
        #expect(await owner.repository.book(uniqueId: book.uniqueId)?.stableId == book.stableId)
        #expect(await child.repository.book(uniqueId: book.uniqueId)?.stableId == book.stableId)

        let ownerPlayback = try PlaybackStateManager(storage: ownerLocations)
        let childPlayback = try PlaybackStateManager(storage: childLocations)
        try ownerPlayback.savePlaybackState(bookId: "42", position: 120, speed: 1.25, chapterIndex: 2)
        #expect(try childPlayback.loadPlaybackState(for: "42").currentPosition == 0)
        try childPlayback.savePlaybackState(bookId: "42", position: 30, speed: 1, chapterIndex: 0)
        #expect(try ownerPlayback.loadPlaybackState(for: "42").currentPosition == 120)
        #expect(try childPlayback.loadPlaybackState(for: "42").currentPosition == 30)
        #expect(owner.needsLegacyImport)
        #expect(!child.needsLegacyImport)

        let restoredChild = try BookStoreManager(storage: childLocations, defaults: childDefaults)
        let restoredPlayback = try PlaybackStateManager(storage: childLocations)
        #expect(await restoredChild.repository.book(uniqueId: book.uniqueId)?.title == "Child title")
        #expect(try restoredPlayback.loadPlaybackState(for: "42").currentPosition == 30)
    }

    @Test func failedProfileOpenPreservesOwnerDatabasesAndMigrationFlags() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaultsName = "com.enve.tests.profiles.failure.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: defaultsName)
        }
        let ownerLocations = locations(profileID: FamilyProfile.ownerID, root: root)
        let owner = try BookStoreManager(storage: ownerLocations, defaults: defaults)
        let ownerPlayback = try PlaybackStateManager(storage: ownerLocations)
        let book = Book(
            id: "42", title: "Preserved", source: .local,
            backendId: "account", providerId: UUID(), libraryId: "library"
        )
        await owner.runLegacyImportIfNeeded(allBooks: [book], hiddenStableIds: [], deletedStableIds: [])
        try ownerPlayback.savePlaybackState(bookId: "42", position: 90, speed: 1, chapterIndex: 1)
        let childLocations = locations(profileID: UUID().uuidString, root: root)
        try Data("blocked".utf8).write(
            to: ownerLocations.applicationSupportDirectory.appendingPathComponent("Profiles")
        )

        #expect(throws: (any Error).self) {
            try BookStoreManager(storage: childLocations, defaults: defaults)
        }
        #expect(throws: (any Error).self) {
            try PlaybackStateManager(storage: childLocations)
        }
        #expect(!owner.needsLegacyImport)
        #expect(await owner.repository.book(uniqueId: book.uniqueId)?.title == "Preserved")
        #expect(try ownerPlayback.loadPlaybackState(for: "42").currentPosition == 90)
        let restored = try BookStoreManager(storage: ownerLocations, defaults: defaults)
        #expect(await restored.repository.book(uniqueId: book.uniqueId)?.stableId == book.stableId)
    }

    private func locations(profileID: String, root: URL) -> ProfileStorageLocations {
        ProfileStorageLocations(
            profileID: profileID,
            documentsDirectory: root.appendingPathComponent("Documents", isDirectory: true),
            applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport", isDirectory: true),
            cachesDirectory: root.appendingPathComponent("Caches", isDirectory: true),
            legacyPlaybackStoreURL: root.appendingPathComponent("ApplicationSupport/default.store")
        )
    }
}
