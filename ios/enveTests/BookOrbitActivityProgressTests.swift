import Foundation
import Testing

@testable import enve

@MainActor
struct BookOrbitActivityProgressTests {
    private static let canonicalCFI = "epubcfi(/6/14!/4/2/2:0)"
    private static let partialCFI = "epubcfi(/4/2/2:0)"
    private static let localDate = Date(timeIntervalSince1970: 100_000)

    @Test func canonicalServerCFIBecomesTheExactAnchor() throws {
        let locator = try #require(
            BookOrbitSyncStrategy.ebookLocator(serverCFI: Self.canonicalCFI, fraction: 0.8, book: ebook())
        )

        #expect(EpubLocationBridge.epubCFI(from: locator) == Self.canonicalCFI)
        #expect(EpubLocationBridge.totalProgression(from: locator) == 0.8)
        #expect(EpubLocationBridge.sourceEngine(from: locator) == .foliate)
    }

    @Test func percentageOnlySnapshotKeepsTheExactLocalAnchor() {
        let book = ebook()

        #expect(BookOrbitSyncStrategy.ebookLocator(serverCFI: nil, fraction: 0.62, book: book) == book.epubLocator)
        #expect(
            BookOrbitSyncStrategy.ebookLocator(serverCFI: Self.partialCFI, fraction: 0.62, book: book)
                == book.epubLocator
        )
    }

    @Test func percentageOnlySnapshotThatMovedKeepsTheExactLocalAnchor() {
        let book = ebook()

        #expect(BookOrbitSyncStrategy.ebookLocator(serverCFI: nil, fraction: 0.9, book: book) == book.epubLocator)
    }

    @Test func olderServerSnapshotDoesNotRollBackNewerLocalProgress() {
        let book = ebook()
        let server = progress(
            fraction: 0.30,
            lastUpdate: Self.localDate.addingTimeInterval(-3_600)
        )

        #expect(
            BookOrbitSyncStrategy.serverProgressIsStale(
                book: book,
                serverProgress: server,
                serverLocator: EpubLocationBridge.readiumLocator(href: nil, fraction: 0.30, sourceEngine: .foliate)
            )
        )
    }

    @Test func newerServerSnapshotStillApplies() {
        let book = ebook()
        let server = progress(fraction: 0.30, lastUpdate: Self.localDate.addingTimeInterval(3_600))

        #expect(
            BookOrbitSyncStrategy.serverProgressIsStale(
                book: book,
                serverProgress: server,
                serverLocator: EpubLocationBridge.readiumLocator(
                    href: nil,
                    epubCFI: Self.canonicalCFI,
                    fraction: 0.30,
                    sourceEngine: .foliate
                )
            ) == false
        )
    }

    @Test func percentageOnlyServerSnapshotCannotReplaceAnExactLocalAnchor() {
        let book = ebook()
        let server = progress(fraction: 0.9, lastUpdate: Self.localDate.addingTimeInterval(3_600))

        #expect(
            BookOrbitSyncStrategy.serverProgressIsStale(
                book: book,
                serverProgress: server,
                serverLocator: EpubLocationBridge.readiumLocator(href: nil, fraction: 0.9, sourceEngine: .foliate)
            )
        )
    }

    @Test func anOlderSnapshotAtTheSamePositionIsNotStale() {
        let book = ebook()
        let server = progress(fraction: 0.62, lastUpdate: Self.localDate.addingTimeInterval(-3_600))

        #expect(
            BookOrbitSyncStrategy.serverProgressIsStale(
                book: book,
                serverProgress: server,
                serverLocator: book.epubLocator
            ) == false
        )
    }

    @Test func olderAudiobookSnapshotDoesNotRewindTheLocalPosition() {
        let book = Book(
            id: "1",
            title: "Audiobook",
            duration: 3_600,
            source: .bookOrbit,
            mediaType: .audiobook,
            currentTime: 1_200,
            lastUpdate: Self.localDate,
            providerId: UUID(),
            libraryId: "1"
        )

        let server = UserMediaProgress(
            id: "bookorbit-1",
            libraryItemId: "1",
            providerId: book.providerId,
            episodeId: nil,
            currentTime: 60,
            progress: 60.0 / 3_600.0,
            isFinished: false,
            duration: 3_600,
            lastUpdate: Self.localDate.addingTimeInterval(-3_600),
            ebookProgress: nil
        )

        #expect(BookOrbitSyncStrategy.serverProgressIsStale(book: book, serverProgress: server, serverLocator: nil))
    }

    private func ebook() -> Book {
        Book(
            id: "1",
            title: "Ebook",
            source: .bookOrbit,
            mediaType: .ebook,
            epubLocator: EpubLocationBridge.readiumLocator(
                href: nil,
                epubCFI: Self.canonicalCFI,
                fraction: 0.62,
                sourceEngine: .foliate
            ),
            ebookProgress: 0.62,
            lastUpdate: Self.localDate,
            providerId: UUID(),
            libraryId: "1"
        )
    }

    private func progress(fraction: Double, lastUpdate: Date) -> UserMediaProgress {
        UserMediaProgress(
            id: "bookorbit-1",
            libraryItemId: "1",
            providerId: UUID(),
            episodeId: nil,
            currentTime: 0,
            progress: fraction,
            isFinished: false,
            duration: 0,
            lastUpdate: lastUpdate,
            ebookProgress: fraction
        )
    }
}
