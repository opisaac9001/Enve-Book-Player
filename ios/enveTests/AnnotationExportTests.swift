import Foundation
import PDFKit
import Testing

@testable import enve

@MainActor
struct AnnotationExportTests {
    private func exporter(text: String) -> AnnotationExporter {
        AnnotationExporter(bookTitle: "Test / Book", bookAuthor: "Test Author", annotations: [
            ReaderAnnotation(bookId: "book", position: 0.4, text: text, note: "My note\nAnother line", chapterTitle: "Chapter, One")
        ], bookmarks: [])
    }

    @Test func textFormatsPreserveMultilineHighlightsNotesAndChapter() throws {
        let exporter = exporter(text: "First line\nSecond line")
        let markdown = exporter.preview(format: .markdown)
        #expect(markdown.contains("> First line\n> Second line"))
        #expect(markdown.contains("> My note\n> Another line"))
        #expect(markdown.contains("Chapter, One"))
        #expect(exporter.preview(format: .csv).contains("\"Chapter, One\""))
        let object = try #require(JSONSerialization.jsonObject(with: Data(exporter.preview(format: .json).utf8)) as? [String: Any])
        let entry = try #require((object["annotations"] as? [[String: Any]])?.first)
        #expect(entry["chapter"] as? String == "Chapter, One")
        #expect(entry["text"] as? String == "First line\nSecond line")
    }

    @Test func pdfPaginatesWithoutLosingTheEndOfLongHighlights() throws {
        let text = (0..<300).map { "Paragraph \($0): The lantern waits beside the quiet gate." }.joined(separator: "\n") + "\nFinal passage preserved"
        let data = try exporter(text: text).pdfData()
        #expect(data.starts(with: Data("%PDF".utf8)))
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount > 1)
        let extracted = pdf.string ?? ""
        #expect(extracted.contains("Paragraph 0:"))
        #expect(extracted.contains("Paragraph 299:"))
        #expect(extracted.contains("Final passage preserved"))
        #expect(extracted.contains("My note"))
    }

    @Test func shareFileHasCorrectTypeAndLivesUntilReleased() throws {
        var file: AnnotationExportFile? = try exporter(text: "Test passage").makeFile(format: .pdf)
        let url = try #require(file?.url)
        #expect(url.pathExtension == "pdf")
        #expect(url.lastPathComponent == "Test   Book.pdf")
        #expect(try Data(contentsOf: url).starts(with: Data("%PDF".utf8)))
        file = nil
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
