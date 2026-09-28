import Foundation
import Testing
import Zip

@testable import enve

@MainActor
struct StorytellerReadaloudCacheTests {
    @Test func textOnlyEbookIsNotAStorytellerOverlayCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ebook = root.appendingPathComponent("text.epub")
        try Data("text-only".utf8).write(to: ebook)
        var book = Book(
            id: UUID().uuidString,
            title: "Read-aloud cache test",
            mediaType: .ebook,
            libraryId: "library",
            providerId: UUID(),
            source: .storyteller
        )
        book.ebookFileURL = ebook
        book.epub3Features = EPUB3Features(hasMediaOverlay: true)

        #expect(LocalEbookImporter.shared.resolveEbookForOverlay(book: book) == nil)
        #expect(UnifiedDownloadService.shared.existingReaderAsset(for: book) == nil)

        var localBook = Book(
            id: UUID().uuidString,
            title: "Local overlay",
            mediaType: .ebook,
            libraryId: "library",
            providerId: UUID(),
            source: .local
        )
        localBook.ebookFileURL = ebook
        #expect(LocalEbookImporter.shared.resolveEbookForOverlay(book: localBook) == ebook)
    }

    @Test(arguments: [false, true])
    func readaloudRequiresBothOverlayAndAudio(includeAudio: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let smil = root.appendingPathComponent("chapter.smil")
        let audio = root.appendingPathComponent("chapter.mp3")
        try Data("<smil/>".utf8).write(to: smil)
        try Data([0xFF, 0xFB]).write(to: audio)
        let epub = root.appendingPathComponent("book.epub")
        try Zip.zipFiles(paths: includeAudio ? [smil, audio] : [smil], zipFilePath: epub, password: nil, progress: nil)

        if includeAudio {
            try await StorytellerReadaloudOfflinePrep.validate(epubURL: epub)
        } else {
            await #expect(throws: (any Error).self) {
                try await StorytellerReadaloudOfflinePrep.validate(epubURL: epub)
            }
        }
    }
}
