import Foundation
import Testing

@testable import enve

@MainActor
struct ComicSeriesModelTests {
    @Test(arguments: [false, true])
    func anOpenLegacySeriesAdoptsRefreshedMetadataWithoutLosingItsFilters(filtered: Bool) async throws {
        let fixture = try OfflineAvailabilityFixture()
        var books = (1...2).map { index in
            var book = Book(id: "legacy-\(index)", title: "Issue \(index)", source: .komga, mediaType: .ebook,
                            ebookFormat: "cbz", providerId: fixture.providerID, libraryId: "comics")
            book.series = "Legacy Run"
            book.isFinished = index == 1
            return book
        }
        await fixture.session.bookStore.upsertBooks(books)
        let library = fixture.session.engine.library
        let aggregate = try #require(library.seriesAggregates(from: filtered ? [books[0]] : books).first)
        let model = ComicSeriesModel(
            aggregate: aggregate, mediaScope: ["ebook"], filter: ComicSeriesFilter(status: filtered ? .finished : .all), library: library
        )
        await model.loadInitial()
        for index in books.indices {
            books[index].comicMetadata = ComicMetadata(seriesID: "newly-mapped-run", section: .volumes, volumeID: "v1", volumeOrder: 1, issueOrder: Double(index))
        }
        await fixture.session.bookStore.upsertBooks(books)
        await model.refresh()

        #expect(model.aggregate.comicSeriesID == "newly-mapped-run")
        #expect(model.selectedSection == .volumes)
        #expect(model.grouping.bookCount == (filtered ? 1 : 2))
        #expect(model.totalCount == (filtered ? 1 : 2))
        #expect(model.grouping.orderedBooks.allSatisfy { $0.comicMetadata?.volumeID == "v1" })
        books[1].comicMetadata?.seriesID = "another-run"
        await fixture.session.bookStore.upsertBooks(books)
        #expect(await fixture.session.bookStore.seriesAggregate(for: aggregate) == nil)
        if filtered {
            await fixture.session.bookStore.updateEbookProgress(
                uniqueId: books[0].uniqueId, ebookProgress: 0.2, epubLocator: "comic:1", isFinished: false, lastUpdate: Date()
            )
            await model.refresh()
            #expect(model.totalCount == 0)
            #expect(model.grouping.bookCount == 0)
        }
        await fixture.close()
    }

    @Test func opensSpecialsDirectlyAndKeepsLoadedSectionsOnRefresh() async throws {
        let fixture = try OfflineAvailabilityFixture()
        let books = makeBooks(provider: fixture.providerID)
        await fixture.session.bookStore.upsertBooks(books)
        let aggregate = try #require(await fixture.session.bookStore.browseSeriesAggregates(mediaType: "ebook").first)
        let model = ComicSeriesModel(aggregate: aggregate, mediaScope: ["ebook"], filter: ComicSeriesFilter(), library: fixture.session.engine.library)
        await model.loadInitial()
        let initialIDs = model.grouping.orderedBooks.map(\.id)
        #expect(initialIDs.count == 200)
        #expect(model.sections.map(\.section) == [.issues, .volumes, .specials])

        model.expandedVolumeIds.insert("volumes/v1")
        model.selectSection(.specials)
        await model.loadNextPage()
        #expect(model.looseBooks(in: .specials).map(\.id) == ["special"])
        #expect(model.grouping.bookCount == 201)
        #expect(!model.hasMore(.section(.specials)))

        let changed = books[1]
        await fixture.session.bookStore.updateEbookProgress(
            uniqueId: changed.uniqueId, ebookProgress: 0.4, epubLocator: "comic:1", isFinished: false, lastUpdate: Date()
        )
        await model.refresh()
        #expect(model.selectedSection == .specials)
        #expect(model.expandedVolumeIds == ["volumes/v1"])
        #expect(model.grouping.bookCount == 201)
        #expect(model.continueBook?.uniqueId == changed.uniqueId)
        model.selectSection(.issues)
        #expect(model.looseBooks(in: .issues).map(\.id) == initialIDs)
        await fixture.close()
    }

    @Test func filteredSeriesUsesTheUnfilteredSectionOffset() async throws {
        let fixture = try OfflineAvailabilityFixture()
        let books = makeBooks(provider: fixture.providerID)
        await fixture.session.bookStore.upsertBooks(books)
        let special = try #require(books.last)
        let aggregate = try #require(fixture.session.engine.library.seriesAggregates(from: [special]).first)
        let model = ComicSeriesModel(aggregate: aggregate, mediaScope: ["ebook"], filter: ComicSeriesFilter(), library: fixture.session.engine.library)
        await model.loadInitial()
        #expect(model.selectedSection == .specials)
        #expect(model.grouping.orderedBooks.map(\.id) == ["special"])
        #expect(model.grouping.bookCount == 1)
        await fixture.close()
    }

