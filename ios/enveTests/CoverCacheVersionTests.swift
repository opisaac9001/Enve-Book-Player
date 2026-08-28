import Foundation
import Testing

@testable import enve

struct CoverCacheVersionTests {
    @Test func versionedCoverRejectsAnOlderPersistentCopy() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("cover".utf8).write(to: fileURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: fileURL.path
        )
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let sourceURL = try #require(URL(string: "https://books.example/cover?v=2026-03-21T03:13:41Z"))

        #expect(!CachedAsyncCoverImage.coverOverrideIsCurrent(at: fileURL, for: sourceURL))
    }

    @Test func unversionedCoverAcceptsAnExistingPersistentCopy() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("cover".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let sourceURL = try #require(URL(string: "https://books.example/cover"))

        #expect(CachedAsyncCoverImage.coverOverrideIsCurrent(at: fileURL, for: sourceURL))
    }
}
