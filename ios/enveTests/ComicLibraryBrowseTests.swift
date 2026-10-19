import Foundation
import Testing

@testable import enve

@MainActor
struct ComicLibraryBrowseTests {
    private let providerId = UUID()

    @Test func volumesGroupByIdentifierAndFollowServerOrder() {
        let books = [
            issue("b2", volume: "v2", volumeTitle: "Volume 2", volumeOrder: 2, issueOrder: 2),
            issue("a1", volume: "v1", volumeTitle: "Volume 1", volumeOrder: 1, issueOrder: 1),
            issue("b1", volume: "v2", volumeTitle: "Volume 2", volumeOrder: 2, issueOrder: 1),
            issue("a2", volume: "v1", volumeTitle: "Volume 1", volumeOrder: 1, issueOrder: 2),
        ]

        let grouping = ComicSeriesGrouping(books: books)

        #expect(grouping.sections.map(\.section) == [.issues])
        let volumes = grouping.sections[0].volumes
        #expect(volumes.map(\.id) == ["issues/v1", "issues/v2"])
        #expect(volumes[0].books.map(\.id) == ["a1", "a2"])
        #expect(volumes[1].books.map(\.id) == ["b1", "b2"])
    }

    @Test func volumesWithMatchingTitlesStayDistinct() {
        let books = [
            issue("first", volume: "100", volumeTitle: "Volume 1", volumeOrder: 1),
            issue("second", volume: "200", volumeTitle: "Volume 1", volumeOrder: 1),
        ]

        let volumes = ComicSeriesGrouping(books: books).sections[0].volumes

        #expect(volumes.count == 2)
        #expect(Set(volumes.map(\.id)) == ["issues/100", "issues/200"])
    }

    @Test func sectionsAppearOnlyWhenPresentAndInSectionOrder() {
        let books = [
            issue("special", section: .specials),
            issue("issue", section: .issues),
            issue("volume", section: .volumes, volume: "v1"),
        ]

        let grouping = ComicSeriesGrouping(books: books)

        #expect(grouping.sections.map(\.section) == [.issues, .volumes, .specials])
    }

    @Test func singleVolumeGroupsItsIssues() {
        let books = [
            issue("one", volume: "only", volumeOrder: 1),
            issue("two", volume: "only", volumeOrder: 1),
        ]

        let group = ComicSeriesGrouping(books: books).sections[0]

        #expect(group.volumes.count == 1)
        #expect(group.looseBooks.isEmpty)
        #expect(group.bookCount == 2)
    }

    @Test func looseIssuesStaySeparateFromVolumes() {
        let books = [
            issue("loose", issueOrder: 5),
            issue("bound", volume: "v1", volumeOrder: 1),
        ]

        let group = ComicSeriesGrouping(books: books).sections[0]

        #expect(group.looseBooks.map(\.id) == ["loose"])
        #expect(group.orderedBooks.map(\.id) == ["loose", "bound"])
    }

    @Test func rangesAndCollectedEditionsRemainSeparatePublications() {
        let books = [
            issue("range", title: "Saga #1-6", label: "1-6", issueOrder: 1),
            issue("single", title: "Saga #1", label: "1", issueOrder: 1),
            issue("range", title: "Saga #1-6", label: "1-6", issueOrder: 1),
        ]

        let group = ComicSeriesGrouping(books: books).sections[0]

        #expect(group.looseBooks.map(\.id) == ["range", "single"])
    }

    @Test func sameTitleOnDifferentServersIsKept() {
        var other = issue("shared", title: "Batman #1")
        other.providerId = UUID()
        let books = [issue("shared", title: "Batman #1"), other]

        #expect(ComicSeriesGrouping(books: books).bookCount == 2)
    }

    @Test func unnumberedIssuesFollowNumberedOnesInServerOrder() {
        let books = [
            issue("annual"),
            issue("two", issueOrder: 2),
            issue("preview"),
            issue("one", issueOrder: 1),
        ]

        let ordered = ComicSeriesGrouping(books: books).sections[0].looseBooks.map(\.id)

        #expect(ordered == ["one", "two", "annual", "preview"])
    }

    @Test func nextUnreadFollowsReadingOrder() {
        var first = issue("one", issueOrder: 1)
        first.isFinished = true
        let books = [issue("three", issueOrder: 3), first, issue("two", issueOrder: 2)]

        #expect(ComicSeriesGrouping(books: books).nextUnread?.id == "two")
    }

    @Test func volumeTitleFallsBackToTypedOrder() {
        let titled = ComicSeriesVolume(id: "a", title: "Book One", order: 1, books: [])
        let numbered = ComicSeriesVolume(id: "b", title: nil, order: 3, books: [])
        let unnamed = ComicSeriesVolume(id: "c", title: "", order: nil, books: [])

        #expect(titled.displayTitle == "Book One")
        #expect(numbered.displayTitle == "Volume 3")
        #expect(unnamed.displayTitle == "Volume")
    }

