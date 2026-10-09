import Foundation
import Testing

@testable import enve

@MainActor
struct PlayerChapterServiceTests {
    private let recording = [
        Chapter(id: "0", start: 0, end: 20, title: "Opening"),
        Chapter(id: "1", start: 20, end: 40, title: "Middle"),
    ]

    private final class Recorder {
        var currentBook: Book?
        var playbackUpdates: [[Chapter]] = []
    }

    private func makeService(
        stored: Book,
        server: Book?,
        recorder: Recorder
    ) -> PlayerChapterService {
        PlayerChapterService(
            currentBook: { recorder.currentBook },
            updateCurrentBook: { recorder.currentBook = $0 },
            bookLookup: { _ in stored },
            playbackBookUpdater: { _, chapters in recorder.playbackUpdates.append(chapters) },
            serverBookLookup: { _ in server }
        )
    }

    private func clearCache(for book: Book) {
        ReaderArtifactsStore.shared.clearCachedChapters(bookId: book.stableId)
        ReaderArtifactsStore.shared.clearCachedChapters(bookId: book.id)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: documents.appending(path: "Metadata/\(book.id).json"))
    }

    private func chapterlessAudiobook() -> Book {
        Book(id: "chapter-test-\(UUID().uuidString)", title: "Jurassic Park", source: .audiobookshelf, mediaType: .audiobook)
    }

    @Test func aFinishedDownloadSavesTheServerChaptersForOfflinePlay() async {
        let stored = chapterlessAudiobook()
        defer { clearCache(for: stored) }
        var server = stored
        server.chapters = recording
        let recorder = Recorder()
        recorder.currentBook = Book(id: "other-\(UUID().uuidString)", title: "Other", source: .audiobookshelf, mediaType: .audiobook)
        let service = makeService(stored: stored, server: server, recorder: recorder)

        await service.fetchAndCacheChaptersAfterDownload(bookId: stored.id)

        #expect(ReaderArtifactsStore.shared.loadCachedAudioChapters(for: stored) == recording)
        #expect(service.chapters.isEmpty)
        #expect(recorder.playbackUpdates.isEmpty)
    }

    @Test func serverChaptersReachThePlayingBook() async {
        let stored = chapterlessAudiobook()
        defer { clearCache(for: stored) }
        var server = stored
        server.chapters = recording
        let recorder = Recorder()
        recorder.currentBook = stored
        let service = makeService(stored: stored, server: server, recorder: recorder)

        #expect(await service.refreshChaptersFromServer(for: stored))
        #expect(service.chapters == recording)
        #expect(recorder.currentBook?.chapters == recording)
        #expect(recorder.playbackUpdates == [recording])
    }

    @Test func anUnreachableServerLeavesTheBookForTheEmbeddedFallback() async {
        let stored = chapterlessAudiobook()
        let recorder = Recorder()
        recorder.currentBook = stored
        let service = makeService(stored: stored, server: nil, recorder: recorder)

        #expect(!(await service.refreshChaptersFromServer(for: stored)))
        #expect(ReaderArtifactsStore.shared.loadCachedAudioChapters(for: stored) == nil)
        #expect(recorder.playbackUpdates.isEmpty)
    }
}
