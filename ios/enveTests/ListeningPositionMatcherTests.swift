import Foundation
import SwiftData
import Testing

@testable import enve

@MainActor
struct ListeningPositionMatcherTests {
    private let shared = try! ListeningPositionPayload(
        positionMilliseconds: 3_600_000,
        durationMilliseconds: 54_000_000,
        title: "Ender's Game",
        authors: ["Orson Scott Card"],
        narrators: ["Stefan Rudnicki"],
        series: "Ender Quintet",
        seriesSequence: "1"
    )

    @Test func copiesOnDifferentAccountsAreAllKeptAndRankedByRecording() {
        let sameRecording = makeBook(id: "a", title: "Ender's Game", author: "Orson Scott Card", narrator: "Stefan Rudnicki", duration: 54_030)
        let otherAccountLongerEdition = makeBook(id: "a", title: "Ender's Game (Unabridged)", author: "Orson Scott Card", duration: 61_200)

        let ranked = ListeningPositionMatcher.rank([otherAccountLongerEdition, sameRecording], for: shared)

        #expect(ranked.map(\.id) == [sameRecording.uniqueId, otherAccountLongerEdition.uniqueId])
        #expect(ranked.allSatisfy { $0.hasCredibleIdentity })
        #expect(ranked[0].signals.contains(.sameLength))
        #expect(ranked[0].signals.contains(.sameNarrator))
        #expect(ranked[0].warnings.isEmpty)
        #expect(ranked[1].warnings.contains(.lengthDiffers(minutes: 120)))
        #expect(ranked[1].warnings.contains(.lengthUnknown) == false)
    }

    @Test func titleAndAuthorEstablishIdentityBeforeLength() {
        let differentBookSameLength = makeBook(id: "b", title: "Speaker for the Dead", author: "Orson Scott Card", duration: 54_000)
        let sameTitleOtherAuthor = makeBook(id: "c", title: "Ender's Game", author: "Someone Else", duration: 54_000)
        let sameBookUnknownLength = makeBook(id: "d", title: "Ender’s Game", author: "Orson Scott Card", duration: nil)

        let ranked = ListeningPositionMatcher.rank([differentBookSameLength, sameTitleOtherAuthor, sameBookUnknownLength], for: shared)

        let byId = Dictionary(uniqueKeysWithValues: ranked.map { ($0.book.id, $0) })
        #expect(byId["b"]?.hasCredibleIdentity == false)
        #expect(byId["b"]?.warnings.contains(.titleDiffers) == true)
        #expect(byId["c"]?.hasCredibleIdentity == false)
        #expect(byId["c"]?.warnings.contains(.authorDiffers) == true)
        #expect(byId["d"]?.hasCredibleIdentity == true)
        #expect(byId["d"]?.warnings == [.lengthUnknown])
        #expect(ranked.first?.book.id == "d")
    }

    @Test func mismatchesAreWarnedAndPastTheEndCannotBeApplied() {
        let otherNarratorShortCopy = makeBook(id: "e", title: "Ender's Game", author: "Orson Scott Card", narrator: "Somebody Different", duration: 3000)
        let wrongVolume = makeBook(id: "f", title: "Ender's Game", author: "Orson Scott Card", duration: 54_000, series: "Ender Quintet", seriesNumber: 2)

        let narrator = ListeningPositionMatcher.evaluate(otherNarratorShortCopy, against: shared)
        #expect(narrator.warnings.contains(.narratorDiffers))
        #expect(narrator.warnings.contains(.positionBeyondEnd))
        #expect(narrator.canApply == false)

        let volume = ListeningPositionMatcher.evaluate(wrongVolume, against: shared)
        #expect(volume.warnings.contains(.seriesPositionDiffers))
        #expect(volume.canApply)
    }

    @Test func matchingIdentifierIsCredibleDespiteRetitling() throws {
        let payload = try ListeningPositionPayload(
            positionMilliseconds: 0,
            durationMilliseconds: 1_000_000,
            title: "Original Title",
            authors: ["Author"],
            asin: "B000000001"
        )
        let retitled = makeBook(id: "g", title: "Completely Different Name", author: "Translator", duration: 1000, asin: "b000000001")

        let candidate = ListeningPositionMatcher.evaluate(retitled, against: payload)

        #expect(candidate.hasCredibleIdentity)
        #expect(candidate.signals.contains(.sameIdentifier))
    }

    @Test func rankingSkipsNonAudiobooks() {
        let ebook = makeBook(id: "h", title: "Ender's Game", author: "Orson Scott Card", duration: 54_000, mediaType: .ebook)
        #expect(ListeningPositionMatcher.rank([ebook], for: shared).isEmpty)
    }