    @Test func comicsMediaMatchesOnlyComicEbooks() {
        let comic = issue("comic")
        let epub = Book(id: "epub", title: "Novel", source: .kavita, mediaType: .ebook, ebookFormat: "epub")
        let audiobook = Book(id: "audio", title: "Audio", source: .audiobookshelf, mediaType: .audiobook)

        #expect(LibraryMediaFilter.comics.matches(comic))
        #expect(!LibraryMediaFilter.comics.matches(epub))
        #expect(!LibraryMediaFilter.comics.matches(audiobook))
        #expect(LibraryMediaFilter.comics.mediaTypeRaw == "ebook")
        #expect(LibraryMediaFilter.ebooks.matches(comic))
        #expect(LibraryMediaFilter.ebooks.matches(epub))
        #expect(LibraryMediaFilter.all.matches(audiobook))
    }

    @Test func comicsDefaultToSeriesWithoutSavedPreference() throws {
        let defaults = try isolatedDefaults()
        defaults.set(LibraryFacet.authors.rawValue, forKey: LibraryBrowsePreferences.facetKey)
        defaults.set(LibraryLayout.list.rawValue, forKey: LibraryLayout.defaultsKey)

        let comics = LibraryBrowsePreferences.load(media: .comics, source: .all, defaults: defaults)
        let ebooks = LibraryBrowsePreferences.load(media: .ebooks, source: .all, defaults: defaults)

        #expect(comics == LibraryBrowsePreferences(facet: .series, layout: .list))
        #expect(ebooks == LibraryBrowsePreferences(facet: .authors, layout: .list))
    }

    @Test func comicsPreferencesArePerScopeAndLeaveGlobalChoicesAlone() throws {
        let defaults = try isolatedDefaults()
        let library = LibrarySourceFilter.library(providerId: providerId, libraryId: "comics")
        defaults.set(LibraryFacet.genres.rawValue, forKey: LibraryBrowsePreferences.facetKey)

        LibraryBrowsePreferences.save(facet: .books, media: .comics, source: library, defaults: defaults)
        LibraryBrowsePreferences.save(layout: .grid, media: .comics, source: library, defaults: defaults)

        #expect(
            LibraryBrowsePreferences.load(media: .comics, source: library, defaults: defaults)
                == LibraryBrowsePreferences(facet: .books, layout: .grid)
        )
        #expect(
            LibraryBrowsePreferences.load(media: .comics, source: .connection(providerId), defaults: defaults)
                == LibraryBrowsePreferences(facet: .series, layout: .list)
        )
        #expect(defaults.string(forKey: LibraryBrowsePreferences.facetKey) == LibraryFacet.genres.rawValue)
        #expect(defaults.string(forKey: LibraryLayout.defaultsKey) == nil)
    }

    @Test func comicsIgnoreSavedFacetsTheyDoNotOffer() throws {
        let defaults = try isolatedDefaults()
        LibraryBrowsePreferences.save(facet: .narrators, media: .comics, source: .all, defaults: defaults)

        #expect(LibraryBrowsePreferences.load(media: .comics, source: .all, defaults: defaults).facet == .series)
    }

    @Test func switchingSourcesAndReopeningRestoresTheMatchingMediaAndLayout() async throws {
        let fixture = try OfflineAvailabilityFixture()
        let defaults = fixture.session.defaults
        defaults.set("all", forKey: "imagine.library.source")
        defaults.set("ebooks", forKey: "imagine.library.media")
        defaults.set("authors", forKey: LibraryBrowsePreferences.facetKey)
        defaults.set("list", forKey: LibraryLayout.defaultsKey)
        let model = LibraryModel(profileSession: fixture.session)
        model.select(LibraryMediaFilter.comics)
        model.selectLayout(.grid)
        let novels = LibrarySourceFilter.library(providerId: fixture.providerID, libraryId: "novels")
        model.focus(status: .all, media: .ebooks, source: novels, facet: .genres)

        model.select(LibrarySourceFilter.all)
        #expect(model.media == .comics)
        #expect(model.facet == .series)
        #expect(model.layout == .grid)
        model.select(novels)
        #expect(model.media == .ebooks)
        #expect(model.facet == .genres)
        #expect(model.layout == .list)
        let reopened = LibraryModel(profileSession: fixture.session)
        #expect(reopened.sourceFilter == novels)
        #expect(reopened.media == .ebooks)
        #expect(reopened.facet == .genres)
        #expect(reopened.layout == .list)
        await model.reload()
        await fixture.close()
    }

    @Test func summaryReportsIssuesAndUnread() {
        #expect(ComicSeriesFormat.summary(total: 1, unread: 1) == "1 issue · 1 unread")
        #expect(ComicSeriesFormat.summary(total: 12, unread: 0) == "12 issues · All read")
    }

    private func issue(
        _ id: String,
        title: String? = nil,
        section: ComicSection = .issues,
        volume: String? = nil,
        volumeTitle: String? = nil,
        volumeOrder: Double? = nil,
        label: String? = nil,
        issueOrder: Double? = nil
    ) -> Book {
        Book(
            id: id,
            title: title ?? id,
            source: .komga,
            mediaType: .ebook,
            ebookFormat: "cbz",
            comicMetadata: ComicMetadata(
                seriesID: "series",
                section: section,
                volumeID: volume,
                volumeTitle: volumeTitle,
                volumeOrder: volumeOrder,
                issueLabel: label,
                issueOrder: issueOrder
            ),
            providerId: providerId,
            libraryId: "comics"
        )
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "ComicLibraryBrowseTests.\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: suite))
    }
}
