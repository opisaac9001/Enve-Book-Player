import Foundation
import Testing
import UIKit

@testable import enve

@MainActor
struct ProfileMetadataStorageTests {
    @Test func metadataTitlesAndRemovalStayWithinCapturedRoots() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let owner = try MetadataStorage(storage: fixture.ownerStorage)
        let child = try MetadataStorage(storage: fixture.childStorage)
        let id = "same-book"
        try await owner.saveMetadata(BookMetadata(bookId: id, file: FileMetadataLayer(title: "Owner title")))
        #expect(try await child.loadMetadata(bookId: id) == nil)
        let delayed = Task {
            await Task.yield()
            try await owner.updateUserOverrides(bookId: id, overrides: UserOverridesLayer(customTitle: "Owner override"))
        }
        try await child.saveMetadata(BookMetadata(bookId: id, file: FileMetadataLayer(title: "Child title")))
        try await delayed.value
        let reopenedOwner = try MetadataStorage(storage: fixture.ownerStorage)
        let reopenedChild = try MetadataStorage(storage: fixture.childStorage)
        #expect(try await reopenedOwner.loadMetadata(bookId: id)?.file.title == "Owner title")
        #expect(try await reopenedOwner.loadMetadata(bookId: id)?.userOverrides?.customTitle == "Owner override")
        #expect(try await reopenedChild.loadMetadata(bookId: id)?.file.title == "Child title")
        #expect(await reopenedChild.bookIdsWithStoredMetadata() == [id])
        try await reopenedChild.clearAllMetadata()
        #expect(try await child.loadMetadata(bookId: id) == nil)
        #expect(try await owner.loadMetadata(bookId: id)?.file.title == "Owner title")
    }

    @Test func blockedChildMetadataRootFailsWithoutChangingOwner() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let owner = try MetadataStorage(storage: fixture.ownerStorage)
        try await owner.saveMetadata(BookMetadata(bookId: "same-book", file: FileMetadataLayer(title: "Owner")))
        let childDocuments = fixture.childStorage.documentsDirectory
        try FileManager.default.createDirectory(at: childDocuments, withIntermediateDirectories: true)
        try Data([1]).write(to: childDocuments.appendingPathComponent("Metadata"))
        #expect(throws: (any Error).self) {
            _ = try MetadataStorage(storage: fixture.childStorage)
        }
        #expect(try await owner.loadMetadata(bookId: "same-book")?.file.title == "Owner")
        #expect(try Data(contentsOf: childDocuments.appendingPathComponent("Metadata")) == Data([1]))
    }

    @Test func matchingQueuesReopenAndRemoveIndependently() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let owner = MatchQueueStorage(defaults: fixture.ownerDefaults)
        let child = MatchQueueStorage(defaults: fixture.childDefaults)
        let ownerEntry = MatchQueueEntry(
            id: "same-entry", bookId: "same-book", fileMetadata: FileMetadataLayer(title: "Owner"), matchCandidates: []
        )
        owner.addMatchQueueEntry(ownerEntry)
        #expect(child.readMatchQueue().entries.isEmpty)
        let childEntry = MatchQueueEntry(
            id: "same-entry", bookId: "same-book", fileMetadata: FileMetadataLayer(title: "Child"), matchCandidates: []
        )
        child.addMatchQueueEntry(childEntry)
        #expect(MatchQueueStorage(defaults: fixture.ownerDefaults).getPendingMatches() == [ownerEntry])
        #expect(MatchQueueStorage(defaults: fixture.childDefaults).getPendingMatches() == [childEntry])
        child.removeMatchQueueEntry(entryId: "same-entry")
        #expect(MatchQueueStorage(defaults: fixture.childDefaults).readMatchQueue().entries.isEmpty)
        #expect(owner.getPendingMatches() == [ownerEntry])
        child.addMatchQueueEntry(childEntry)
        child.clearPendingMatches()
        #expect(owner.getPendingMatches() == [ownerEntry])
    }

    @Test func appCacheCoverBytesRemainSeparateIncludingDelayedWritesAndCloudPreference() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let owner = AppCache(storage: fixture.ownerStorage, defaults: fixture.ownerDefaults)
        let child = AppCache(storage: fixture.childStorage, defaults: fixture.childDefaults)
        let book = Book(id: "same-book", title: "Book", backendId: "same-backend", source: .local)
        let delayed = Task {
            await Task.yield()
            await owner.setCoverData(Data([1, 2, 3]), for: book)
        }
        await child.setPreferredScope(.iCloudIfAvailable)
        await child.setCoverData(Data([4, 5, 6]), for: book)
        await delayed.value
        let reopenedOwner = AppCache(storage: fixture.ownerStorage, defaults: fixture.ownerDefaults)
        let reopenedChild = AppCache(storage: fixture.childStorage, defaults: fixture.childDefaults)
        #expect(await reopenedOwner.getCoverData(for: book) == Data([1, 2, 3]))
        #expect(await reopenedChild.getCoverData(for: book) == Data([4, 5, 6]))
        await reopenedChild.removeCoverData(for: book)
        #expect(await reopenedChild.getCoverData(for: book) == nil)
        #expect(await reopenedOwner.getCoverData(for: book) == Data([1, 2, 3]))
        await reopenedChild.setCoverData(Data([7]), for: book)
        await reopenedChild.clearActiveCaches()
        #expect(await reopenedChild.getCoverData(for: book) == nil)
        #expect(await reopenedOwner.getCoverData(for: book) == Data([1, 2, 3]))
        #expect(await reopenedOwner.activeCacheSizes().coversBytes > 0)
    }

    @Test func diskArtworkReopensWithoutSharingMemoryOrDelayedWrites() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let ownerRoot = fixture.ownerStorage.cachesDirectory.appendingPathComponent("BookCovers")
        let childRoot = fixture.childStorage.cachesDirectory.appendingPathComponent("BookCovers")
        let owner = DiskImageCache(cacheDirectory: ownerRoot)
        let child = DiskImageCache(cacheDirectory: childRoot)
        let url = try #require(URL(string: "https://example.invalid/same-cover"))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let ownerImage = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let childImage = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        owner.save(ownerImage, for: url)
        #expect(child.memoryImage(for: url) == nil)
        child.save(childImage, for: url)
        #expect(await owner.diskBytes() > 0)
        #expect(await child.diskBytes() > 0)
        let reopenedOwner = DiskImageCache(cacheDirectory: ownerRoot)
        let reopenedChild = DiskImageCache(cacheDirectory: childRoot)
        #expect(await reopenedOwner.image(for: url)?.size.width == 4)
        #expect(await reopenedChild.image(for: url)?.size.width == 8)
        child.save(childImage, for: url)
        child.removeImage(for: url)
        #expect(await child.diskBytes() == 0)
        #expect(await DiskImageCache(cacheDirectory: childRoot).image(for: url) == nil)
        #expect(await reopenedOwner.image(for: url) != nil)
        child.save(childImage, for: url)
        await child.clearAllCache()
        #expect(await child.diskBytes() == 0)
        #expect(await owner.diskBytes() > 0)
    }

    private struct Fixture {
        let root: URL
        let ownerName: String
        let childName: String
        let ownerDefaults: UserDefaults
        let childDefaults: UserDefaults
        let ownerStorage: ProfileStorageLocations
        let childStorage: ProfileStorageLocations

        init() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            root = fixtureRoot
            ownerName = "ProfileMetadataStorageTests.owner.\(UUID().uuidString)"
            childName = "ProfileMetadataStorageTests.child.\(UUID().uuidString)"
            ownerDefaults = try #require(UserDefaults(suiteName: ownerName))
            childDefaults = try #require(UserDefaults(suiteName: childName))
            func storage(_ id: String) -> ProfileStorageLocations {
                ProfileStorageLocations(
                    profileID: id, documentsDirectory: fixtureRoot.appendingPathComponent("Documents"),
                    applicationSupportDirectory: fixtureRoot.appendingPathComponent("ApplicationSupport"),
                    cachesDirectory: fixtureRoot.appendingPathComponent("Caches"),
                    legacyPlaybackStoreURL: fixtureRoot.appendingPathComponent("default.store")
                )
            }
            ownerStorage = storage(FamilyProfile.ownerID)
            childStorage = storage(UUID().uuidString)
        }

        func remove() {
            ownerDefaults.removePersistentDomain(forName: ownerName)
            childDefaults.removePersistentDomain(forName: childName)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
