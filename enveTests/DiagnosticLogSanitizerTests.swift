import Foundation
import Testing

@testable import enve

struct DiagnosticLogSanitizerTests {
    @Test func removesUnixPathsAndMediaFilenames() {
        let input = #"Opening /Users/alice/Library/Application Support/Enve/Private Book.m4b, filename=Private Book.m4b"#

        let result = DiagnosticLogSanitizer.sanitize(input)

        #expect(!result.contains("/Users/alice"))
        #expect(!result.contains("Private Book"))
        #expect(result.contains("<local-path>"))
    }

    @Test func removesSignedURLsAndCredentials() {
        let input = "https://books.example.test/audio.m4b?token=secret&X-Plex-Token=also-secret Bearer abc.def.ghi"

        let result = DiagnosticLogSanitizer.sanitize(input)

        #expect(result == "<server-url> Bearer <redacted>")
    }

    @Test func removesPrivateLibraryMetadataSuppliedByCaller() {
        let result = DiagnosticLogSanitizer.sanitize(
            "Playing The Secret Garden by Frances Hodgson Burnett",
            privateValues: ["The Secret Garden", "Frances Hodgson Burnett"]
        )

        #expect(result == "Playing <private-library-data> by <private-library-data>")
    }

    @Test func removesStructuredLibraryMetadataAndUUIDs() {
        let input = "title=The Secret Garden, author='Frances Hodgson Burnett', providerId=9A7AC100-7096-4B78-B0DF-94A34A6277CF"

        let result = DiagnosticLogSanitizer.sanitize(input)

        #expect(!result.contains("The Secret Garden"))
        #expect(!result.contains("Frances Hodgson Burnett"))
        #expect(!result.contains("9A7AC100"))
        #expect(result.contains("title=<private-library-data>"))
        #expect(result.contains("author=<private-library-data>"))
    }

    @Test func diagnosticIdentifiersAreStableAndDoNotContainSourceData() {
        let first = DiagnosticLogSanitizer.identifier(for: "private-book-id")
        let second = DiagnosticLogSanitizer.identifier(for: "private-book-id")

        #expect(first == second)
        #expect(first.count == 12)
        #expect(!first.contains("private-book-id"))
    }

    @Test func fileDescriptorKeepsOnlyUsefulDiagnostics() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("enve-log-tests-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("Private Book.m4b")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0x01, 0x02, 0x03]).write(to: file)
        defer { try? FileManager.default.removeItem(at: directory) }

        let descriptor = DiagnosticLogSanitizer.fileDescriptor(for: file)

        #expect(descriptor.contains("type=.m4b"))
        #expect(descriptor.contains("bytes=3"))
        #expect(!descriptor.contains("Private Book"))
        #expect(!descriptor.contains(directory.path))
    }
}
