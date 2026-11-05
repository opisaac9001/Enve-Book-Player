import Foundation
import Testing

@testable import enve

@MainActor
struct BookContextBoundaryTests {
    @Test func slicesBothBoundsAgainstTheOriginalChunk() throws {
        try withEbook { book, store in
            try store.saveContext(bookStableId: book.stableId, chunks: [chunk(book, text: words(1...100))])
            let result = BookContextRetriever.shared.context(for: book, scope: .lastTenMinutes, range: 0.4...0.6)
            #expect(result.text == words(41...60))
            #expect(result.segmentCount == 1)
        }
    }

    @Test(arguments: [0.0, 0.5, 1.0]) func emptyRangesContainNoTextOrChapterTitle(progress: Double) throws {
        try withEbook { book, store in
            try store.saveContext(bookStableId: book.stableId, chunks: [chunk(book, title: "Unread title", text: words(1...100))])
            let result = BookContextRetriever.shared.context(for: book, scope: .bookSoFar, range: progress...progress)
            #expect(result.isEmpty)
            #expect(result.segmentCount == 0)
        }
    }

    @Test func chapterBoundaryExcludesTheNextChapterTitleAndWords() throws {
        try withEbook { book, store in
            try store.saveContext(bookStableId: book.stableId, chunks: [
                chunk(book, title: "Read chapter", end: 0.5, text: "Already read."),
                chunk(book, index: 1, title: "Future revelation", start: 0.5, text: "Not read yet."),
            ])
            let result = BookContextRetriever.shared.context(for: book, scope: .bookSoFar, range: 0...0.5)
            #expect(result.text == "[Read chapter] Already read.")
            #expect(result.segmentCount == 1)
        }
    }

    @Test func readingBeforeTheFirstIndexedChapterHasNoContext() throws {
        try withEbook { book, store in
            try store.saveContext(bookStableId: book.stableId, chunks: [chunk(book, start: 0.2, text: "Future content")])
            let result = BookContextRetriever.shared.context(for: book, scope: .currentChapterSoFar, currentTime: 0.1)
            #expect(result.isEmpty)
            #expect(result.range == 0.1...0.1)
        }
    }

    @Test func partialWordsAndWhitespaceCannotExtendTheUpperBoundary() throws {
        try withEbook { book, store in
            try store.saveContext(bookStableId: book.stableId, chunks: [chunk(book, text: "one\ntwo\tthree four")])
            let result = BookContextRetriever.shared.context(for: book, scope: .bookSoFar, range: 0...0.49)
            #expect(result.text == "one")
        }
    }

    @Test func transcriptContextExcludesUnfinishedAndFutureSegments() throws {
        let book = Book(id: UUID().uuidString, title: "Transcript boundary fixture")
        let store = BookTranscriptStore.shared
        defer { store.clear(bookStableId: book.stableId) }
        let segments = [(0.0, 5.0, "Already heard."), (5.0, 10.0, "Future reveal."), (10.0, 15.0, "Later.")]
            .enumerated().map { index, item in
                TranscriptSegment(id: "s\(index)", bookStableId: book.stableId, chapterId: nil, trackIndex: 0,
                                  startTime: item.0, endTime: item.1, text: item.2, confidence: nil, isFinal: true)
            }
        try store.saveTranscript(bookStableId: book.stableId, localeIdentifier: "en-US", duration: 15,
                                 fingerprint: .init(version: 1, localeIdentifier: "en-US", duration: 15, files: []), segments: segments)
        let result = BookContextRetriever.shared.context(for: book, scope: .bookSoFar, range: 0...7)
        #expect(result.segmentCount == 1)
        #expect(result.text.contains("Already heard."))
        #expect(!result.text.contains("Future reveal."))
        #expect(BookContextRetriever.shared.context(for: book, scope: .bookSoFar, range: 0...0).isEmpty)
    }

    private func withEbook(_ test: (Book, EbookContextStore) throws -> Void) throws {
        var book = Book(id: UUID().uuidString, title: "Ebook boundary fixture")
        book.mediaType = .ebook
        let store = EbookContextStore.shared
        defer { store.clear(bookStableId: book.stableId) }
        try test(book, store)
    }

    private func chunk(_ book: Book, index: Int = 0, title: String? = nil,
                       start: Double = 0, end: Double = 1, text: String) -> EbookContextChunk {
        EbookContextChunk(id: "c\(index)", bookStableId: book.stableId, title: title, href: "chapter\(index).xhtml",
                          index: index, startProgress: start, endProgress: end, text: text)
    }

    private func words(_ range: ClosedRange<Int>) -> String {
        range.map { "word\($0)" }.joined(separator: " ")
    }
}
