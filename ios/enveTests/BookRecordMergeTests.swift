import Foundation
import Testing

@testable import enve

@MainActor
struct BookRecordMergeTests {
    private let providerId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEE00000042")!

    private func makeBook(
        mediaType: AppMediaType,
        currentTime: TimeInterval = 0,
        ebookProgress: Double? = nil,
        epubLocator: String? = nil,
        isFinished: Bool = false,
        lastUpdate: Date
    ) -> Book {
        Book(
            id: "42",
            title: "Merge Target",
            duration: 100,
            source: .booklore,
            mediaType: mediaType,
            epubLocator: epubLocator,
            ebookProgress: ebookProgress,
            currentTime: currentTime,
            isFinished: isFinished,
            lastUpdate: lastUpdate,
            providerId: providerId,
            libraryId: "1"
        )
    }

    @Test func staleMediaTypeCorrectionDoesNotOverwriteNewerProgress() {
        let record = BookRecord(
            from: makeBook(
                mediaType: .ebook,
                ebookProgress: 0.6,
                epubLocator: #"{"locations":{"totalProgression":0.6}}"#,
                isFinished: true,
                lastUpdate: Date(timeIntervalSince1970: 2_000_000)
            )
        )
        let stale = makeBook(
            mediaType: .audiobook,
            currentTime: 30,
            lastUpdate: Date(timeIntervalSince1970: 1_000_000)
        )
        record.update(from: stale)

        #expect(record.mediaType == AppMediaType.audiobook.rawValue)
        #expect(record.ebookProgress == 0.6)
        #expect(record.epubLocator == #"{"locations":{"totalProgression":0.6}}"#)
        #expect(record.currentTime == 0)
        #expect(record.isFinished == true)
        #expect(record.lastUpdate == Date(timeIntervalSince1970: 2_000_000))
    }

    @Test func newerIncomingUpdatesProgressAndTimestamp() {
        let record = BookRecord(
            from: makeBook(
                mediaType: .ebook,
                ebookProgress: 0.6,
                lastUpdate: Date(timeIntervalSince1970: 1_000_000)
            )
        )
        let fresh = makeBook(
            mediaType: .audiobook,
            currentTime: 30,
            lastUpdate: Date(timeIntervalSince1970: 2_000_000)
        )
        record.update(from: fresh)

        #expect(record.mediaType == AppMediaType.audiobook.rawValue)
        #expect(record.currentTime == 30)
        #expect(record.ebookProgress == nil)
        #expect(record.lastUpdate == Date(timeIntervalSince1970: 2_000_000))
    }
}
