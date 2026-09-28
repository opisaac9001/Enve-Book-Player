import Foundation
import Testing

@testable import enve

@MainActor
struct KOReaderDocumentHashRepairTests {
    @Test func legacyPersistedLinkDecodesWithoutRepairFields() throws {
        let legacy = Data(
            """
            [{"bookStableId":"local:x:1","documentHash":"11111111111111111111111111111111",
              "isAutomatic":true,"lastSyncedAt":760000000.5,"lastSyncedPercentage":0.25}]
            """.utf8
        )

        let decoded = try JSONDecoder().decode([KOReaderBookLink].self, from: legacy)

        #expect(decoded.count == 1)
        #expect(decoded[0].documentHash == "11111111111111111111111111111111")
        #expect(decoded[0].lastSyncedPercentage == 0.25)
        #expect(decoded[0].fileIdentity == nil)
        #expect(decoded[0].previousHashes.isEmpty)
    }

    @Test func fileIdentityReflectsSizeAndIsNilWhenFileIsMissing() throws {
        let fileURL = try writeEbook(bytes: 4_000)
        let first = KOReaderFileIdentity.read(fileURL: fileURL)
        #expect(first?.sizeBytes == 4_000)
        #expect(first?.path == fileURL.path)

        try Data(repeating: 9, count: 6_000).write(to: fileURL, options: .atomic)
        #expect(KOReaderFileIdentity.read(fileURL: fileURL) != first)

        try FileManager.default.removeItem(at: fileURL)
        #expect(KOReaderFileIdentity.read(fileURL: fileURL) == nil)
    }

    @Test func unchangedHashKeepsSyncMetadataAndRefreshesIdentity() {
        let identity = KOReaderFileIdentity(path: "/tmp/a.epub", sizeBytes: 10, modifiedAtMilliseconds: 5)
        let previous = KOReaderBookLink(
            bookStableId: "book",
            documentHash: String(repeating: "a", count: 32),
            isAutomatic: true,
            lastSyncedAt: Date(timeIntervalSince1970: 100),
            lastSyncedPercentage: 0.4
        )

        let repaired = KOReaderSyncService.repairedLink(
            previous: previous,
            bookStableId: "book",
            documentHash: previous.documentHash,
            isAutomatic: true,
            fileIdentity: identity
        )

        #expect(repaired.documentHash == previous.documentHash)
        #expect(repaired.lastSyncedPercentage == 0.4)
        #expect(repaired.lastSyncedAt == previous.lastSyncedAt)
        #expect(repaired.fileIdentity == identity)
        #expect(repaired.previousHashes.isEmpty)
    }

    @Test func changedHashRecordsHistoryAndResetsSyncMetadata() {
        let previous = KOReaderBookLink(
            bookStableId: "book",
            documentHash: String(repeating: "a", count: 32),
            isAutomatic: true,
            lastSyncedAt: Date(timeIntervalSince1970: 100),
            lastSyncedPercentage: 0.4,
            previousHashes: [String(repeating: "9", count: 32)]
        )

        let repaired = KOReaderSyncService.repairedLink(
            previous: previous,
            bookStableId: "book",
            documentHash: String(repeating: "b", count: 32),
            isAutomatic: true,
            fileIdentity: nil
        )

        #expect(repaired.documentHash == String(repeating: "b", count: 32))
        #expect(repaired.previousHashes == [previous.documentHash, String(repeating: "9", count: 32)])
        #expect(repaired.lastSyncedAt == nil)
        #expect(repaired.lastSyncedPercentage == nil)
    }

    @Test func hashHistoryStaysBounded() {
        var link = KOReaderBookLink(
            bookStableId: "book",
            documentHash: String(repeating: "0", count: 32),
            isAutomatic: true
        )

        for marker in "123456789" {
            link = KOReaderSyncService.repairedLink(
                previous: link,
                bookStableId: "book",
                documentHash: String(repeating: marker, count: 32),
                isAutomatic: true,
                fileIdentity: nil
            )
        }

        #expect(link.previousHashes.count == KOReaderSyncService.maxHashHistory)
        #expect(link.previousHashes.first == String(repeating: "8", count: 32))
    }

