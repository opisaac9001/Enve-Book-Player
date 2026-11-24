import Foundation
import Testing

@testable import enve

struct CoverCacheVersionTests {
    @Test func revisedCoverRequiresMatchingSourceEvenWhenTheOldFileIsNewer() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let revisionURL = fileURL.appendingPathExtension("revision")
        try Data("old chapter cover".utf8).write(to: fileURL)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: revisionURL)
        }
        let sourceURL = try #require(URL(string: "https://books.example/api/image/volume-cover?volumeId=7&v=2020-01-01T00:00:00Z&enveCoverRevision=volume:7:revision"))

        #expect(!CachedAsyncCoverImage.coverOverrideIsCurrent(at: fileURL, for: sourceURL))
        try Data("chapter:11:revision".utf8).write(to: revisionURL)
        #expect(!CachedAsyncCoverImage.coverOverrideIsCurrent(at: fileURL, for: sourceURL))
        try Data("volume:7:revision".utf8).write(to: revisionURL)
        #expect(CachedAsyncCoverImage.coverOverrideIsCurrent(at: fileURL, for: sourceURL))
    }

    @Test @MainActor func savingCoverPersistsOnlyItsRevisionAndClearsItOnReplacement() throws {
        let key = "CoverCacheVersionTests-\(UUID().uuidString)"
        let sourceURL = try #require(URL(string: "https://books.example/cover?apiKey=fixture-secret&enveCoverRevision=volume:7:revision"))
        let imageData = Data("new volume cover".utf8)
        let path = try LocalStorageManager.shared.saveCoverOverride(for: key, imageData: imageData, sourceURL: sourceURL)
        let revisionURL = path.appendingPathExtension("revision")
        defer {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: revisionURL)
        }
        #expect(try Data(contentsOf: path) == imageData)
        #expect(try String(contentsOf: revisionURL, encoding: .utf8) == "volume:7:revision")
        #expect(CachedAsyncCoverImage.coverOverrideIsCurrent(at: path, for: sourceURL))

        _ = try LocalStorageManager.shared.saveCoverOverride(for: key, imageData: Data("replacement".utf8))
        #expect(!FileManager.default.fileExists(atPath: revisionURL.path))
        #expect(!CachedAsyncCoverImage.coverOverrideIsCurrent(at: path, for: sourceURL))
    }

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
