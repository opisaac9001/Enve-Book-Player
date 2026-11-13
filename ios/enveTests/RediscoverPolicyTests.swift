import Foundation
import Testing

@testable import enve

struct RediscoverPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let provider = UUID()
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    @Test func pausedBooksSurfaceOnlyAfterThreeWeeks() {
        var hidden = book("hidden", currentTime: 600, updated: 40)
        hidden.hideFromContinue = true
        let books = [
            book("paused", currentTime: 600, updated: 22),
            book("recent", currentTime: 600, updated: 10),
            book("finished", currentTime: 600, isFinished: true, updated: 40),
            hidden,
        ]

        let picks = rediscover(books)

        #expect(picks.map(\.book.id) == ["paused"])
        #expect(picks.first?.reason == .paused(days: 22))
        #expect(picks.first?.reason.label == "Paused 3 weeks")
    }

    @Test func ebooksPauseOnReadingProgressAndWaitWithoutIt() {
        let books = [
            book("reading", mediaType: .ebook, ebookProgress: 0.4, updated: 30),
            book("untouched", mediaType: .ebook, added: 45),
        ]

        let reasons = Dictionary(uniqueKeysWithValues: rediscover(books).map { ($0.book.id, $0.reason) })

        #expect(reasons == ["reading": .paused(days: 30), "untouched": .waiting])
    }

    @Test func unreadAdditionsWaitThirtyDays() {
        let books = [
            book("old", added: 45),
            book("new", added: 10),
            book("undated", added: nil),
        ]

        let picks = rediscover(books)

        #expect(picks.map(\.book.id) == ["old"])
        #expect(picks.first?.reason.label == "Waiting on your shelf")
    }

    @Test func nextInSeriesFollowsTheFinishedPredecessor() {
        let books = [
            book("one", series: "The Expanse", sequence: "1", isFinished: true, added: 200),
            book("two", series: "Expanse", sequence: "2", added: 2),
            book("three", series: "The Expanse", sequence: "3", added: 2),
        ]

        let picks = rediscover(books)

        #expect(picks.map(\.book.id) == ["two"])
        #expect(picks.first?.reason == .nextInSeries)
        #expect(picks.first?.reason.label == "Next in series")
    }

    @Test func seriesGapsAndLaterProgressSuppressSuggestions() {
        let books = [
            book("gap-one", series: "Gap", sequence: "1", isFinished: true, added: 2),
            book("gap-three", series: "Gap", sequence: "3", added: 2),
            book("ahead-one", series: "Ahead", sequence: "1", isFinished: true, added: 2),
            book("ahead-two", series: "Ahead", sequence: "2", added: 2),
            book("ahead-three", series: "Ahead", sequence: "3", currentTime: 300, updated: 2, added: 2),
        ]

        #expect(rediscover(books).isEmpty)
    }

    @Test func fractionalVolumeIsTheNextNumericBook() {
        let books = [
            book("one", series: "Cradle", sequence: "1", isFinished: true, added: 2),
            book("novella", series: "Cradle", sequence: "1.5", added: 2),
            book("two", series: "Cradle", sequence: "2", added: 2),
        ]

        #expect(rediscover(books).map(\.book.id) == ["novella"])
    }

    @Test func seriesPrefersThePredecessorFormatAndCollapsesVariants() {
        let books = [
            book("one-audio", title: "Book One", series: "Saga", sequence: "1", isFinished: true, added: 90),
            book("two-ebook", title: "Book Two", mediaType: .ebook, series: "Saga", sequence: "2", added: 90),
            book("two-audio", title: "Book Two", series: "Saga", sequence: "2", added: 90),
        ]

        let picks = rediscover(books)

        #expect(picks.map(\.book.id) == ["two-audio"])
        #expect(picks.first?.reason == .nextInSeries)
    }

    @Test func engagedFormatsKeepOtherCopiesOffTheShelf() {
        let listening = book("listening", currentTime: 120, updated: 2)
        var linked = book("linked", title: "Linked Ebook", mediaType: .ebook, added: 90)
        linked.linkedAudiobookStableId = listening.stableId
        let books = [
            book("dune-audio", title: "Dune", isFinished: true, added: 90),
            book("dune-ebook", title: "Dune", mediaType: .ebook, added: 90),
            listening,
            linked,
        ]

        #expect(rediscover(books).isEmpty)
    }

    @Test func visibleStartedCopyPreventsUnreadRecommendation() {
        var audio = book("audio", title: "A Novel", currentTime: 120, updated: 1)
        audio.asin = "audio-edition"
        var ebook = book("ebook", title: "A Novel", mediaType: .ebook, added: 60)
        ebook.isbn = "9780000000001"
        let picks = RediscoverPolicy.picks(
            from: [audio, ebook], now: now, calendar: calendar,
            exclusions: .init(stableIds: [audio.stableId])
        )
        #expect(picks.isEmpty)
    }

    @Test func identicallyNamedSeriesByDifferentAuthorsDoNotMix() {
        let first = book("one", series: "Chronicles", sequence: "1", isFinished: true, added: 1)
        var unrelated = book("two", series: "Chronicles", sequence: "2", added: 1)
        unrelated.author = "Another Author"
        #expect(rediscover([first, unrelated]).isEmpty)
    }

    @Test func duplicateSourcesCollapseToOnePick() {
        let books = [
            book("abs-copy", title: "Piranesi", added: 60),
            book("plex-copy", title: "Piranesi", added: 60, providerId: UUID()),
        ]

        #expect(rediscover(books).count == 1)
    }

    @Test func exclusionsRemoveHiddenFilteredAndNonBookItems() {
        let kept = book("kept", added: 60)
        let dismissed = book("dismissed", added: 60)
        let filtered = book("filtered", added: 60, libraryId: "hidden-library")
        var episode = book("episode", added: 60)
        episode.isPodcastEpisode = true
        var comic = book("comic", mediaType: .ebook, added: 60)
        comic.ebookFormat = "cbz"
        let exclusions = RediscoverPolicy.Exclusions(
            stableIds: [dismissed.stableId],
            libraryKeys: ["\(provider.uuidString)_hidden-library"]
        )

        let picks = RediscoverPolicy.picks(
            from: [kept, dismissed, filtered, episode, comic],
            now: now,
            calendar: calendar,
            exclusions: exclusions
        )

        #expect(picks.map(\.book.id) == ["kept"])
    }

    @Test func dailyOrderIsStableWithinADayBoundedAndVariesAcrossDays() {
        let books = (1...20).map { book("waiting-\($0)", added: 60) }

        let morning = rediscover(books).map(\.book.id)
        let evening = RediscoverPolicy.picks(from: books, now: now.addingTimeInterval(3 * 3600), calendar: calendar).map(\.book.id)
        let week = (0..<7).map { day in
            RediscoverPolicy.picks(
                from: books,
                now: now.addingTimeInterval(Double(day) * 86_400),
                calendar: calendar
            ).map(\.book.id)
        }

        #expect(morning.count == RediscoverPolicy.defaultLimit)
        #expect(Set(morning).count == morning.count)
        #expect(morning == evening)
        #expect(Set(week).count > 1)
    }

    @Test func reasonsInterleaveBeforeOneKindFillsTheShelf() {
        var books = (1...10).map { book("waiting-\($0)", added: 60) }
        books.append(book("paused", currentTime: 600, updated: 30))
        books.append(book("first", series: "Mistborn", sequence: "1", isFinished: true, added: 2))
        books.append(book("second", series: "Mistborn", sequence: "2", added: 2))

        let picks = RediscoverPolicy.picks(from: books, now: now, calendar: calendar, limit: 3)

        #expect(picks.map(\.reason) == [.nextInSeries, .paused(days: 30), .waiting])
    }

    @Test func pausedLabelsStayShort() {
        #expect(RediscoverPick.Reason.paused(days: 7).label == "Paused 1 week")
        #expect(RediscoverPick.Reason.paused(days: 56).label == "Paused 8 weeks")
        #expect(RediscoverPick.Reason.paused(days: 90).label == "Paused 3 months")
        #expect(RediscoverPick.Reason.paused(days: 400).label == "Paused over a year")
    }

    private func rediscover(_ books: [Book]) -> [RediscoverPick] {
        RediscoverPolicy.picks(from: books, now: now, calendar: calendar)
    }

    private func book(
        _ id: String,
        title: String? = nil,
        mediaType: AppMediaType = .audiobook,
        series: String? = nil,
        sequence: String? = nil,
        ebookProgress: Double? = nil,
        currentTime: TimeInterval = 0,
        isFinished: Bool = false,
        updated: Int = 0,
        added: Int? = 5,
        libraryId: String = "library",
        providerId: UUID? = nil
    ) -> Book {
        Book(
            id: id,
            title: title ?? id,
            author: "Author",
            seriesInfo: series.map { SeriesInfo(name: $0, sequence: sequence) },
            duration: 36_000,
            mediaType: mediaType,
            ebookProgress: ebookProgress,
            dateAdded: added.map(daysAgo),
            currentTime: currentTime,
            isFinished: isFinished,
            lastUpdate: daysAgo(updated),
            libraryId: libraryId,
            providerId: providerId ?? provider
        )
    }

    private func daysAgo(_ days: Int) -> Date {
        now.addingTimeInterval(-Double(days) * 86_400)
    }
}
