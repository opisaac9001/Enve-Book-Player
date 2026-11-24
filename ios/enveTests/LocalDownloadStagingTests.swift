import Foundation
import Testing

@testable import enve

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct LocalDownloadStagingTests {
    @Test func completedCopyPublishesTheWholeFileWithoutStagingLeftovers() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("source.m4b")
        let bytes = Data((0..<300_000).map { UInt8($0 % 251) })
        try bytes.write(to: source)

        await fixture.manager.startFileCopyDownload(bookId: "local-book", sourceURL: source)

        let published = fixture.storage.bookAudioDirectory(for: "local-book").appendingPathComponent("chapter_0.m4b")
        #expect(try Data(contentsOf: published) == bytes)
        #expect(fixture.storage.isAudiobookDownloaded("local-book"))
        #expect(fixture.manager.completedBookIds.contains("local-book"))
        #expect(fixture.stagingDirectories().isEmpty)
        await fixture.manager.retire()
    }

    @Test func failedCopyLeavesNoPartialBookBehind() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let unreadable = fixture.root.appendingPathComponent("folder.m4b", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)

        await fixture.manager.startFileCopyDownload(bookId: "local-book", sourceURL: unreadable)

        #expect(!FileManager.default.fileExists(atPath: fixture.storage.bookAudioDirectory(for: "local-book").path))
        #expect(!fixture.storage.isAudiobookDownloaded("local-book"))
        #expect(fixture.manager.lastErrorByBookId["local-book"] != nil)
        #expect(fixture.stagingDirectories().isEmpty)
        await fixture.manager.retire()
    }

    @Test func failedReplacementKeepsThePreviousCompleteCopy() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let directory = fixture.storage.bookAudioDirectory(for: "local-book")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = Data(repeating: 0x07, count: 50_000)
        try previous.write(to: directory.appendingPathComponent("chapter_0.m4b"))
        let unreadable = fixture.root.appendingPathComponent("folder.m4b", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)

        await fixture.manager.startFileCopyDownload(bookId: "local-book", sourceURL: unreadable)

        #expect(try Data(contentsOf: directory.appendingPathComponent("chapter_0.m4b")) == previous)
        #expect(fixture.stagingDirectories().isEmpty)
        await fixture.manager.retire()
    }

    @Test func cancellationAfterAnEarlyChunkNeverExposesATruncatedFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("large.m4b")
        let size: UInt64 = 96 * 1_048_576
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: size)
        try handle.close()

        let manager = fixture.manager
        let copy = Task { await manager.startFileCopyDownload(bookId: "local-book", sourceURL: source) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while (manager.progressByBookId["local-book"] ?? 0) == 0, !manager.completedBookIds.contains("local-book") {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
        manager.cancelDownload(bookId: "local-book")
        await copy.value

        let published = fixture.storage.bookAudioDirectory(for: "local-book").appendingPathComponent("chapter_0.m4b")
        if FileManager.default.fileExists(atPath: published.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: published.path)
            #expect((attributes[.size] as? NSNumber)?.uint64Value == size)
        } else {
            #expect(!fixture.storage.isAudiobookDownloaded("local-book"))
        }
        #expect(fixture.stagingDirectories().isEmpty)
        await manager.retire()
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage: LocalStorageManager
        let manager: BookDownloadManager

        init() throws {
            let locations = ProfileStorageLocations(profileID: UUID().uuidString,
                documentsDirectory: root.appendingPathComponent("Documents"),
                applicationSupportDirectory: root.appendingPathComponent("Support"),
                cachesDirectory: root.appendingPathComponent("Caches"))
            let activity = ProfileDownloadActivity()
            storage = try LocalStorageManager(storage: locations, isDownloadActive: { activity.isActive($0) })
            manager = BookDownloadManager(storage: storage, activity: activity, clientCertificate: { _ in nil })
        }

        func stagingDirectories() -> [String] {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: storage.audiobooksDirectory.path)) ?? []
            return entries.filter { $0.hasPrefix(".enve-download-") }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
