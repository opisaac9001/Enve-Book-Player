import Foundation
import Testing
import Zip

@testable import enve

struct DownloadArchiveFileSystemTests {
    @Test func archiveSignaturesAreDetectedWithoutUsingFilenames() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let zip = directory.appendingPathComponent("payload.bin")
        let rar = directory.appendingPathComponent("other.bin")
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: zip)
        try Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]).write(to: rar)

        #expect(DownloadArchiveFileSystem.isZipFile(at: zip))
        #expect(DownloadArchiveFileSystem.isRarFile(at: rar))
        #expect(!DownloadArchiveFileSystem.isRarFile(at: zip))
    }

    @Test func zipExtractionKeepsOnlyAudioAndUsesStableChapterOrder() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input", isDirectory: true)
        let output = directory.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let second = input.appendingPathComponent("02-second.m4b")
        let first = input.appendingPathComponent("01-first.mp3")
        let ignored = input.appendingPathComponent("notes.txt")
        try Data([2]).write(to: second)
        try Data([1]).write(to: first)
        try Data("private title".utf8).write(to: ignored)
        let archive = directory.appendingPathComponent("book.zip")
        try Zip.zipFiles(paths: [second, ignored, first], zipFilePath: archive, password: nil, progress: nil)

        let extracted = try DownloadArchiveFileSystem.extractZip(at: archive, to: output)

        #expect(extracted.map(\.lastPathComponent) == ["chapter_0.mp3", "chapter_1.m4b"])
        #expect(try Data(contentsOf: extracted[0]) == Data([1]))
        #expect(try Data(contentsOf: extracted[1]) == Data([2]))
        #expect(!FileManager.default.fileExists(atPath: archive.path))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
                == ["chapter_0.mp3", "chapter_1.m4b"]
        )
    }

    @Test func stagedArchiveSurvivesDestinationRemovalUntilDiscarded() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bookDirectory = root.appendingPathComponent("book", isDirectory: true)
        try FileManager.default.createDirectory(at: bookDirectory, withIntermediateDirectories: true)
        let archive = bookDirectory.appendingPathComponent("chapter_0.rar")
        try Data([0xAA]).write(to: archive)

        let staged = try DownloadArchiveFileSystem.stageForDistribution(at: archive)
        try FileManager.default.removeItem(at: bookDirectory)

        #expect(try Data(contentsOf: staged.url) == Data([0xAA]))

        staged.discard()

        #expect(!FileManager.default.fileExists(atPath: staged.url.deletingLastPathComponent().path))
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