    @Test func largeVolumesShowHeadersBeforeIssuesAndPageOnlyTheExpandedVolume() async throws {
        let fixture = try OfflineAvailabilityFixture()
        let books = makeVolumeBooks(provider: fixture.providerID)
        await fixture.session.bookStore.upsertBooks(books)
        // Resume on the special so opening the series fetches no issue volume.
        await fixture.session.bookStore.updateEbookProgress(
            uniqueId: try #require(books.last).uniqueId, ebookProgress: 0.3, epubLocator: "comic:1",
            isFinished: false, lastUpdate: Date()
        )
        let aggregate = try #require(await fixture.session.bookStore.browseSeriesAggregates(mediaType: "ebook").first)
        let model = ComicSeriesModel(aggregate: aggregate, mediaScope: ["ebook"], filter: ComicSeriesFilter(), library: fixture.session.engine.library)
        await model.loadInitial()
        #expect(model.selectedSection == .specials)
        #expect(model.grouping.orderedBooks.map(\.id) == ["special"])

        let volumes = model.volumeSummaries(in: .issues)
        #expect(volumes.map(\.volumeID) == ["v1", "v2", "v3"])
        #expect(volumes.map(\.count) == [250, 250, 250])
        #expect(model.directVolume(in: .issues) == nil)
        #expect(model.looseSlice(in: .issues) == nil)

        model.selectSection(.issues)
        await model.loadNextPage()
        #expect(model.grouping.orderedBooks.map(\.id) == ["special"])

        let last = try #require(volumes.last)
        let lastSlice = ComicSeriesSlice.volume(section: .issues, id: "v3")
        model.toggleVolume(last.id)
        await model.loadNextPage(lastSlice)
        #expect(model.books(in: last).count == 200)
        #expect(model.hasMore(lastSlice))
        await model.loadNextPage(lastSlice)
        let lastIDs = model.books(in: last).map(\.id)
        #expect(lastIDs.count == 250)
        #expect(Set(lastIDs).count == 250)
        #expect(lastIDs.allSatisfy { $0.hasPrefix("v3-") })
        #expect(!model.hasMore(lastSlice))
        #expect(model.book(uniqueId: books[0].uniqueId) == nil)
        #expect(model.books(in: volumes[0]).isEmpty)

        let single = try #require(model.directVolume(in: .volumes))
        model.selectSection(.volumes)
        await model.loadNextPage()
        #expect(model.books(in: single).map(\.id) == ["tpb-0", "tpb-1", "tpb-2"])

        model.selectSection(.issues)
        let changed = books[600]
        await fixture.session.bookStore.updateEbookProgress(
            uniqueId: changed.uniqueId, ebookProgress: 0.5, epubLocator: "comic:4", isFinished: false, lastUpdate: Date()
        )
        await model.refresh()
        #expect(model.selectedSection == .issues)
        #expect(model.expandedVolumeIds == [last.id])
        #expect(model.books(in: last).map(\.id) == lastIDs)
        #expect(model.books(in: volumes[0]).isEmpty)
        #expect(model.continueBook?.uniqueId == changed.uniqueId)
        #expect(model.book(uniqueId: changed.uniqueId)?.canonicalEbookProgress ?? 0 > 0.4)
        await fixture.close()
    }

    private func makeVolumeBooks(provider: UUID) -> [Book] {
        let issues = (0..<750).map { index in
            let volume = index / 250 + 1
            return comicBook(id: "v\(volume)-\(index % 250)", provider: provider, metadata: ComicMetadata(
                seriesID: "saga", section: .issues, volumeID: "v\(volume)", volumeTitle: "Volume \(volume)",
                volumeOrder: Double(volume), issueOrder: Double(index % 250)
            ))
        }
        let collected = (0..<3).map { index in
            comicBook(id: "tpb-\(index)", provider: provider, metadata: ComicMetadata(
                seriesID: "saga", section: .volumes, volumeID: "tpb", volumeTitle: "Collected", volumeOrder: 1, issueOrder: Double(index)
            ))
        }
        let special = comicBook(id: "special", provider: provider, metadata: ComicMetadata(seriesID: "saga", section: .specials))
        return issues + collected + [special]
    }

    private func comicBook(id: String, provider: UUID, metadata: ComicMetadata) -> Book {
        var book = Book(id: id, title: id, source: .komga, mediaType: .ebook, ebookFormat: "cbz", providerId: provider, libraryId: "comics")
        book.series = "Saga Run"
        book.comicMetadata = metadata
        return book
    }

    private func makeBooks(provider: UUID) -> [Book] {
        (0...700).map { index in
            let section: ComicSection = index < 650 ? .issues : (index < 700 ? .volumes : .specials)
            var book = Book(id: index == 700 ? "special" : "issue-\(index)", title: "Issue \(index)",
                            source: .komga, mediaType: .ebook, ebookFormat: "cbz", providerId: provider, libraryId: "comics")
            book.series = "Long Run"
            book.comicMetadata = ComicMetadata(
                seriesID: "run", section: section, volumeID: section == .volumes ? "v1" : nil,
                volumeTitle: section == .volumes ? "Volume 1" : nil,
                volumeOrder: section == .volumes ? 1 : nil, issueOrder: Double(index)
            )
            return book
        }
    }
}
