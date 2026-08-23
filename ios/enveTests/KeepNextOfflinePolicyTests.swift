import Foundation
import Testing

@testable import enve

struct KeepNextOfflinePolicyTests {
    @Test func seriesCandidatesFollowFractionalSequenceAndSkipFinishedBooks() {
        let providerID = UUID()
        let books = [
            book("three", providerID: providerID, sequence: "3"),
            book("one", providerID: providerID, sequence: "1"),
            book("two-and-a-half", providerID: providerID, sequence: "2.5"),
            book("two", providerID: providerID, sequence: "2"),
            book("four", providerID: providerID, sequence: "4", isFinished: true),
        ]

        let candidates = KeepNextOfflinePolicy.seriesCandidates(current: books[3], books: books)

        #expect(candidates.map(\.id) == ["two-and-a-half", "three"])
    }

    @Test func podcastCandidatesRespectTheDisplayedEpisodeOrder() {
        let providerID = UUID()
        let oldest = episode("oldest", providerID: providerID, date: Date(timeIntervalSince1970: 1))
        let middle = episode("middle", providerID: providerID, date: Date(timeIntervalSince1970: 2))
        let newest = episode("newest", providerID: providerID, date: Date(timeIntervalSince1970: 3))

        #expect(
            KeepNextOfflinePolicy.podcastCandidates(
                current: newest,
                episodes: [oldest, newest, middle],
                newestFirst: true
            ).map(\.id) == ["middle", "oldest"]
        )
        #expect(
            KeepNextOfflinePolicy.podcastCandidates(
                current: oldest,
                episodes: [oldest, newest, middle],
                newestFirst: false
            ).map(\.id) == ["middle", "newest"]
        )
    }

    @Test func onlyDownloadsEnoughItemsToFillTheOfflineWindow() {
        let providerID = UUID()
        let candidates = ["two", "three", "four", "five"].map {
            book($0, providerID: providerID, sequence: nil)
        }

        let needed = KeepNextOfflinePolicy.downloadsNeeded(
            from: candidates,
            targetCount: 3,
            isKeptOffline: { $0.id == "two" }
        )

        #expect(needed.map(\.id) == ["three", "four"])

        let laterDownloadDoesNotShrinkTheWindow = KeepNextOfflinePolicy.downloadsNeeded(
            from: candidates,
            targetCount: 3,
            isKeptOffline: { $0.id == "five" }
        )

        #expect(laterDownloadDoesNotShrinkTheWindow.map(\.id) == ["two", "three", "four"])
    }

    private func book(
        _ id: String,
        providerID: UUID,
        sequence: String?,
        isFinished: Bool = false
    ) -> Book {
        var book = Book(
            id: id,
            title: id,
            seriesInfo: SeriesInfo(name: "The Series", sequence: sequence),
            duration: 600,
            isFinished: isFinished,
            libraryId: "library",
            providerId: providerID
        )
        book.seriesSequence = sequence
        return book
    }

    private func episode(_ id: String, providerID: UUID, date: Date) -> Book {
        Book(
            id: id,
            title: id,
            duration: 600,
            isPodcastEpisode: true,
            episodeId: id,
            podcastLibraryItemId: "show",
            dateAdded: date,
            libraryId: "podcasts",
            providerId: providerID
        )
    }
}
