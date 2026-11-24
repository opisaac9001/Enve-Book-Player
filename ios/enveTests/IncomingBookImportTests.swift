import Foundation
import Testing

@testable import enve

@MainActor
struct IncomingBookImportTests {
    @Test func acceptsLocalSupportedFilesOnly() {
        for filename in ["Book.EPUB", "Book.kepub", "Book.pdf", "Book.cbz", "Book.m4b", "Books.zip"] {
            #expect(IncomingBookImportRequest.supports(URL(fileURLWithPath: "/tmp/" + filename)))
        }
        #expect(!IncomingBookImportRequest.supports(URL(string: "https://example.com/Book.epub")!))
        #expect(!IncomingBookImportRequest.supports(URL(fileURLWithPath: "/tmp/Notes.txt")))
        #expect(!IncomingBookImportRequest.supports(URL(fileURLWithPath: "/tmp/Book.imagefolder")))
    }

    @Test func claimsInboxCopyWithoutMovingExternalOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Book.epub")
        let incoming = inbox.appendingPathComponent("Book.epub")
        let data = Data("test book".utf8)
        try data.write(to: original)
        try data.write(to: incoming)

        let external = IncomingBookImportRequest(url: original, inboxDirectory: inbox)
        #expect(external.url == original)
        #expect(try Data(contentsOf: original) == data)

        var request: IncomingBookImportRequest? = IncomingBookImportRequest(url: incoming, inboxDirectory: inbox)
        let staged = try #require(request?.url)
        #expect(request?.stagingError == nil)
        #expect(staged != incoming)
        #expect(try Data(contentsOf: staged) == data)
        #expect(!FileManager.default.fileExists(atPath: incoming.path))
        request = nil
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(try Data(contentsOf: original) == data)
    }

    @Test func calibrePresetPreservesExplicitCatalogAndProxyPaths() {
        let preset = ConnectionCapability.CatalogSetup.calibre
        #expect(preset.catalogURL(from: "http://computer.local:8080") == "http://computer.local:8080/opds")
        #expect(preset.catalogURL(from: "http://computer.local:8080/") == "http://computer.local:8080/opds")
        for address in ["https://example.com/calibre/opds", "https://example.com/opds/library", "https://example.com/?catalog=1"] {
            #expect(preset.catalogURL(from: address) == address)
        }
        #expect(ConnectionCapability.calibre.providerType == .opds)
        #expect(ConnectionCapability.calibre.credentialsOptional)
    }
}
