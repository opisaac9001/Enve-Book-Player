import Foundation
import XCTest
import ZIPFoundation
@testable import StoryAlignCore

private struct CancellingExportLogger: Logger {
    func log(_ level: LogLevel, _ message: @autoclosure () -> String, file: String, function: String, line: Int, indentLevel: Int) {
        if message().hasPrefix("Adding ") {
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
}

final class EpubExporterTests: XCTestCase, @unchecked Sendable {
    func testExistingOutputIsReplacedWithCompleteArchive() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (epub, session, output) = try fixture(root: root)
        try Data("stale output".utf8).write(to: output)
        try EpubExporter(session: session).export(eBook: epub, to: output)
        let archive = try Archive(url: output, accessMode: .read)
        let entries = Array(archive)
        XCTAssertEqual(entries.first?.path, "mimetype")
        XCTAssertEqual(entries.first?.isCompressed, false)
        XCTAssertEqual(Set(entries.map(\.path)), ["mimetype", "OEBPS/chapter.xhtml"])
        XCTAssertEqual(try EpubParser.extractData(from: archive, path: "mimetype"), Data("application/epub+zip".utf8))
        XCTAssertEqual(try EpubParser.extractData(from: archive, path: "OEBPS/chapter.xhtml"), Data("<html><body>Finished book.</body></html>".utf8))
        try assertNoTemporaryOutput(in: root)
    }

    func testFailedArchivePreservesPreviousOutputAndRemovesTemporaryFile() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (epub, session, output) = try fixture(root: root, includeMimetype: false)
        let previous = Data("previous complete output".utf8)
        try previous.write(to: output)
        XCTAssertThrowsError(try EpubExporter(session: session).export(eBook: epub, to: output))
        XCTAssertEqual(try Data(contentsOf: output), previous)
        try assertNoTemporaryOutput(in: root)
    }

    func testCancellationPreservesPreviousOutputAndRemovesTemporaryFile() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (epub, session, output) = try fixture(root: root, logger: CancellingExportLogger())
        let previous = Data("previous complete output".utf8)
        try previous.write(to: output)
        let task = Task.detached {
            try EpubExporter(session: session).export(eBook: epub, to: output)
        }
        do {
            try await task.value
            XCTFail("A cancelled export must not replace the destination")
        } catch is CancellationError {
            XCTAssertEqual(try Data(contentsOf: output), previous)
            try assertNoTemporaryOutput(in: root)
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func fixture(root: URL, includeMimetype: Bool = true, logger: any Logger = NullLogger()) throws -> (EpubDocument, AlignmentSession, URL) {
        let directory = root.appendingPathComponent("contents", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("OEBPS", isDirectory: true), withIntermediateDirectories: true)
        if includeMimetype {
            try Data("application/epub+zip".utf8).write(to: directory.appendingPathComponent("mimetype"))
        }
        try Data("<html><body>Finished book.</body></html>".utf8).write(to: directory.appendingPathComponent("OEBPS/chapter.xhtml"))
        let request = try AlignmentRequest(epubURL: root.appendingPathComponent("input.epub"), audioBookURLs: [], sessionDir: root.path)
        let session = AlignmentSession(request: request, config: AlignmentConfig(concurrency: 1), logger: logger)
        let epub = try EpubDocument(opfPath: "OEBPS/content.opf", opfXmlData: Data(), metaInfo: EpubMetaInfo(), unzippedURL: directory, guide: [], manifest: [], spine: EpubSpine(toc: "", items: []), resources: [])
        return (epub, session, root.appendingPathComponent("output.epub"))
    }

    private func assertNoTemporaryOutput(in directory: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(entries.contains { $0.hasPrefix(".output.epub.") && $0.hasSuffix(".tmp") }, file: file, line: line)
    }
}
