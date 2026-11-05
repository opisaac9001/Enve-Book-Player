import Foundation
import Testing

@testable import enve

@MainActor
struct BookHTTPTransferStoreTests {
    @Test(arguments: [false, true])
    func corruptManifestIsPreservedWithoutBlockingFreshDownloads(validJSON: Bool) throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let transfer = try store.begin(bookID: "fixture-book", destination: fixture.destination, mode: .single, count: 1)
        let manifest = fixture.locations.applicationSupportDirectory.appendingPathComponent("Enve/Downloads/BookHTTPTransfers.json")
        let corrupt = try validJSON ? JSONEncoder().encode([transfer, transfer]) : Data("{".utf8)
        try corrupt.write(to: manifest)

        let reopened = fixture.store()
        #expect(reopened.all.isEmpty)
        let replacement = try reopened.begin(bookID: transfer.bookID, destination: fixture.destination, mode: .single, count: 1)
        #expect(replacement.attemptID != transfer.attemptID)
        let saved = try FileManager.default.contentsOfDirectory(at: manifest.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("BookHTTPTransfers.corrupt-") }
        #expect(saved.count == 1)
        #expect(try Data(contentsOf: #require(saved.first)) == corrupt)
        #expect(fixture.store().transfer(for: transfer.bookID)?.attemptID == replacement.attemptID)
    }

    @Test func roundTripKeepsOnlyIdentityAndCompletedParts() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let transfer = try store.begin(bookID: "fixture-book", destination: fixture.destination, mode: .multiTrack, count: 2)
        let directory = try store.directory(for: transfer)
        try Data(repeating: 1, count: 2048).write(to: directory.staging.appendingPathComponent("chapter_0.mp3"))
        _ = try store.completePart(bookID: transfer.bookID, attemptID: transfer.attemptID, index: 0, fileNames: ["chapter_0.mp3"])
        let reloaded = fixture.store()
        try reloaded.recover(liveTaskDescriptions: [transfer.taskDescription(for: 1)])
        let restored = try #require(reloaded.transfer(for: transfer.bookID))
        #expect(restored.outcome == .active)
        #expect(restored.parts[0].fileNames == ["chapter_0.mp3"])
        #expect(restored.parts[1].fileNames.isEmpty)
        let metadata = try Data(contentsOf: fixture.locations.applicationSupportDirectory.appendingPathComponent("Enve/Downloads/BookHTTPTransfers.json"))
        let text = try #require(String(data: metadata, encoding: .utf8))
        #expect(!text.contains("http"))
        #expect(!text.lowercased().contains("authorization"))
        #expect(!text.lowercased().contains("resumedata"))
    }

    @Test func missingNativeTaskBecomesPersistentInterruption() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let transfer = try store.begin(bookID: "fixture-book", destination: fixture.destination, mode: .single, count: 1)
        try store.recover(liveTaskDescriptions: [])
        #expect(fixture.store().transfer(for: transfer.bookID)?.failure == .interrupted)
        #expect(!FileManager.default.fileExists(atPath: try store.directory(for: transfer).staging.path))
        try store.acknowledge(bookID: transfer.bookID)
        #expect(fixture.store().all.isEmpty)
    }

    @Test func staleAttemptCannotCompleteReplacement() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let old = try store.begin(bookID: "fixture-book", destination: fixture.destination, mode: .single, count: 1)
        try store.cancel(bookID: old.bookID)
        let current = try store.begin(bookID: old.bookID, destination: fixture.destination, mode: .single, count: 1)
        let stale = try store.completePart(bookID: old.bookID, attemptID: old.attemptID, index: 0, fileNames: ["chapter_0.mp3"])
        #expect(stale?.attemptID == nil)
        #expect(store.transfer(for: old.bookID)?.attemptID == current.attemptID)
        #expect(store.transfer(for: old.bookID)?.parts[0].fileNames.isEmpty == true)
    }

    @Test func publishReplayNeverSwapsOldDirectoryBack() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: true)
        let old = Data("old-book".utf8)
        try old.write(to: fixture.destination.appendingPathComponent("chapter_0.mp3"))
        let store = fixture.store()
        let transfer = try store.begin(bookID: "fixture-book", destination: fixture.destination, mode: .single, count: 1)
        let directory = try store.directory(for: transfer)
        let new = Data(repeating: 2, count: 2048)
        try new.write(to: directory.staging.appendingPathComponent("chapter_0.mp3"))
        // Model termination after directory commit but before the terminal manifest write.
        try directory.publish()
        try store.recover(liveTaskDescriptions: [])
        #expect(store.transfer(for: transfer.bookID)?.outcome == .completed)
        try directory.publish()
        #expect(try Data(contentsOf: fixture.destination.appendingPathComponent("chapter_0.mp3")) == new)
        try store.acknowledge(bookID: transfer.bookID)
        #expect(try Data(contentsOf: fixture.destination.appendingPathComponent("chapter_0.mp3")) == new)
    }

    @Test func finalPartPersistsCompletionUntilAcknowledgement() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let transfer = try store.begin(bookID: "fixture-book", destination: fixture.destination, mode: .multiTrack, count: 2)
        let directory = try store.directory(for: transfer)
        for index in 0..<2 {
            let name = "chapter_\(index).mp3"
            try Data(repeating: UInt8(index), count: 2048).write(to: directory.staging.appendingPathComponent(name))
            _ = try store.completePart(bookID: transfer.bookID, attemptID: transfer.attemptID, index: index, fileNames: [name])
        }
        #expect(fixture.store().transfer(for: transfer.bookID)?.outcome == .completed)
        try store.recover(liveTaskDescriptions: [])
        #expect(store.transfer(for: transfer.bookID)?.outcome == .completed)
        #expect(!FileManager.default.fileExists(atPath: directory.staging.path))
        try store.acknowledge(bookID: transfer.bookID)
        #expect(fixture.store().all.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("chapter_1.mp3").path))
    }

    @Test func profilesKeepSeparateTransferManifests() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let owner = fixture.store()
        _ = try owner.begin(bookID: "same-book", destination: fixture.destination, mode: .single, count: 1)
        let childLocations = ProfileStorageLocations(profileID: "fixture-child", documentsDirectory: fixture.root,
            applicationSupportDirectory: fixture.root, cachesDirectory: fixture.root)
        let childAudio = childLocations.applicationSupportDirectory.appendingPathComponent("Audiobooks")
        let child = BookHTTPTransferStore(storage: childLocations, audioRoot: childAudio)
        #expect(child.all.isEmpty)
        let transfer = try child.begin(bookID: "same-book", destination: childAudio.appendingPathComponent("book"), mode: .single, count: 1)
        #expect(owner.transfer(for: transfer.bookID)?.attemptID != transfer.attemptID)
        #expect(BookDownloadManager.backgroundSessionIdentifier(for: FamilyProfile.ownerID) != BookDownloadManager.backgroundSessionIdentifier(for: childLocations.profileID))
        #expect(BookDownloadManager.profileID(forBackgroundSessionIdentifier: BookDownloadManager.backgroundSessionIdentifier(for: childLocations.profileID)) == childLocations.profileID)
        #expect(BookDownloadManager.profileID(forBackgroundSessionIdentifier: "com.enve.book-http../owner") == nil)
        #expect(BookDownloadManager.profileID(forBackgroundSessionIdentifier: "com.narrator.downloads") == nil)
    }

    @Test func authenticationFailureKeepsHTTPStatusAcrossRelaunch() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let transfer = try store.begin(bookID: "fixture-book", destination: fixture.destination, mode: .single, count: 1)
        _ = try store.fail(bookID: transfer.bookID, attemptID: transfer.attemptID, category: .invalidResponse, httpStatusCode: 401)
        let restored = try #require(fixture.store().transfer(for: transfer.bookID))
        #expect(restored.outcome == .failed)
        #expect(restored.httpStatusCode == 401)
        #expect(restored.failureMessage == "Download failed with HTTP status: 401")
        #expect(store.transfer(taskDescription: transfer.taskDescription(for: 0))?.0.attemptID == nil)
    }

    @Test func restorationMatchesOnlyIncompletePartsOfCurrentActiveAttempt() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let transfer = try store.begin(bookID: "fixture-book", destination: fixture.destination, mode: .multiTrack, count: 2)
        let directory = try store.directory(for: transfer)
        try Data(repeating: 1, count: 2048).write(to: directory.staging.appendingPathComponent("chapter_0.mp3"))
        _ = try store.completePart(bookID: transfer.bookID, attemptID: transfer.attemptID, index: 0, fileNames: ["chapter_0.mp3"])
        let reloaded = fixture.store()
        try reloaded.recover(liveTaskDescriptions: [transfer.taskDescription(for: 1)])
        #expect(reloaded.transfer(taskDescription: transfer.taskDescription(for: 0))?.0.attemptID == nil)
        #expect(reloaded.transfer(taskDescription: transfer.taskDescription(for: 1))?.0.attemptID == transfer.attemptID)
        #expect(reloaded.transfer(taskDescription: "unowned-task")?.0.attemptID == nil)
        try reloaded.cancel(bookID: transfer.bookID)
        #expect(reloaded.transfer(taskDescription: transfer.taskDescription(for: 1))?.0.attemptID == nil)
        let replacement = try reloaded.begin(bookID: transfer.bookID, destination: fixture.destination, mode: .single, count: 1)
        #expect(reloaded.transfer(taskDescription: transfer.taskDescription(for: 1))?.0.attemptID == nil)
        #expect(reloaded.transfer(taskDescription: replacement.taskDescription(for: 0))?.0.attemptID == replacement.attemptID)
    }

    @Test func failedManifestWriteStillRevokesCallbackOwnership() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let transfer = try store.begin(bookID: "fixture-book", destination: fixture.destination, mode: .single, count: 1)
        let metadata = fixture.locations.applicationSupportDirectory.appendingPathComponent("Enve/Downloads/BookHTTPTransfers.json")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try store.fail(bookID: transfer.bookID, attemptID: transfer.attemptID, category: .fileSystem)
        }
        #expect(store.transfer(for: transfer.bookID)?.outcome == .failed)
        #expect(store.transfer(taskDescription: transfer.taskDescription(for: 0)) == nil)
        #expect(!FileManager.default.fileExists(atPath: try store.directory(for: transfer).staging.path))
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var locations: ProfileStorageLocations {
            ProfileStorageLocations(profileID: FamilyProfile.ownerID, documentsDirectory: root,
                applicationSupportDirectory: root, cachesDirectory: root)
        }
        var audioRoot: URL { root.appendingPathComponent("Audiobooks") }
        var destination: URL { audioRoot.appendingPathComponent("book") }
        func store() -> BookHTTPTransferStore { BookHTTPTransferStore(storage: locations, audioRoot: audioRoot) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
