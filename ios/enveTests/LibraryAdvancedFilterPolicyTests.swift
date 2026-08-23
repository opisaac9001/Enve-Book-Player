import Foundation
import Testing

@testable import enve

struct LibraryAdvancedFilterPolicyTests {
    @Test func combinesFacetsWhileKeepingSelectionsWithinAFacetInclusive() {
        let fantasy = book(
            "fantasy",
            genres: ["Fantasy", "Adventure"],
            language: "English",
            rating: 4.4,
            series: "Earthsea"
        )
        let mystery = book(
            "mystery",
            genres: ["Mystery"],
            language: "English",
            rating: 4.2,
            series: nil
        )
        let translated = book(
            "translated",
            genres: ["Fantasy"],
            language: "Spanish",
            rating: 4.8,
            series: "Saga"
        )
        let filters = LibraryAdvancedFilters(
            genres: ["Fantasy", "Mystery"],
            languages: ["English"],
            minimumRating: 4,
            series: .all
        )

        #expect(LibraryAdvancedFilterPolicy.matches(fantasy, filters: filters))
        #expect(LibraryAdvancedFilterPolicy.matches(mystery, filters: filters))
        #expect(!LibraryAdvancedFilterPolicy.matches(translated, filters: filters))
    }

    @Test func ratingAndSeriesPresenceNarrowTogether() {
        let seriesBook = book(
            "series",
            genres: ["Science Fiction"],
            language: "English",
            rating: 4.5,
            series: "The Expanse"
        )
        let standalone = book(
            "standalone",
            genres: ["Science Fiction"],
            language: "English",
            rating: 4.8,
            series: nil
        )
        let filters = LibraryAdvancedFilters(
            minimumRating: 4.5,
            series: .inSeries
        )

        #expect(LibraryAdvancedFilterPolicy.matches(seriesBook, filters: filters))
        #expect(!LibraryAdvancedFilterPolicy.matches(standalone, filters: filters))
    }

    @Test func optionsDeduplicateCaseAndWhitespace() {
        let first = book(
            "one",
            genres: [" Fantasy ", "Adventure"],
            language: "English",
            rating: nil,
            series: nil
        )
        let second = book(
            "two",
            genres: ["fantasy"],
            language: " english ",
            rating: nil,
            series: nil
        )

        let options = LibraryAdvancedFilterPolicy.options(from: [first, second])

        #expect(options.genres.count == 2)
        #expect(options.languages == ["English"])
    }

    @Test func personalRatingQualifiesWhenCommunityRatingDoesNot() {
        let rated = book(
            "rated",
            genres: [],
            language: "English",
            rating: 3.2,
            personalRating: 5,
            series: nil
        )

        #expect(
            LibraryAdvancedFilterPolicy.matches(
                rated,
                filters: LibraryAdvancedFilters(minimumRating: 4.5)
            )
        )
    }

    private func book(
        _ id: String,
        genres: [String],
        language: String,
        rating: Double?,
        personalRating: Double? = nil,
        series: String?
    ) -> Book {
        Book(
            id: id,
            title: id,
            source: .local,
            backendId: "unit",
            series: series,
            personalRating: personalRating,
            goodreadsRating: rating,
            genres: genres,
            language: language,
            providerId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            libraryId: "library"
        )
    }
}
