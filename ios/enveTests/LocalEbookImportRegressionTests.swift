import Foundation
import ReadiumZIPFoundation
import Testing

@testable import enve

@MainActor
struct LocalEbookImportRegressionTests {
    @Test func nativeSidecarMetadataIsNotMisclassifiedAsAudible() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let sidecar = LocalBookSidecar(
            metadata: LocalBookMetadata(
                title: "One Dark Window",
                author: "Rachel Gillig",
                epub3Features: EPUB3Features(hasMediaOverlay: true, smilFileCount: 36)
            ),
            fileHash: "content-hash",
            fileName: "One Dark Window.epub",
            format: "epub"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let sidecarURL = directory.appendingPathComponent("One Dark Window.sidecar.json")
        try encoder.encode(sidecar).write(to: sidecarURL)

        let decoded = try await LocalLibraryService.shared.loadSidecarMetadata(from: sidecarURL.path)

        #expect(decoded.title == "One Dark Window")
        #expect(decoded.author == "Rachel Gillig")
        #expect(decoded.epub3Features?.hasMediaOverlay == true)
        #expect(decoded.epub3Features?.smilFileCount == 36)
    }

    @Test func localImporterFallsBackToArchiveMediaOverlayDetection() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let epubURL = try await makeReadAloudEPUB(in: directory)

        let metadata = try await LocalEbookImporter.shared.extractMetadata(from: epubURL)

        #expect(metadata.title == "Read Aloud Regression")
        #expect(metadata.author == "Enve")
        #expect(metadata.epub3Features?.hasMediaOverlay == true)
        #expect(metadata.epub3Features?.smilFileCount == 1)
    }

    private func makeReadAloudEPUB(in root: URL) async throws -> URL {
        let contents = root.appendingPathComponent("contents", isDirectory: true)
        let write: (String, Data) throws -> Void = { path, data in
            let url = contents.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
        }
        let writeText: (String, String) throws -> Void = { path, text in
            try write(path, Data(text.utf8))
        }

        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try writeText("mimetype", "application/epub+zip")
        try writeText(
            "META-INF/container.xml",
            """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """
        )
        try writeText(
            "OEBPS/package.opf",
            """
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">read-aloud-regression</dc:identifier>
                <dc:title>Read Aloud Regression</dc:title>
                <dc:creator>Enve</dc:creator>
                <dc:language>en</dc:language>
              </metadata>
              <manifest>
                <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml" media-overlay="overlay"/>
                <item id="overlay" href="chapter.smil" media-type="application/smil+xml"/>
                <item id="audio" href="audio.mp3" media-type="audio/mpeg"/>
              </manifest>
              <spine><itemref idref="chapter"/></spine>
            </package>
            """
        )
        try writeText(
            "OEBPS/chapter.xhtml",
            """
            <html xmlns="http://www.w3.org/1999/xhtml"><body><p id="line">Read aloud text.</p></body></html>
            """
        )
        try writeText(
            "OEBPS/chapter.smil",
            """
            <smil xmlns="http://www.w3.org/ns/SMIL" version="3.0">
              <body><seq><par><text src="chapter.xhtml#line"/><audio src="audio.mp3" clipBegin="0s" clipEnd="1s"/></par></seq></body>
            </smil>
            """
        )
        try write("OEBPS/audio.mp3", Data([0]))

        let epubURL = root.appendingPathComponent("read-aloud.epub")
        try await FileManager.default.zipItem(at: contents, to: epubURL, shouldKeepParent: false)
        return epubURL
    }
}
