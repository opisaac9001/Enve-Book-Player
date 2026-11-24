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

        let book = Book(id: "42", title: "Book", source: .booklore, providerId: UUID())
        let ownerStream = owner.streamedEpubCacheRoot.appendingPathComponent("\(book.providerId)/book-42")
        let childStream = child.streamedEpubCacheRoot.appendingPathComponent("\(book.providerId)/book-42")
        try FileManager.default.createDirectory(at: ownerStream, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: childStream, withIntermediateDirectories: true)
        try child.deleteRemoteEbookArtifacts(for: book)
        #expect(FileManager.default.fileExists(atPath: ownerStream.path))
        #expect(!FileManager.default.fileExists(atPath: childStream.path))
    }

    @Test func equalProviderItemIDsKeepSeparateEbooksAcrossRestartAndDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = locations("reader", root: root)
        let importer = try LocalEbookImporter(storage: paths)
        let first = Book(id: "42", title: "Book", source: .kavita, providerId: UUID())
        let second = Book(id: "42", title: "Book", source: .kavita, providerId: UUID())
        for (book, value) in [(first, "first"), (second, "second")] {
            let cached = try importer.cacheRemoteEbook(data: Data(value.utf8), preferredFilename: "volume.epub", bookIdentifier: book.ebookStorageID)
            _ = try importer.persistRemoteEbookForOffline(from: cached, bookIdentifier: book.ebookStorageID)
        }
        let reopened = try LocalEbookImporter(storage: paths)
        let firstURL = try #require(reopened.offlineEbookURL(for: first))
        let secondURL = try #require(reopened.offlineEbookURL(for: second))
        #expect(try Data(contentsOf: firstURL) == Data("first".utf8))
        try reopened.deleteRemoteEbookArtifacts(for: first)
        #expect(reopened.cachedEbook(for: first) == nil)
        #expect(try Data(contentsOf: secondURL) == Data("second".utf8))
    }

    @Test func longUnicodeTitlesKeepTheirScopedPrefixAndFileExtension() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let importer = try LocalEbookImporter(storage: locations("reader", root: root))
        let book = Book(id: "42", title: "Volume", source: .kavita, providerId: UUID())
        let name = String(repeating: "東京Volume", count: 60) + ".epub"
        let url = try importer.cacheRemoteEbook(data: Data([1]), preferredFilename: name, bookIdentifier: book.ebookStorageID)
        #expect(url.lastPathComponent.utf8.count <= 255)
        #expect(url.pathExtension == "epub")
        #expect(importer.cachedEbook(for: book) == url)
    }

    @Test func legacyFileRequiresARecordedOwnerAndSurvivesWhileReferenced() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let importer = try LocalEbookImporter(storage: locations("reader", root: root))
        var owner = Book(id: "42", title: "Book", source: .kavita, providerId: UUID())
        var other = Book(id: "42", title: "Book", source: .kavita, filePath: "/server/books/42-book.epub", providerId: UUID())
        let legacy = importer.serverEbooksRoot.appendingPathComponent("42-book.epub")
        try Data("old download".utf8).write(to: legacy)
        owner.ebookFileURL = legacy
        #expect(importer.cachedEbook(for: owner) == legacy)
        #expect(importer.cachedEbook(for: other) == nil)
        #expect(importer.resolveExistingLocalEbookURL(for: other) == nil)
        other.ebookFileURL = legacy
        try importer.deleteRecordedLegacyEbook(for: owner, otherBooks: [owner, other])
        #expect(importer.cachedEbook(for: other) == legacy)
        try importer.deleteRecordedLegacyEbook(for: other, otherBooks: [other])
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
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
            cachesDirectory: root.appendingPathComponent("Caches")
        )
    }
}