    @Test func automaticLinkRepairsWhenFileIsReplacedAtTheSamePath() async throws {
        let service = KOReaderSyncService.shared
        let fileURL = try writeEbook(bytes: 4_000)
        let book = makeEbook(fileURL: fileURL)
        defer {
            service.unlink(bookStableId: book.stableId)
            try? FileManager.default.removeItem(at: fileURL)
        }

        let firstResult = await service.ensureDocumentHash(for: book)
        let first = try #require(firstResult)
        #expect(service.link(for: book.stableId)?.fileIdentity != nil)

        let repeated = await service.ensureDocumentHash(for: book)
        #expect(repeated == first)
        #expect(service.link(for: book.stableId)?.previousHashes.isEmpty == true)

        try Data((0..<6_000).map { UInt8(($0 * 13 + 7) % 256) }).write(to: fileURL, options: .atomic)
        let repaired = await service.ensureDocumentHash(for: book)

        #expect(repaired != first)
        let link = try #require(service.link(for: book.stableId))
        #expect(link.documentHash == repaired)
        #expect(link.previousHashes == [first])
        #expect(link.isAutomatic)
    }

    @Test func missingLocalFileKeepsThePriorLink() async throws {
        let service = KOReaderSyncService.shared
        let fileURL = try writeEbook(bytes: 4_000)
        let book = makeEbook(fileURL: fileURL)
        defer { service.unlink(bookStableId: book.stableId) }

        let originalResult = await service.ensureDocumentHash(for: book)
        let original = try #require(originalResult)
        try FileManager.default.removeItem(at: fileURL)

        #expect(await service.ensureDocumentHash(for: book) == original)
        #expect(service.link(for: book.stableId)?.documentHash == original)
    }

    @Test func manualPinIsNeverRevalidated() async throws {
        let service = KOReaderSyncService.shared
        let fileURL = try writeEbook(bytes: 4_000)
        let book = makeEbook(fileURL: fileURL)
        defer {
            service.unlink(bookStableId: book.stableId)
            try? FileManager.default.removeItem(at: fileURL)
        }

        let pinned = String(repeating: "c", count: 32)
        service.link(book: book, documentHash: pinned, isAutomatic: false)

        #expect(await service.ensureDocumentHash(for: book) == pinned)
        let link = try #require(service.link(for: book.stableId))
        #expect(link.isAutomatic == false)
        #expect(link.fileIdentity == nil)
        #expect(link.previousHashes.isEmpty)
    }

    @Test func manualPinSurvivesAnInFlightAutomaticRepair() async throws {
        let service = KOReaderSyncService.shared
        let fileURL = try writeEbook(bytes: 4_000)
        let book = makeEbook(fileURL: fileURL)
        defer {
            service.unlink(bookStableId: book.stableId)
            try? FileManager.default.removeItem(at: fileURL)
        }

        _ = await service.ensureDocumentHash(for: book)
        try Data((0..<6_000).map { UInt8(($0 * 13 + 7) % 256) }).write(to: fileURL, options: .atomic)

        let pinned = String(repeating: "d", count: 32)
        let inFlight = Task { await service.ensureDocumentHash(for: book) }
        await Task.yield()
        service.link(book: book, documentHash: pinned, isAutomatic: false)
        _ = await inFlight.value

        let link = try #require(service.link(for: book.stableId))
        #expect(link.documentHash == pinned)
        #expect(link.isAutomatic == false)
    }

    private func writeEbook(bytes: Int) throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("koreader-repair-\(UUID().uuidString).epub")
        try Data((0..<bytes).map { UInt8(($0 * 37 + 11) % 256) }).write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func makeEbook(fileURL: URL) -> Book {
        Book(
            id: fileURL.deletingPathExtension().lastPathComponent,
            title: "KOReader repair fixture",
            source: .local,
            backendId: "koreader-repair-tests",
            filePath: fileURL.path,
            mediaType: .ebook,
            providerId: UUID(),
            libraryId: "library"
        )
    }
}
