import Foundation
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
    }

    @Test func profileLocationsUseDurableIdentity() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let id = UUID().uuidString
        let first = locations(profileID: id, root: root)
        let second = locations(profileID: id, root: root)
        let owner = locations(profileID: FamilyProfile.ownerID, root: root)
        #expect(first.bookStoreURL == second.bookStoreURL)
        #expect(first.documentsDirectory != owner.documentsDirectory)
        #expect(first.applicationSupportDirectory != owner.applicationSupportDirectory)
        #expect(first.cachesDirectory != owner.cachesDirectory)
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

        await owner.repository.updateProgress(uniqueId: book.uniqueId, currentTime: 120, isFinished: false, lastUpdate: Date())
        #expect(await child.repository.book(uniqueId: book.uniqueId)?.currentTime == 0)
        await child.repository.updateProgress(uniqueId: book.uniqueId, currentTime: 30, isFinished: false, lastUpdate: Date())
        #expect(await owner.repository.book(uniqueId: book.uniqueId)?.currentTime == 120)
        #expect(await child.repository.book(uniqueId: book.uniqueId)?.currentTime == 30)
        #expect(owner.needsLegacyImport)
        #expect(!child.needsLegacyImport)

        let restoredChild = try BookStoreManager(storage: childLocations, defaults: childDefaults)
        #expect(await restoredChild.repository.book(uniqueId: book.uniqueId)?.title == "Child title")
        #expect(await restoredChild.repository.book(uniqueId: book.uniqueId)?.currentTime == 30)
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
        let book = Book(
            id: "42", title: "Preserved", source: .local,
            backendId: "account", providerId: UUID(), libraryId: "library"
        )
        await owner.runLegacyImportIfNeeded(allBooks: [book], hiddenStableIds: [], deletedStableIds: [])
        await owner.repository.updateProgress(uniqueId: book.uniqueId, currentTime: 90, isFinished: false, lastUpdate: Date())
        let childLocations = locations(profileID: UUID().uuidString, root: root)
        try FileManager.default.createDirectory(at: ownerLocations.applicationSupportDirectory, withIntermediateDirectories: true)
        try Data("blocked".utf8).write(
            to: ownerLocations.applicationSupportDirectory.appendingPathComponent("Profiles")
        )

        #expect(throws: (any Error).self) {
            try BookStoreManager(storage: childLocations, defaults: defaults)
        }
        #expect(!owner.needsLegacyImport)
        #expect(await owner.repository.book(uniqueId: book.uniqueId)?.title == "Preserved")
        #expect(await owner.repository.book(uniqueId: book.uniqueId)?.currentTime == 90)
        let restored = try BookStoreManager(storage: ownerLocations, defaults: defaults)
        #expect(await restored.repository.book(uniqueId: book.uniqueId)?.stableId == book.stableId)
    }

    private func locations(profileID: String, root: URL) -> ProfileStorageLocations {
        ProfileStorageLocations(
            profileID: profileID,
            documentsDirectory: root.appendingPathComponent("Documents", isDirectory: true),
            applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport", isDirectory: true),
            cachesDirectory: root.appendingPathComponent("Caches", isDirectory: true)
        )
    }
}
