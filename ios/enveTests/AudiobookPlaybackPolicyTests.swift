import Foundation
import Testing

@testable import enve

struct AudiobookPlaybackPolicyTests {
    @Test func longSingleChapterRequestsRefreshAndEmbeddedExtraction() {
        let book = makeBook(
            duration: 3_600,
            chapters: [Chapter(id: "one", start: 0, end: 3_600, title: "One", index: 0)]
        )

        #expect(AudiobookPlaybackPolicy.chaptersNeedRefresh(for: book))
        #expect(AudiobookPlaybackPolicy.chaptersAreInadequateForExtraction(book))
    }

    @Test func validMultipleChaptersDoNotRequestRefresh() {
        let book = makeBook(
            duration: 3_600,
            chapters: [
                Chapter(id: "one", start: 0, end: 1_800, title: "One", index: 0),
                Chapter(id: "two", start: 1_800, end: 3_600, title: "Two", index: 1),
            ]
        )

        #expect(!AudiobookPlaybackPolicy.chaptersNeedRefresh(for: book))
        #expect(!AudiobookPlaybackPolicy.chaptersAreInadequateForExtraction(book))
    }

    @Test func duplicateOrInvalidChaptersRequestRefresh() {
        let duplicate = makeBook(
            duration: 600,
            chapters: [
                Chapter(id: "same", start: 0, end: 300, title: "One", index: 0),
                Chapter(id: "same", start: 300, end: 600, title: "Two", index: 1),
            ]
        )
        let invalid = makeBook(
            duration: 600,
            chapters: [Chapter(id: "one", start: 20, end: 20, title: "One", index: 0)]
        )

        #expect(AudiobookPlaybackPolicy.chaptersNeedRefresh(for: duplicate))
        #expect(AudiobookPlaybackPolicy.chaptersNeedRefresh(for: invalid))
    }

    private func makeBook(duration: TimeInterval, chapters: [Chapter]) -> Book {
        Book(
            id: "playback-policy",
            title: "Playback Policy",
            duration: duration,
            chapters: chapters,
            providerId: UUID(),
            libraryId: "tests"
        )
    }
}
