import Foundation
import Testing

@testable import enve

struct PlaybackResumeRegressionTests {
    @Test func nowPlayingKeepsBookGlobalProgressWhileShowingChapterMetadata() {
        let book = Book(
            id: "book",
            title: "Book",
            duration: 900,
            chapters: [
                Chapter(id: "one", start: 0, end: 300, title: "One", index: 0),
                Chapter(id: "two", start: 300, end: 600, title: "Two", index: 1),
                Chapter(id: "three", start: 600, end: 900, title: "Three", index: 2),
            ]
        )

        let metadata = resolveAudiobookNowPlayingMetadata(
            book: book,
            currentTime: 450,
            playbackDuration: 900
        )

        #expect(metadata.chapterTitle == "Two")
        #expect(metadata.chapterNumber == 2)
        #expect(metadata.chapterCount == 3)
        #expect(metadata.elapsed == 450)
        #expect(metadata.duration == 900)
    }

    @Test func resolvedLocalResumeWinsOverSessionSnapshot() {
        #expect(
            resolvePlaybackResumeTime(
                requestedTime: 420,
                sessionTime: 120,
                duration: 900
            ) == 420
        )
    }

    @Test func sessionSnapshotIsUsedWhenThereIsNoMeaningfulLocalResume() {
        #expect(
            resolvePlaybackResumeTime(
                requestedTime: 0,
                sessionTime: 120,
                duration: 900
            ) == 120
        )
    }

    @Test func outOfRangeResumeResetsToBeginning() {
        #expect(
            resolvePlaybackResumeTime(
                requestedTime: 1_200,
                sessionTime: nil,
                duration: 900
            ) == 0
        )
    }

    @Test func plexProgressUsesTheCurrentTrackAndTrackLocalTime() {
        let providerID = UUID()
        let book = Book(
            id: "13",
            title: "Multi-file MP3 Book",
            duration: 75,
            audioTracks: [
                AudioTrack(id: "14", index: 0, duration: 25, startOffset: 0),
                AudioTrack(id: "15", index: 1, duration: 25, startOffset: 25),
                AudioTrack(id: "16", index: 2, duration: 25, startOffset: 50),
            ],
            libraryId: "2",
            providerId: providerID,
            source: .plex
        )

        let target = resolvePlexProgressTarget(book: book, currentTime: 42)

        #expect(target == PlexProgressTarget(ratingKey: "15", time: 17, duration: 25))
    }

    @Test func playbackTimelinePreservesProviderTrackIdentityAndFormat() {
        let book = Book(id: "13", title: "Book", source: .plex)
        let sessionTrack = AudioTrackInfo(
            id: "15",
            index: 1,
            startOffset: 25,
            duration: 25,
            contentUrl: "https://example.invalid/chapter.m4b",
            mimeType: "audio/mp4",
            title: "Chapter 2"
        )

        let updated = book.withPlaybackSessionTimeline(tracks: [sessionTrack], duration: 25)

        #expect(updated.audioTracks?.first?.id == "15")
        #expect(updated.audioTracks?.first?.format == "audio/mp4")
        #expect(updated.audioTracks?.first?.title == "Chapter 2")
    }

    @Test func playbackSessionTimelineIsProviderNeutral() {
        let sources: [Book.BookSource] = [
            .plex,
            .audiobookshelf,
            .local,
            .smb,
            .webdav,
            .jellyfin,
            .emby,
            .booklore,
            .realdebrid,
            .torbox,
            .komga,
            .kavita,
            .opds,
            .storyteller,
            .bookOrbit,
            .silo,
        ]
        let providerID = UUID()
        let sessionTracks = [
            AudioTrackInfo(
                id: "track-1",
                index: 0,
                startOffset: 0,
                duration: 300,
                contentUrl: "https://example.invalid/track-1.m4b",
                mimeType: "audio/mp4",
                title: "Track 1"
            ),
            AudioTrackInfo(
                id: "track-2",
                index: 1,
                startOffset: 300,
                duration: 300,
                contentUrl: "https://example.invalid/track-2.mp3",
                mimeType: "audio/mpeg",
                title: "Track 2"
            ),
        ]

        for source in sources {
            let book = Book(
                id: "book",
                title: "Book",
                duration: 900,
                source: source,
                backendId: "backend",
                currentTime: 420,
                providerId: providerID,
                libraryId: "library"
            )

            let updated = book.withPlaybackSessionTimeline(tracks: sessionTracks, duration: 600)

            #expect(updated.source == source)
            #expect(updated.providerId == providerID)
            #expect(updated.backendId == "backend")
            #expect(updated.libraryId == "library")
            #expect(updated.currentTime == 420)
            #expect(updated.duration == 600)
            #expect(updated.audioTracks?.map(\.id) == ["track-1", "track-2"])
            #expect(updated.audioTracks?.map(\.startOffset) == [0, 300])
            #expect(updated.audioTracks?.map(\.format) == ["audio/mp4", "audio/mpeg"])
        }
    }
}

@MainActor
struct BookProgressIsolationRegressionTests {
    @Test func rawLegacyProgressCannotResumeAnUnrelatedBook() throws {
        let suiteName = "BookProgressIsolationRegressionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            ["progress": 700.0, "duration": 900.0, "lastUpdated": 1_000.0],
            forKey: "bookProgress_13"
        )

        let store = BookProgressStore(defaults: defaults)
        let freshBook = Book(
            id: "13",
            title: "Fresh Book",
            libraryId: "2",
            providerId: UUID(),
            source: .plex
        )

        #expect(store.loadProgress(for: freshBook) == nil)
    }

    @Test func scopedProgressDoesNotLeakAcrossSourcesWithTheSameRawID() throws {
        let suiteName = "BookProgressIsolationRegressionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BookProgressStore(defaults: defaults)
        let plexBook = Book(
            id: "13",
            title: "Plex Book",
            libraryId: "2",
            providerId: UUID(),
            source: .plex
        )
        let absBook = Book(
            id: "13",
            title: "ABS Book",
            libraryId: "library",
            providerId: UUID(),
            source: .audiobookshelf
        )

        store.saveProgress(for: plexBook, progress: 400, duration: 900)

        #expect(store.loadProgress(for: plexBook)?.progress == 400)
        #expect(store.loadProgress(for: absBook) == nil)
    }
}
