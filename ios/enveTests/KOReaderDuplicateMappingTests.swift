import Foundation
import Testing

@testable import enve

@MainActor
struct KOReaderDuplicateMappingTests {
    @Test func partialMD5MatchesKOReaderSampling() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("koreader-hash-\(UUID().uuidString).epub")
        let bytes = Data((0..<5_000).map { UInt8(($0 * 37 + 11) % 256) })
        try bytes.write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let hash = await KOReaderSyncService.computePartialMD5(fileURL: fileURL)

        #expect(hash == "bc0a36e392584120c95013be66f97b0b")
    }

    @Test func duplicatePersistedLinksRestoreWithoutTrapping() {
        let first = KOReaderBookLink(
            bookStableId: "ebook",
            documentHash: "11111111111111111111111111111111",
            isAutomatic: true,
            lastSyncedAt: nil,
            lastSyncedPercentage: nil
        )
        let latest = KOReaderBookLink(
            bookStableId: "ebook",
            documentHash: "22222222222222222222222222222222",
            isAutomatic: false,
            lastSyncedAt: Date(),
            lastSyncedPercentage: 0.5
        )

        let restored = KOReaderSyncService.restoredLinks([first, latest])

        #expect(restored.count == 1)
        #expect(restored["ebook"] == latest)
    }

    @Test func duplicateBookBridgeKeysAreExcludedFromMatching() {
        let first = makeBook(id: "duplicate", providerId: UUID())
        let second = makeBook(id: "duplicate", providerId: UUID())
        let unique = makeBook(id: "unique", providerId: UUID())

        let indexed = BookBridgeMappingImporter.booksIndexedByUniqueKey(
            [first, second, unique],
            key: { $0.id }
        )

        #expect(indexed["duplicate"] == nil)
        #expect(indexed["unique"]?.providerId == unique.providerId)
    }

    private func makeBook(id: String, providerId: UUID) -> Book {
        Book(
            id: id,
            title: "Book \(id)",
            source: .audiobookshelf,
            mediaType: .audiobook,
            providerId: providerId,
            libraryId: "library"
        )
    }
}
