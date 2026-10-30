import Foundation
import SwiftSoup
import XCTest
@testable import StoryAlignCore

final class CTCSparseSentenceExportTests: XCTestCase, @unchecked Sendable {
    func testOmittedInteriorSentencesKeepTheirOriginalFragmentIDs() async throws {
        try await verify(sentences: ["A quiet opening.", "An omitted interruption.", "A second supported sentence.", "Another omitted interruption.", "The final supported sentence."], accepted: [0, 2, 4])
    }

    func testUnspokenHeadingAndMultipleGapsDoNotShiftHighlights() async throws {
        try await verify(sentences: ["Unspoken prologue", "The captain opened the door.", "An omitted interruption.", "The sailor unfolded the map.", "Another omitted interruption.", "The ship reached the harbor."], accepted: [1, 3, 5], heading: true)
    }

    private func verify(sentences: [String], accepted: [Int], heading: Bool = false) async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let opfDirectory = root.appendingPathComponent("OEBPS", isDirectory: true)
        try manager.createDirectory(at: opfDirectory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let body = sentences.enumerated().map { index, text in
            heading && index == 0 ? "<h1>\(text)</h1>" : "<p>\(text)</p>"
        }.joined()
        let xhtml = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Harbor</title></head><body>\(body)</body></html>"
        let chapterURL = opfDirectory.appendingPathComponent("chapter.xhtml")
        try Data(xhtml.utf8).write(to: chapterURL)
        let opf = "<package xmlns=\"http://www.idpf.org/2007/opf\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" version=\"3.0\"><metadata><dc:identifier>fixture</dc:identifier><dc:title>Harbor</dc:title><dc:language>en</dc:language></metadata><manifest><item id=\"chapter\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"chapter\"/></spine></package>"
        try Data(opf.utf8).write(to: opfDirectory.appendingPathComponent("content.opf"))
        let manifest = EpubManifestItem(id: "chapter", href: "chapter.xhtml", mediaType: "application/xhtml+xml", properties: nil, spineItemIndex: 0, text: sentences.joined(separator: " "), xmlData: Data(xhtml.utf8), hasScript: false, xhtmlSentences: sentences, name: "Harbor", filePath: chapterURL)
        var metadata = EpubMetaInfo()
        metadata.version = "3.0"
        let epub = try EpubDocument(opfPath: "OEBPS/content.opf", opfXmlData: Data(opf.utf8), metaInfo: metadata, unzippedURL: root, guide: [], manifest: [manifest], spine: EpubSpine(toc: "", items: [.init(idref: "chapter", id: nil, index: 0)]), resources: [])
        let audio = AudioFile(startTmeInterval: 0, endTmeInterval: 100, filePath: opfDirectory.appendingPathComponent(AssetPaths.audio).appendingPathComponent("narration.m4a"), index: 0)
        let aligned = accepted.map { index in
            let range = SentenceRange(id: index, start: Double(index * 5), end: Double(index * 5 + 4), audioFile: audio, timeStamps: [])
            return AlignedSentence(xhtmlSentence: sentences[index], sentenceId: index, sentenceRange: range, matchText: nil, matchOffset: nil, matchType: nil)
        }
        let request = try AlignmentRequest(epubURL: root.appendingPathComponent("original.epub"), audioBookURLs: [audio.filePath], sessionDir: root.path)
        let session = AlignmentSession(request: request, config: AlignmentConfig(concurrency: 1))
        try await EpubXmlUpdater(session: session).update(epub: epub, audioBook: AudioBook(audioFiles: [audio]), alignedChapters: [AlignedChapter(manifestItem: manifest, alignedSentences: aligned)], includeUnalignedSentences: true)
        let tagged = try SwiftSoup.parse(String(contentsOf: chapterURL, encoding: .utf8))
        XCTAssertEqual(try tagged.body()?.text(), sentences.joined(separator: " "))
        for (index, sentence) in sentences.enumerated() {
            let fragment = try XCTUnwrap(tagged.getElementById("chapter-sentence\(index)"))
            XCTAssertEqual(try fragment.text(), sentence)
        }
        let smilURL = opfDirectory.appendingPathComponent(AssetPaths.mediaOverlays).appendingPathComponent("chapter.smil")
        let smil = try SwiftSoup.parse(String(contentsOf: smilURL, encoding: .utf8), "", Parser.xmlParser())
        let references = try smil.select("par > text").array().map { try $0.attr("src").components(separatedBy: "#").last! }
        XCTAssertEqual(references, accepted.map { "chapter-sentence\($0)" })
        for (reference, originalIndex) in zip(references, accepted) {
            let fragment = try XCTUnwrap(tagged.getElementById(reference))
            XCTAssertEqual(try fragment.text(), sentences[originalIndex])
        }
    }
}
