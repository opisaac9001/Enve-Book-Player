import Foundation
import PDFKit
import Testing
import UIKit

@testable import enve

@MainActor
struct BookOrbitEbookDownloadTests {
    @Test func cachedPDFWithAnEpubFilenameIsRepairedOffline() async throws {
        let id = UUID().uuidString
        let importer = LocalEbookImporter.shared
        defer { try? importer.deleteRemoteEbookArtifacts(forBookId: id) }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 300))
        let data = renderer.pdfData { $0.beginPage() }
        let old = try importer.cacheRemoteEbook(data: data, preferredFilename: "Fixture.epub", bookIdentifier: id)
        let connection = ServerConnection(name: "Fixture", url: "https://offline.invalid", type: .bookOrbit)
        let provider = BookOrbitProvider(connection: connection)
        let book = Book(id: id, title: "Fixture", source: .bookOrbit, providerId: connection.id, libraryId: "1")

        let corrected = try await provider.downloadEbook(for: book)

        #expect(corrected.pathExtension == "pdf")
        #expect(PDFDocument(url: corrected)?.pageCount == 1)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(try await provider.downloadEbook(for: book) == corrected)
    }

    @Test func cachedEpubRemainsAvailableOffline() async throws {
        let id = UUID().uuidString
        let importer = LocalEbookImporter.shared
        defer { try? importer.deleteRemoteEbookArtifacts(forBookId: id) }
        let cached = try importer.cacheRemoteEbook(data: Data([0x50, 0x4B, 0x03, 0x04]),
                                                preferredFilename: "Fixture.epub", bookIdentifier: id)
        let connection = ServerConnection(name: "Fixture", url: "https://offline.invalid", type: .bookOrbit)
        let provider = BookOrbitProvider(connection: connection)
        let book = Book(id: id, title: "Fixture", source: .bookOrbit, providerId: connection.id, libraryId: "1")

        #expect(try await provider.downloadEbook(for: book) == cached)
    }
}
