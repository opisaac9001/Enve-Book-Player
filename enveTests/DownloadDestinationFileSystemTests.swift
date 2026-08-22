import Foundation
import Testing

@testable import enve

struct DownloadDestinationFileSystemTests {
    @Test func bookDirectorySanitizesPathUnsafeIdentifiersUnderTheAudiobooksRoot() {
        let root = URL(fileURLWithPath: "/tmp/audiobooks", isDirectory: true)
        let destinations = DownloadDestinationFileSystem(audiobooksRoot: root)

        let directory = destinations.bookDirectory(for: "abs:lib/1?a&b=c\\d")

        #expect(directory.lastPathComponent == "abs-lib-1-a-b-c-d")
        #expect(directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
    }

    @Test func chapterFilesFollowTheDownloadedAudioLayout() {
        let directory = URL(fileURLWithPath: "/tmp/book", isDirectory: true)

        #expect(
            DownloadDestinationFileSystem.chapterFile(in: directory, index: 0, fileExtension: "m4b")
                .lastPathComponent == "chapter_0.m4b"
        )
        #expect(
            DownloadDestinationFileSystem.chapterFile(in: directory, index: 12, fileExtension: "mp3")
                .lastPathComponent == "chapter_12.mp3"
        )
    }

    @Test func prepareBookDirectoryCreatesTheDestinationAndToleratesRepeatedCalls() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destinations = DownloadDestinationFileSystem(audiobooksRoot: root)

        let created = try destinations.prepareBookDirectory(for: "book:1")
        try destinations.prepareBookDirectory(for: "book:1")

        #expect(created == destinations.bookDirectory(for: "book:1"))
        #expect(FileManager.default.fileExists(atPath: created.path))
    }

    @Test func replaceItemOverwritesTheDestinationAndConsumesTheSource() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destinations = DownloadDestinationFileSystem(audiobooksRoot: root)
        let directory = try destinations.prepareBookDirectory(for: "book:1")
        let destination = DownloadDestinationFileSystem.chapterFile(in: directory, index: 0, fileExtension: "m4b")
        try Data([0xAA]).write(to: destination)
        let source = directory.appendingPathComponent("incoming.tmp")
        try Data([0xBB]).write(to: source)

        try DownloadDestinationFileSystem.replaceItem(at: destination, with: source)

        #expect(try Data(contentsOf: destination) == Data([0xBB]))
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test func removeBookDirectoryReportsWhetherPartialFilesExisted() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destinations = DownloadDestinationFileSystem(audiobooksRoot: root)
        let directory = try destinations.prepareBookDirectory(for: "book:1")
        try Data([0xAA]).write(to: directory.appendingPathComponent("chapter_0.m4b"))

        let removedExisting = try destinations.removeBookDirectory(for: "book:1")
        let removedMissing = try destinations.removeBookDirectory(for: "book:1")

        #expect(removedExisting)
        #expect(!removedMissing)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