    @Test func readingCodesSearchEbooksWithoutAudioLengthWarnings() async throws {
        let location = try ListeningPositionReadingLocation(format: "epub", progressionUnits: 250_000)
        let payload = try ListeningPositionPayload(positionMilliseconds: 0, durationMilliseconds: 0,
            title: "Ender's Game", authors: ["Orson Scott Card"], readingLocation: location)
        var ebook = makeBook(id: "epub", title: "Ender's Game", author: "Orson Scott Card", duration: nil, mediaType: .ebook)
        ebook.ebookFormat = "EPUB"
        let audio = makeBook(id: "audio", title: "Ender's Game", author: "Orson Scott Card", duration: 54_000)
        let store = try makeStore()
        await store.upsertBooks([ebook, audio])
        let candidates = await ListeningPositionMatcher.suggestions(for: payload, in: store)
        #expect(candidates.map(\.book.id) == ["epub"])
        #expect(candidates.first?.warnings.isEmpty == true)
        #expect(await ListeningPositionMatcher.search("ender", for: payload, in: store).map(\.book.id) == ["epub"])
    }

    @Test func fixedPageMatchesWarnAboutOtherEditionsAndRejectMissingPages() throws {
        let reading = try ListeningPositionReadingLocation(format: "comic", progressionUnits: 750_000, page: 16, pageCount: 21)
        let payload = try ListeningPositionPayload(positionMilliseconds: 0, durationMilliseconds: 0,
            title: "Ender's Game", authors: ["Orson Scott Card"], readingLocation: reading)
        var comic = makeBook(id: "comic", title: "Ender's Game", author: "Orson Scott Card", duration: nil, mediaType: .ebook)
        comic.ebookFormat = "CBZ"
        comic.comicMetadata = ComicMetadata(seriesID: "series", pageCount: 12)
        let candidate = ListeningPositionMatcher.evaluate(comic, against: payload)
        #expect(candidate.warnings.contains(.pageCountDiffers))
        #expect(candidate.warnings.contains(.positionBeyondEnd))
        #expect(!candidate.canApply)
        var epub = comic
        epub.ebookFormat = "EPUB"
        epub.comicMetadata = nil
        let otherFormat = ListeningPositionMatcher.evaluate(epub, against: payload)
        #expect(otherFormat.warnings == [.formatDiffers])
        #expect(otherFormat.canApply)
    }

    @Test func audioCodesIncludePodcastCandidates() {
        var episode = makeBook(id: "episode", title: "Ender's Game", author: "Orson Scott Card", duration: 54_000, mediaType: .podcast)
        episode.isPodcastEpisode = true
        #expect(ListeningPositionMatcher.rank([episode], for: shared).map(\.book.id) == ["episode"])
    }

    @Test func suggestionsComeFromTheLocalStoreAndSearchFindsWhatTheyOmit() async throws {
        let store = try makeStore()
        let match = makeBook(id: "i", title: "Ender's Game: Special Edition", author: "Orson Scott Card", duration: 54_000)
        let sameAuthorOtherBook = makeBook(id: "j", title: "Xenocide", author: "Orson Scott Card", duration: 70_000)
        let differentlyTitledCopy = makeBook(id: "k", title: "Battle School", author: "O. S. Card", duration: 54_000)
        await store.upsertBooks([match, sameAuthorOtherBook, differentlyTitledCopy])

        let suggestions = await ListeningPositionMatcher.suggestions(for: shared, in: store)
        #expect(suggestions.map(\.book.id) == ["i"])

        let searched = await ListeningPositionMatcher.search("battle", for: shared, in: store)
        #expect(searched.map(\.book.id) == ["k"])
        #expect(searched.first?.hasCredibleIdentity == false)
        #expect(await ListeningPositionMatcher.search("   ", for: shared, in: store).isEmpty)
    }

    private func makeStore() throws -> SwiftDataBookStore {
        let schema = Schema(versionedSchema: BookStoreSchemaV2.self)
        let configuration = ModelConfiguration(
            "ListeningPositionMatcherTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return SwiftDataBookStore(container: try ModelContainer(for: schema, configurations: [configuration]))
    }

    private func makeBook(
        id: String,
        title: String,
        author: String,
        narrator: String? = nil,
        duration: TimeInterval?,
        mediaType: AppMediaType = .audiobook,
        series: String? = nil,
        seriesNumber: Int? = nil,
        asin: String? = nil
    ) -> Book {
        Book(
            id: id,
            ratingKey: id,
            title: title,
            author: author,
            narrator: narrator,
            duration: duration,
            source: .audiobookshelf,
            backendId: UUID().uuidString,
            mediaType: mediaType,
            series: series,
            seriesNumber: seriesNumber,
            asin: asin,
            providerId: UUID(),
            libraryId: "library"
        )
    }
}
