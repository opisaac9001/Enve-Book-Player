import Foundation
import ReadiumZIPFoundation
import Testing

@testable import enve

struct ComicArchiveDetectionTests {
    @Test func aComicSavedUnderAnEPUBNameIsRecognisedAsAComic() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let comic = try await zip(
            ["001.png": Data([0x89, 0x50, 0x4E, 0x47]), "002.png": Data([0x89, 0x50, 0x4E, 0x47])],
            named: "Issue.epub",
            in: root
        )
        let epub = try await zip(
            [
                "mimetype": Data("application/epub+zip".utf8),
                "META-INF/container.xml": Data("<container/>".utf8),
                "OEBPS/page.png": Data([0x89, 0x50, 0x4E, 0x47]),
            ],
            named: "Divina.epub",
            in: root
        )
        let service = ComicArchiveService(cachesDirectory: root)

        #expect(await service.isComicArchiveWithoutEPUBContainer(comic))
        #expect(!(await service.isComicArchiveWithoutEPUBContainer(epub)))
    }

    @Test func comicInfoMangaFlagSetsTheArchiveDirection() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        func comicInfo(_ manga: String) -> Data {
            Data("<?xml version=\"1.0\"?><ComicInfo><Title>Issue</Title><Manga>\(manga)</Manga><Notes>after</Notes></ComicInfo>".utf8)
        }
        let page = Data([0x89, 0x50, 0x4E, 0x47])
        let manga = try await zip(["001.png": page, "ComicInfo.xml": comicInfo("YesAndRightToLeft")], named: "Manga.cbz", in: root)
        let western = try await zip(["001.png": page, "ComicInfo.xml": comicInfo("No")], named: "Western.cbz", in: root)
        let bare = try await zip(["001.png": page], named: "Bare.cbz", in: root)
        let service = ComicArchiveService(cachesDirectory: root)

        #expect(await service.readingDirection(from: manga) == .rightToLeft)
        #expect(await service.readingDirection(from: western) == .leftToRight)
        #expect(await service.readingDirection(from: bare) == nil)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func zip(_ entries: [String: Data], named name: String, in root: URL) async throws -> URL {
        let contents = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        for (path, data) in entries {
            let url = contents.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let archive = root.appendingPathComponent(name)
        try await FileManager.default.zipItem(at: contents, to: archive, shouldKeepParent: false)
        return archive
    }
}
