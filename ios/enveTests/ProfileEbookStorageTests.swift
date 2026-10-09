import Foundation
import Testing

@testable import enve

@MainActor
struct ProfileEbookStorageTests {
    @Test func ebookRootsPreserveOwnerLocationsAndSeparateProfileMedia() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ownerLocations = locations(FamilyProfile.ownerID, root: root)
        let childLocations = locations("child-one", root: root)
        let owner = try LocalEbookImporter(storage: ownerLocations)
        let child = try LocalEbookImporter(storage: childLocations)
        #expect(owner.serverEbooksRoot == ownerLocations.documentsDirectory.appendingPathComponent("Ebooks", isDirectory: true))
        #expect(owner.localEbooksRoot == ownerLocations.documentsDirectory.appendingPathComponent("Ebooks/local", isDirectory: true))
        #expect(child.serverEbooksRoot != owner.serverEbooksRoot)
        #expect(child.remoteReaderCacheRoot != owner.remoteReaderCacheRoot)
        #expect(child.streamedEpubCacheRoot != owner.streamedEpubCacheRoot)

        let ownerFile = owner.serverEbooksRoot.appendingPathComponent("42.epub")
        let childFile = child.serverEbooksRoot.appendingPathComponent("42.epub")
        try Data("owner ebook".utf8).write(to: ownerFile)
        #expect(child.persistedRemoteEbook(forBookId: "42") == nil)
        try Data("child ebook".utf8).write(to: childFile)
        #expect(owner.persistedRemoteEbook(forBookId: "42") == ownerFile)
        #expect(child.persistedRemoteEbook(forBookId: "42") == childFile)
        let reopened = try LocalEbookImporter(storage: childLocations)
        #expect(reopened.persistedRemoteEbook(forBookId: "42") == childFile)
        try reopened.deleteRemoteEbookArtifacts(forBookId: "42")
        #expect(child.persistedRemoteEbook(forBookId: "42") == nil)
        #expect(try Data(contentsOf: ownerFile) == Data("owner ebook".utf8))
    }

    @Test func cacheAndOfflinePersistenceKeepLateWritesInTheirCapturedProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try LocalEbookImporter(storage: locations(FamilyProfile.ownerID, root: root))
        let child = try LocalEbookImporter(storage: locations("child-one", root: root))
        let ownerBytes = Data("owner ebook".utf8)
        let childBytes = Data("child ebook".utf8)
        let ownerCache = try owner.cacheRemoteEbook(data: ownerBytes, preferredFilename: "book.epub", bookIdentifier: "42")
        let childCache = try child.cacheRemoteEbook(data: childBytes, preferredFilename: "book.epub", bookIdentifier: "42")
        let ownerFile = try owner.persistRemoteEbookForOffline(from: ownerCache, bookIdentifier: "42")
        let childFile = try child.persistRemoteEbookForOffline(from: childCache, bookIdentifier: "42")
        #expect(ownerFile != childFile)
        #expect(try Data(contentsOf: ownerFile) == ownerBytes)
        #expect(try Data(contentsOf: childFile) == childBytes)
        _ = try owner.cacheRemoteEbook(data: Data("late owner cache".utf8), preferredFilename: "book.epub", bookIdentifier: "42")
        #expect(child.cachedEbook(forBookId: "42") == childFile)
        #expect(try Data(contentsOf: childFile) == childBytes)
        try child.deleteRemoteEbookArtifacts(forBookId: "42")
        #expect(try Data(contentsOf: ownerFile) == ownerBytes)
    }

    @Test func childStoredPathsAndSymlinksCannotResolveAnotherProfilesEbook() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try LocalEbookImporter(storage: locations(FamilyProfile.ownerID, root: root))
        let child = try LocalEbookImporter(storage: locations("child-one", root: root))
        let ownerFile = owner.serverEbooksRoot.appendingPathComponent("42.epub")
        try Data("owner ebook".utf8).write(to: ownerFile)
        #expect(child.resolveExistingLocalEbookURL(ebookFileURL: ownerFile, filePath: ownerFile.path) == nil)
        let link = child.serverEbooksRoot.appendingPathComponent("42.epub")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: ownerFile)
        #expect(child.persistedRemoteEbook(forBookId: "42") == nil)
        #expect(child.resolveExistingLocalEbookURL(ebookFileURL: link, filePath: nil) == nil)
        try child.deleteRemoteEbookArtifacts(forBookId: "42")
        #expect(try Data(contentsOf: ownerFile) == Data("owner ebook".utf8))
    }

    @Test func readaloudConversionAndStreamCleanupUseCapturedProfilePaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try LocalEbookImporter(storage: locations(FamilyProfile.ownerID, root: root))
        let child = try LocalEbookImporter(storage: locations("child-one", root: root))
        let ownerReadaloud = owner.readaloudEpubURL(forBookId: "42")
        let childReadaloud = child.readaloudEpubURL(forBookId: "42")
        try Data("owner readaloud".utf8).write(to: ownerReadaloud)
        try Data("child readaloud".utf8).write(to: childReadaloud)
        child.removeReadaloudCache(forBookId: "42")
        #expect(child.cachedReadaloudEpub(forBookId: "42") == nil)
        #expect(owner.cachedReadaloudEpub(forBookId: "42") == ownerReadaloud)
        #expect(owner.convertedEpubURL(for: URL(fileURLWithPath: "/fixture/book.mobi")) != child.convertedEpubURL(for: URL(fileURLWithPath: "/fixture/book.mobi")))

        let ownerStream = owner.streamedEpubCacheRoot.appendingPathComponent("connection/book-42")
        let childStream = child.streamedEpubCacheRoot.appendingPathComponent("connection/book-42")
        try FileManager.default.createDirectory(at: ownerStream, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: childStream, withIntermediateDirectories: true)
        try child.deleteRemoteEbookArtifacts(forBookId: "42")
        #expect(FileManager.default.fileExists(atPath: ownerStream.path))
        #expect(!FileManager.default.fileExists(atPath: childStream.path))
    }

    @Test func blockedProfileEbookRootFailsWithoutOwnerFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ownerLocations = locations(FamilyProfile.ownerID, root: root)
        let owner = try LocalEbookImporter(storage: ownerLocations)
        let ownerFile = owner.serverEbooksRoot.appendingPathComponent("42.epub")
        try Data("owner ebook".utf8).write(to: ownerFile)
        let childLocations = locations("child-one", root: root)
        try FileManager.default.createDirectory(at: childLocations.documentsDirectory, withIntermediateDirectories: true)
        let blocker = childLocations.documentsDirectory.appendingPathComponent("Ebooks")
        try Data("blocked".utf8).write(to: blocker)
        #expect(throws: (any Error).self) { try LocalEbookImporter(storage: childLocations) }
        #expect(try Data(contentsOf: blocker) == Data("blocked".utf8))
        #expect(try Data(contentsOf: ownerFile) == Data("owner ebook".utf8))
    }

    private func locations(_ profileID: String, root: URL) -> ProfileStorageLocations {
        ProfileStorageLocations(
            profileID: profileID,
            documentsDirectory: root.appendingPathComponent("Documents"),
            applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
            cachesDirectory: root.appendingPathComponent("Caches"),
            legacyPlaybackStoreURL: root.appendingPathComponent("default.store")
        )
    }
}
