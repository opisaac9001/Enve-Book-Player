import Foundation
import Testing

@testable import enve

@MainActor
struct ProfileDownloadRuntimeTests {
    @Test func copiedDownloadsAndRetirementStayWithTheirCapturedStorage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstActivity = ProfileDownloadActivity()
        let secondActivity = ProfileDownloadActivity()
        let firstStorage = try LocalStorageManager(
            storage: locations(root: root), isDownloadActive: { firstActivity.isActive($0) }
        )
        let secondStorage = try LocalStorageManager(
            storage: locations(root: root), isDownloadActive: { secondActivity.isActive($0) }
        )
        let first = BookDownloadManager(storage: firstStorage, activity: firstActivity, clientCertificate: { _ in nil })
        let second = BookDownloadManager(storage: secondStorage, activity: secondActivity, clientCertificate: { _ in nil })
        let source = root.appendingPathComponent("source.m4b")
        let bytes = Data(repeating: 17, count: 8_192)
        try bytes.write(to: source)
        let bookID = "local:shared:book"
        await first.startFileCopyDownload(bookId: bookID, sourceURL: source)
        let firstFile = firstStorage.bookAudioDirectory(for: bookID).appendingPathComponent("chapter_0.m4b")
        let secondFile = secondStorage.bookAudioDirectory(for: bookID).appendingPathComponent("chapter_0.m4b")
        #expect(try Data(contentsOf: firstFile) == bytes)
        #expect(!FileManager.default.fileExists(atPath: secondFile.path))

        await first.retire()
        await first.startFileCopyDownload(bookId: "retired-job", sourceURL: source)
        #expect(!FileManager.default.fileExists(atPath: firstStorage.bookAudioDirectory(for: "retired-job").path))
        await second.startFileCopyDownload(bookId: bookID, sourceURL: source)
        #expect(try Data(contentsOf: secondFile) == bytes)
        #expect(first.completedBookIds == [bookID])
        #expect(second.completedBookIds == [bookID])
        await second.retire()
    }

    @Test func importedReadaloudResolvesOnlyItsCapturedSourceEbook() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = locations(root: root)
        let suite = "readaloud-profile-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let session = try ProfileSession(profile: FamilyProfile(id: storage.profileID, name: "Child", role: .child),
            storage: storage, defaults: defaults)
        let directory = session.ebooks.localEbooksRoot.appendingPathComponent("imported-ebook", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("book.epub")
        try Data([1, 2, 3]).write(to: file)
        let ebook = Book(id: "imported-ebook", title: "Readaloud", mediaType: .ebook, ebookFormat: "epub",
            ebookFileURL: file, libraryId: "profile-imports", providerId: UUID(), backendId: "profile-imports", source: .local)
        var audio = Book(id: "imported-audio", title: "Readaloud", backendId: "profile-imports", source: .local)
        audio.readAloudSourceStableId = ebook.stableId
        await session.bookStore.upsertBooks([ebook, audio])
        #expect(audio.hasEPUB3MediaOverlay)
        #expect(audio.ebookFileURL == nil)
        #expect(try await session.downloads.prepareReaderAsset(for: audio) == file)
        audio.readAloudSourceStableId = "missing-profile-source"
        do {
            _ = try await session.downloads.prepareReaderAsset(for: audio)
            Issue.record("Missing captured source must fail")
        } catch ProfileDownloadImportError.missingMedia {}
        await session.retire()
    }

    @Test func backgroundSessionIdentifiersRouteToTheOriginalProfile() {
        let profileID = UUID().uuidString
        let ownerID = UnifiedDownloadService.backgroundSessionIdentifier(for: FamilyProfile.ownerID)
        let childID = UnifiedDownloadService.backgroundSessionIdentifier(for: profileID)
        #expect(ownerID == "com.narrator.downloads")
        #expect(childID != ownerID)
        #expect(UnifiedDownloadService.profileID(forBackgroundSessionIdentifier: ownerID) == FamilyProfile.ownerID)
        #expect(UnifiedDownloadService.profileID(forBackgroundSessionIdentifier: childID) == profileID)
        #expect(UnifiedDownloadService.profileID(forBackgroundSessionIdentifier: "com.narrator.downloads.profile../owner") == nil)
        #expect(UnifiedDownloadService.profileID(forBackgroundSessionIdentifier: "unrelated-session") == nil)
    }

    private func locations(root: URL) -> ProfileStorageLocations {
        ProfileStorageLocations(
            profileID: UUID().uuidString,
            documentsDirectory: root.appendingPathComponent("Documents"),
            applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
            cachesDirectory: root.appendingPathComponent("Caches"),
            legacyPlaybackStoreURL: root.appendingPathComponent("default.store")
        )
    }
}
