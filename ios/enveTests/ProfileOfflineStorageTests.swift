import Foundation
import Testing

@testable import enve

@MainActor
struct ProfileOfflineStorageTests {
    @Test func invalidBookPathComponentsCannotResolveToAProfileRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try LocalStorageManager(
            storage: locations(profileID: UUID().uuidString, root: root), isDownloadActive: { _ in false }
        )
        for id in ["", ".", "..", "../../owner"] {
            let directory = manager.bookAudioDirectory(for: id).standardizedFileURL
            #expect(directory.deletingLastPathComponent().path == manager.audiobooksDirectory.standardizedFileURL.path)
            #expect(directory != manager.audiobooksDirectory)
        }
    }

    @Test func identicalMediaNamesStayIndependentAndChildDeletionPreservesOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try LocalStorageManager(
            storage: locations(profileID: FamilyProfile.ownerID, root: root), isDownloadActive: { _ in false }
        )
        let child = try LocalStorageManager(
            storage: locations(profileID: UUID().uuidString, root: root), isDownloadActive: { _ in false }
        )
        let ownerBytes = Data(repeating: 0x11, count: 120_000)
        let childBytes = Data(repeating: 0x22, count: 130_000)
        let ownerFile = try writeMedia(bytes: ownerBytes, bookID: "42", storage: owner)
        #expect(owner.downloadedAudiobookIds() == ["42"])
        #expect(child.downloadedAudiobookIds().isEmpty)
        let childFile = try writeMedia(bytes: childBytes, bookID: "42", storage: child)
        child.invalidateDownloadedIdsCache()

        #expect(ownerFile.lastPathComponent == childFile.lastPathComponent)
        #expect(ownerFile != childFile)
        #expect(try Data(contentsOf: ownerFile) == ownerBytes)
        #expect(try Data(contentsOf: childFile) == childBytes)
        #expect(owner.localAudiobookFilesIfExists(bookId: "42") == [ownerFile])
        #expect(child.localAudiobookFilesIfExists(bookId: "42") == [childFile])
        #expect(owner.isAudiobookDownloaded("42"))
        #expect(child.isAudiobookDownloaded("42"))
        #expect(owner.sizeOfAudiobook("42") == Int64(ownerBytes.count))
        #expect(child.sizeOfAudiobook("42") == Int64(childBytes.count))

        try owner.saveMetadataOverride(["title": "Owner"], for: "42")
        try child.saveMetadataOverride(["title": "Child"], for: "42")
        try owner.savePlaybackState(["position": 100], for: "42")
        try child.savePlaybackState(["position": 25], for: "42")
        let ownerCover = try owner.saveCoverOverride(for: "42", imageData: ownerBytes)
        let childCover = try child.saveCoverOverride(for: "42", imageData: childBytes)
        #expect(try owner.loadMetadataOverride([String: String].self, for: "42")["title"] == "Owner")
        #expect(try child.loadMetadataOverride([String: String].self, for: "42")["title"] == "Child")
        #expect(try owner.loadPlaybackState([String: Int].self, for: "42")["position"] == 100)
        #expect(try child.loadPlaybackState([String: Int].self, for: "42")["position"] == 25)
        #expect(ownerCover != childCover)
        #expect(try Data(contentsOf: ownerCover) == ownerBytes)
        #expect(try Data(contentsOf: childCover) == childBytes)

        try child.deleteDownloadedAudiobook("42")
        #expect(child.localAudiobookFilesIfExists(bookId: "42") == nil)
        #expect(child.downloadedAudiobookIds().isEmpty)
        #expect(owner.downloadedAudiobookIds() == ["42"])
        #expect(try Data(contentsOf: ownerFile) == ownerBytes)
        #expect(!child.deleteAudiobook("42"))
        #expect(try Data(contentsOf: ownerFile) == ownerBytes)
    }

    @Test func ownerRetainsLegacyAudioFallbackAndChildDoesNotScanIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ownerLocations = locations(profileID: FamilyProfile.ownerID, root: root)
        let owner = try LocalStorageManager(storage: ownerLocations, isDownloadActive: { _ in false })
        let childLocations = locations(profileID: UUID().uuidString, root: root)
        let child = try LocalStorageManager(storage: childLocations, isDownloadActive: { _ in false })
        let bytes = Data(repeating: 0x33, count: 120_000)
        let legacyOwnerDirectory = ownerLocations.documentsDirectory.appendingPathComponent("Enve/Audiobooks/42")
        try FileManager.default.createDirectory(at: legacyOwnerDirectory, withIntermediateDirectories: true)
        let legacyOwnerFile = legacyOwnerDirectory.appendingPathComponent("chapter_0.m4b")
        try bytes.write(to: legacyOwnerFile)
        let legacyChildDirectory = childLocations.documentsDirectory.appendingPathComponent("Enve/Audiobooks/42")
        try FileManager.default.createDirectory(at: legacyChildDirectory, withIntermediateDirectories: true)
        let legacyChildFile = legacyChildDirectory.appendingPathComponent("chapter_0.m4b")
        try bytes.write(to: legacyChildFile)

        #expect(owner.audiobooksDirectory == ownerLocations.applicationSupportDirectory.appendingPathComponent("Enve/Audiobooks", isDirectory: true))
        #expect(owner.localAudiobookFilesIfExists(bookId: "42") == [legacyOwnerFile])
        #expect(child.localAudiobookFilesIfExists(bookId: "42") == nil)
        #expect(child.downloadedAudiobookIds().isEmpty)
        try child.deleteDownloadedAudiobook("42")
        #expect(try Data(contentsOf: legacyOwnerFile) == bytes)
        #expect(try Data(contentsOf: legacyChildFile) == bytes)
    }

    @Test func blockedChildRootThrowsWithoutUsingOwnerMedia() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ownerLocations = locations(profileID: FamilyProfile.ownerID, root: root)
        let owner = try LocalStorageManager(storage: ownerLocations, isDownloadActive: { _ in false })
        let bytes = Data(repeating: 0x44, count: 120_000)
        let ownerFile = try writeMedia(bytes: bytes, bookID: "42", storage: owner)
        let blocker = ownerLocations.applicationSupportDirectory.appendingPathComponent("Profiles")
        let blockedBytes = Data("blocked".utf8)
        try blockedBytes.write(to: blocker)
        let childLocations = locations(profileID: UUID().uuidString, root: root)

        #expect(throws: (any Error).self) {
            try LocalStorageManager(storage: childLocations, isDownloadActive: { _ in false })
        }
        #expect(try Data(contentsOf: blocker) == blockedBytes)
        #expect(try Data(contentsOf: ownerFile) == bytes)
        #expect(owner.localAudiobookFilesIfExists(bookId: "42") == [ownerFile])
    }

    private func writeMedia(bytes: Data, bookID: String, storage: LocalStorageManager) throws -> URL {
        let directory = storage.bookAudioDirectory(for: bookID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("chapter_0.m4b")
        try bytes.write(to: file)
        return file
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
