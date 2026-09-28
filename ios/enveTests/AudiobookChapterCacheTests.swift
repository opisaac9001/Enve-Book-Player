import Foundation
import Testing

@testable import enve

@MainActor
struct AudiobookChapterCacheTests {
    private let tableOfContents = [Chapter(id: "spine-0-EPUB/chapter.xhtml", start: 0, end: 0, title: "Chapter 1")]
    private let recording = [
        Chapter(id: "0", start: 0, end: 20, title: "Opening"),
        Chapter(id: "1", start: 20, end: 40, title: "Middle"),
    ]

    @Test func untimedContentsCarryNoAudioTimeline() {
        #expect(!tableOfContents.hasAudioTimeline)
        #expect(recording.hasAudioTimeline)
    }

    @Test func anAudiobookDropsACachedTableOfContentsAndKeepsItsOwnChapters() throws {
        let suite = "AudiobookChapterCacheTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReaderArtifactsStore(defaults: defaults)
        let audiobook = Book(id: "8b720158", title: "Chaptered M4B Book", source: .audiobookshelf, mediaType: .audiobook)
        store.saveCachedChapters(bookId: audiobook.stableId, chapters: tableOfContents)
        store.saveCachedChapters(bookId: audiobook.id, chapters: recording)

        #expect(store.loadCachedAudioChapters(for: audiobook) == recording)
        #expect(store.loadCachedChapters(bookId: audiobook.stableId) == nil)

        store.saveCachedChapters(bookId: audiobook.id, chapters: tableOfContents)
        #expect(store.loadCachedAudioChapters(for: audiobook) == nil)
        #expect(store.loadCachedChapters(bookId: audiobook.id) == nil)
    }
}
