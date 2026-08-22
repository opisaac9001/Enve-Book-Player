import Foundation
import Testing

@testable import enve

struct SeriesAutoAdvancePolicyTests {
    private func book(_ id: String, sequence: String?, isFinished: Bool = false, mediaType: AppMediaType = .audiobook) -> Book {
        var book = Book(
            id: id,
            title: id,
            seriesInfo: SeriesInfo(name: "The Series", sequence: sequence),
            duration: 600,
            isFinished: isFinished,
            libraryId: "library",
            providerId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        book.mediaType = mediaType
        return book
    }

    @Test func picksTheNextUnfinishedSequence() {
        let finished = book("one", sequence: "1")
        let series = [finished, book("three", sequence: "3"), book("two", sequence: "2")]
        #expect(SeriesAutoAdvancePolicy.nextBook(after: finished, in: series)?.id == "two")
    }

    @Test func skipsFinishedAndEarlierBooks() {
        let finished = book("two", sequence: "2")
        let series = [
            book("one", sequence: "1"),
            finished,
            book("three", sequence: "3", isFinished: true),
            book("four", sequence: "4"),
        ]
        #expect(SeriesAutoAdvancePolicy.nextBook(after: finished, in: series)?.id == "four")
    }

    @Test func handlesFractionalSequences() {
        let finished = book("one", sequence: "1")
        let series = [finished, book("onefive", sequence: "1.5"), book("two", sequence: "2")]
        #expect(SeriesAutoAdvancePolicy.nextBook(after: finished, in: series)?.id == "onefive")
    }

    @Test func requiresASequenceOnTheFinishedBook() {
        let finished = book("one", sequence: nil)
        let series = [finished, book("two", sequence: "2")]
        #expect(SeriesAutoAdvancePolicy.nextBook(after: finished, in: series) == nil)
    }

    @Test func ignoresEbooksAndTheFinishedBookItself() {
        let finished = book("one", sequence: "1")
        let series = [finished, book("ebook", sequence: "2", mediaType: .ebook)]
        #expect(SeriesAutoAdvancePolicy.nextBook(after: finished, in: series) == nil)
    }
}
