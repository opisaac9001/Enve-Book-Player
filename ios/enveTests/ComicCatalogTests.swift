import Foundation
import SwiftData
import Testing

@testable import enve

@MainActor
struct ComicCatalogTests {
    @Test func kavitaMangaLibraryExposesVolumesLooseIssuesAndSpecials() async throws {
        let provider = makeKavita(libraryType: 0)
        let books = try await provider.fetchBooks(libraryId: "6")
        let metadata = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0.comicMetadata) })

        #expect(books.map(\.id) == ["9", "9:20:202", "9:21:211", "9:22:221", "9:23:231"])
        #expect(metadata["9"] == ComicMetadata(
            seriesID: "9", section: .volumes, volumeID: "20", volumeTitle: "Volume 1",
            volumeOrder: 1, issueLabel: "Issue 1", issueOrder: 1, pageCount: 20, resourceID: "201"
        ))
        #expect(metadata["9:20:202"]??.volumeID == "20")
        #expect(metadata["9:20:202"]??.issueOrder == 2)
        #expect(metadata["9:21:211"] == ComicMetadata(
            seriesID: "9", section: .volumes, volumeID: "21", volumeTitle: "Volume 2",
            volumeOrder: 2, issueLabel: "Volume 2", issueOrder: nil, pageCount: 30, resourceID: "211"
        ))
        #expect(metadata["9:22:221"] == ComicMetadata(seriesID: "9", section: .issues, issueLabel: "Issue 13", issueOrder: 13, pageCount: 20, resourceID: "221"))
        #expect(metadata["9:23:231"] == ComicMetadata(seriesID: "9", section: .specials, issueLabel: "Art Book", issueOrder: 1, pageCount: 10, resourceID: "231"))
        #expect(books.allSatisfy { $0.isComic })
    }

    @Test func kavitaStrictComicLibraryKeepsIssuesFlat() async throws {
        let provider = makeKavita(libraryType: 5)
        let books = try await provider.fetchBooks(libraryId: "6")

        #expect(books.map(\.id) == ["9", "9:20:202", "9:21:211", "9:22:221", "9:23:231"])
        #expect(books.compactMap(\.comicMetadata).map(\.section) == [.issues, .issues, .issues, .issues, .specials])
        #expect(books.allSatisfy { $0.comicMetadata?.volumeID == nil && $0.comicMetadata?.volumeOrder == nil })
        #expect(books.compactMap { $0.comicMetadata?.issueOrder } == [1, 2, 13, 1])
    }

    @Test func kavitaBookLibrariesAndEpubFilesStayOutOfComics() async throws {
        let bookLibrary = makeKavita(libraryType: 2)
        let books = try await bookLibrary.fetchBooks(libraryId: "6")
        #expect(books.allSatisfy { $0.comicMetadata == nil })

        let epubInMangaLibrary = makeKavita(libraryType: 0)
        epubInMangaLibrary.seriesJSON = #"[{"id":9,"name":"Saga","libraryId":6,"format":3}]"#
        let epubs = try await epubInMangaLibrary.fetchBooks(libraryId: "6")
        #expect(epubs.allSatisfy { $0.comicMetadata == nil && !$0.isComic })
    }

    @Test func kavitaLibraryTypesAreFetchedOncePerProvider() async throws {
        let provider = makeKavita(libraryType: 1)
        _ = try await provider.fetchBooks(libraryId: "6")
        _ = try await provider.fetchFullBookDetails(bookId: "9:22:221", libraryId: "6")
        #expect(provider.requests.filter { $0.url?.path == "/api/Library/libraries" }.count == 1)
        #expect(provider.requests.filter { $0.url?.path == "/api/Series/volumes" }.count == 2)
    }

    @Test func komgaMapsComicFormatsToFlatSeriesIssues() async throws {
        let provider = KomgaCatalogStub(connection: ServerConnection(
            name: "Fixture", url: "https://komga.example.invalid", type: .komga
        ))
        let archive = try await provider.fetchFullBookDetails(bookId: "archive", libraryId: "comics")
        let divina = try await provider.fetchFullBookDetails(bookId: "divina", libraryId: "comics")
        let pdf = try await provider.fetchFullBookDetails(bookId: "pdf", libraryId: "comics")
        let epub = try await provider.fetchFullBookDetails(bookId: "epub", libraryId: "comics")

        #expect(archive.comicMetadata == ComicMetadata(seriesID: "saga", issueLabel: "Issue 5", issueOrder: 5))
        #expect(divina.comicMetadata == ComicMetadata(seriesID: "saga", issueLabel: "Issue 6", issueOrder: 6))
        #expect(pdf.comicMetadata?.seriesID == "saga")
        #expect(pdf.isComic)
        #expect(epub.comicMetadata == nil)
        #expect(!epub.isComic)
        #expect([archive, divina, pdf].allSatisfy { $0.comicMetadata?.section == .issues && $0.comicMetadata?.volumeID == nil })
    }

    @Test func bookCodingAndIsComicHonorMetadata() throws {
        var book = Book(id: "pdf", title: "Saga 1", source: .kavita, mediaType: .ebook, ebookFormat: "pdf")
        #expect(!book.isComic)
        book.comicMetadata = ComicMetadata(seriesID: "9", section: .specials, issueLabel: "Art Book", issueOrder: 3)
        #expect(book.isComic)

        let decoded = try JSONDecoder().decode(Book.self, from: JSONEncoder().encode(book))
        #expect(decoded.comicMetadata == book.comicMetadata)
        #expect(decoded.withPlaybackSessionTimeline(tracks: [], duration: nil).comicMetadata == book.comicMetadata)

        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as? [String: Any] ?? [:]
        legacy.removeValue(forKey: "comicMetadata")
        let legacyBook = try JSONDecoder().decode(Book.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(legacyBook.comicMetadata == nil)

        var audiobook = book
        audiobook.mediaType = .audiobook
        #expect(!audiobook.isComic)
    }

    @Test func recordRoundTripsAndClearsComicMetadata() async throws {
        let store = try makeStore()
        let provider = UUID()
        var book = comic("1", series: "Saga", seriesID: "saga", provider: provider, library: "comics", issue: 1)
        await store.upsertBooks([book])
        #expect(await store.book(uniqueId: book.uniqueId)?.comicMetadata == book.comicMetadata)

        book.comicMetadata = nil
        book.ebookFormat = "epub"
        await store.upsertBooks([book])
        let restored = try #require(await store.book(uniqueId: book.uniqueId))
        #expect(restored.comicMetadata == nil)
        #expect(!restored.isComic)
    }

    @Test func comicSeriesIdentityIsScopedByConnectionLibraryAndServerSeries() async throws {
        let store = try makeStore()
        let first = UUID()
        let second = UUID()
        var regular = Book(id: "novel", title: "Batman Novel", source: .komga, mediaType: .ebook, ebookFormat: "epub",
                           providerId: first, libraryId: "comics")
        regular.series = "Batman"
        var legacy = Book(id: "legacy", title: "Batman Legacy", source: .komga, mediaType: .ebook, ebookFormat: "cbz",
                          providerId: first, libraryId: "comics")
        legacy.series = "Batman"
        await store.upsertBooks([
            comic("2016-1", series: "Batman", seriesID: "run-2016", provider: first, library: "comics", issue: 1),
            comic("2016-2", series: "Batman", seriesID: "run-2016", provider: first, library: "comics", issue: 2),
            comic("2011-1", series: "Batman", seriesID: "run-2011", provider: first, library: "comics", issue: 1),
            comic("other-library", series: "Batman", seriesID: "run-2016", provider: first, library: "manga", issue: 1),
            comic("other-server", series: "Batman", seriesID: "run-2016", provider: second, library: "comics", issue: 1),
            regular,
            legacy,
        ])

        let aggregates = await store.browseSeriesAggregates(mediaType: "ebook")
        #expect(aggregates.count == 6)
        #expect(Set(aggregates.map(\.id)).count == 6)
        #expect(aggregates.filter { !$0.isComic }.map(\.name) == ["Batman"])

        func members(_ aggregate: BrowseSeriesAggregate) async -> [String] {
            await store.seriesBooksPage(for: aggregate, mediaScope: ["ebook"], offset: 0, limit: 100).map(\.id)
        }
        let run2016 = try #require(aggregates.first {
            $0.comicSeriesID == "run-2016" && $0.providerId == first && $0.libraryId == "comics"
        })
        #expect(run2016.bookCount == 2)
        #expect(await members(run2016) == ["2016-1", "2016-2"])
        let run2011 = try #require(aggregates.first { $0.comicSeriesID == "run-2011" })
        #expect(await members(run2011) == ["2011-1"])
        let otherLibrary = try #require(aggregates.first { $0.comicSeriesID == "run-2016" && $0.libraryId == "manga" })
        #expect(await members(otherLibrary) == ["other-library"])
        let otherServer = try #require(aggregates.first { $0.comicSeriesID == "run-2016" && $0.providerId == second })
        #expect(await members(otherServer) == ["other-server"])
        let legacyAggregate = try #require(aggregates.first { $0.isComic && $0.comicSeriesID == nil })
        #expect(legacyAggregate.providerId == first)
        #expect(await members(legacyAggregate) == ["legacy"])
        let regularAggregate = try #require(aggregates.first { !$0.isComic })
        #expect(await members(regularAggregate) == ["novel"])
    }

    @Test func seriesPagePagesBeyondFiveHundredIssuesInServerOrder() async throws {
        let store = try makeStore()
        let provider = UUID()
        var books = (1...650).map {
            comic("issue-\($0)", series: "Long Run", seriesID: "long", provider: provider, library: "comics", issue: Double($0))
        }
        books.append(comic("special", series: "Long Run", seriesID: "long", provider: provider, library: "comics",
                           section: .specials, issue: 1))
        books.append(comic("unnumbered", series: "Long Run", seriesID: "long", provider: provider, library: "comics"))
        books.append(comic("elsewhere", series: "Long Run", seriesID: "other", provider: provider, library: "comics", issue: 1))
        await store.upsertBooks(books.shuffled())
        await store.setHidden(true, stableId: books[9].stableId)

        let aggregate = try #require(await store.browseSeriesAggregates(mediaType: "ebook").first { $0.comicSeriesID == "long" })
        #expect(aggregate.bookCount == 651)

        var paged: [String] = []
        var offset = 0
        while true {
            let page = await store.seriesBooksPage(for: aggregate, mediaScope: ["ebook"], offset: offset, limit: 100)
            paged += page.map(\.id)
            offset += page.count
            if page.count < 100 { break }
        }
        let expected = (1...650).filter { $0 != 10 }.map { "issue-\($0)" } + ["unnumbered", "special"]
        #expect(paged == expected)
        #expect(await store.seriesBooksPage(for: aggregate, mediaScope: ["audiobook"], offset: 0, limit: 10).isEmpty)
    }

    @Test func standaloneComicsRemainSeparateAndOpenWithoutSeriesMetadata() async throws {
        let store = try makeStore()
        let provider = UUID()
        let books = ["first", "second"].map { id in
            Book(id: id, title: "One Shot", source: .komga, mediaType: .ebook, ebookFormat: "cbz",
                 providerId: provider, libraryId: "comics")
        }
        await store.upsertBooks(books)

        let aggregates = await store.browseSeriesAggregates(mediaType: "ebook")
        #expect(aggregates.count == 2)
        #expect(Set(aggregates.map(\.id)).count == 2)
        #expect(Set(aggregates.compactMap(\.standaloneBookUniqueID)) == Set(books.map(\.uniqueId)))
        for aggregate in aggregates {
            #expect(aggregate.isComic)
            #expect(aggregate.name == "One Shot")
            #expect(aggregate.bookCount == 1)
            let resolved = await store.seriesAggregate(for: aggregate)
            #expect(resolved?.id == aggregate.id)
            let page = await store.seriesBooksPage(for: aggregate, mediaScope: ["ebook"], offset: 0, limit: 200)
            #expect(page.map(\.uniqueId) == [aggregate.standaloneBookUniqueID].compactMap { $0 })
        }
    }

    @Test func resumePrefersMostRecentUnfinishedThenFirstUnread() async throws {
        let store = try makeStore()
        let provider = UUID()
        await store.upsertBooks([
            comic("1", series: "Saga", seriesID: "saga", provider: provider, library: "comics", issue: 1, progress: 1),
            comic("2", series: "Saga", seriesID: "saga", provider: provider, library: "comics", issue: 2),
            comic("3", series: "Saga", seriesID: "saga", provider: provider, library: "comics", issue: 3,
                  progress: 0.3, lastUpdate: Date(timeIntervalSince1970: 100)),
            comic("4", series: "Saga", seriesID: "saga", provider: provider, library: "comics", issue: 4,
                  progress: 0.6, lastUpdate: Date(timeIntervalSince1970: 200)),
            comic("a", series: "Paper Girls", seriesID: "paper", provider: provider, library: "comics", issue: 1, progress: 1),
            comic("b", series: "Paper Girls", seriesID: "paper", provider: provider, library: "comics", issue: 3),
            comic("c", series: "Paper Girls", seriesID: "paper", provider: provider, library: "comics", issue: 2),
            comic("x", series: "Done", seriesID: "done", provider: provider, library: "comics", issue: 1, progress: 1),
        ])

        let aggregates = await store.browseSeriesAggregates(mediaType: "ebook", providerId: provider, libraryId: "comics")
        let resume = Dictionary(uniqueKeysWithValues: aggregates.map { ($0.comicSeriesID ?? "", $0.resumeBookUniqueID) })
        #expect(resume["saga"] == "\(provider)_4")
        #expect(resume["paper"] == "\(provider)_c")
        #expect(resume["done"] == .some(nil))
        #expect(aggregates.first { $0.comicSeriesID == "saga" }?.completedBookCount == 1)
        let initial = try #require(aggregates.first { $0.comicSeriesID == "saga" })
        await store.updateEbookProgress(
            uniqueId: "\(provider)_4", ebookProgress: 0.8, epubLocator: "comic:8", isFinished: false,
            lastUpdate: Date(timeIntervalSince1970: 300)
        )
        let refreshed = try #require(await store.seriesAggregate(for: initial))
        #expect(refreshed.resumeBookUniqueID == initial.resumeBookUniqueID)
        #expect(refreshed.resumeBookLastUpdate == Date(timeIntervalSince1970: 300))
        #expect(refreshed != initial)
    }

    @Test func comicPageAndCountRespectSourceFilterAndVisibility() async throws {
        let store = try makeStore()
        let first = UUID()
        let second = UUID()
        let device = UUID()
        let hidden = comic("hidden", series: "Saga", seriesID: "saga", provider: first, library: "comics", issue: 9)
        var pdf = comic("pdf", series: "Saga", seriesID: "saga", provider: first, library: "comics", issue: 3)
        pdf.ebookFormat = "pdf"
        var regularPDF = Book(id: "manual", title: "Manual", source: .komga, mediaType: .ebook, ebookFormat: "pdf",
                              providerId: first, libraryId: "comics")
        regularPDF.series = "Saga"
        let epub = Book(id: "novel", title: "Novel", source: .komga, mediaType: .ebook, ebookFormat: "epub",
                        providerId: first, libraryId: "comics")
        var local = Book(id: "local", title: "Local Issue", source: .local, backendId: "device", mediaType: .ebook,
                         ebookFormat: "cbz", providerId: device, libraryId: "")
        local.series = "Local"
        await store.upsertBooks([
            comic("1", series: "Saga", seriesID: "saga", provider: first, library: "comics", issue: 1),
            comic("2", series: "Saga", seriesID: "saga", provider: first, library: "comics", issue: 2),
            comic("manga", series: "Akira", seriesID: "akira", provider: first, library: "manga", issue: 1),
            comic("remote", series: "Akira", seriesID: "akira", provider: second, library: "comics", issue: 1),
            hidden, pdf, regularPDF, epub, local,
        ])
        await store.setHidden(true, stableId: hidden.stableId)

        #expect(await store.comicBookCount(sourceFilter: .all) == 6)
        #expect(await store.comicBookCount(sourceFilter: .connection(first)) == 4)
        #expect(await store.comicBookCount(sourceFilter: .library(providerId: first, libraryId: "comics")) == 3)
        #expect(await store.comicBookCount(sourceFilter: .device) == 1)

        let library = await store.comicBooksPage(sourceFilter: .library(providerId: first, libraryId: "comics"), offset: 0, limit: 10)
        #expect(library.map(\.id) == ["1", "2", "pdf"])
        let all = await store.comicBooksPage(sourceFilter: .all, offset: 0, limit: 10).map(\.id)
        #expect(Set(all) == ["1", "2", "pdf", "manga", "remote", "local"])
        #expect(await store.comicBooksPage(sourceFilter: .all, offset: 4, limit: 10).count == 2)
    }

    private func makeStore() throws -> SwiftDataBookStore {
        let schema = Schema(versionedSchema: BookStoreSchemaV2.self)
        let configuration = ModelConfiguration(
            "ComicCatalogTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return SwiftDataBookStore(container: try ModelContainer(for: schema, configurations: [configuration]))
    }

    private func comic(
        _ id: String,
        series: String,
        seriesID: String,
        provider: UUID,
        library: String,
        section: ComicSection = .issues,
        issue: Double? = nil,
        progress: Double? = nil,
        lastUpdate: Date = .distantPast
    ) -> Book {
        var book = Book(id: id, title: "\(series) \(id)", source: .komga, mediaType: .ebook, ebookFormat: "cbz",
                        providerId: provider, libraryId: library)
        book.series = series
        book.comicMetadata = ComicMetadata(seriesID: seriesID, section: section, issueOrder: issue)
        book.ebookProgress = progress
        book.isFinished = (progress ?? 0) >= 1
        book.lastUpdate = lastUpdate
        return book
    }

    private func makeKavita(libraryType: Int) -> KavitaCatalogStub {
        let provider = KavitaCatalogStub(connection: ServerConnection(
            name: "Fixture", url: "https://kavita.example.invalid", type: .kavita, token: "fixture"
        ))
        provider.librariesJSON = #"[{"id":6,"name":"Fixture","type":\#(libraryType)}]"#
        return provider
    }
}

private final class KavitaCatalogStub: KavitaProvider, @unchecked Sendable {
    var requests: [URLRequest] = []
    var librariesJSON = ""
    var seriesJSON = #"[{"id":9,"name":"Saga","libraryId":6,"format":1}]"#
    let volumesJSON = """
        [
          {"id":20,"name":"1","minNumber":1,"chapters":[
            {"id":201,"range":"1","minNumber":1,"sortOrder":1,"pages":20},
            {"id":202,"range":"2","minNumber":2,"sortOrder":2,"pages":20}]},
          {"id":21,"name":"2","minNumber":2,"chapters":[
            {"id":211,"range":"-100000","minNumber":-100000,"pages":30}]},
          {"id":22,"name":"-100000","minNumber":-100000,"chapters":[
            {"id":221,"range":"13","minNumber":13,"sortOrder":13,"pages":20}]},
          {"id":23,"name":"100000","minNumber":100000,"chapters":[
            {"id":231,"range":"","title":"Art Book","isSpecial":true,"sortOrder":1,"pages":10}]}
        ]
        """

    override func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        let data: Data
        switch url.path {
        case "/api/Library/libraries": data = Data(librariesJSON.utf8)
        case "/api/Series/v2": data = Data(seriesJSON.utf8)
        case "/api/Series/9": data = Data(#"{"id":9,"name":"Saga","libraryId":6,"format":1}"#.utf8)
        case "/api/Series/volumes": data = Data(volumesJSON.utf8)
        default: throw ProviderError.invalidResponse
        }
        return (data, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
}

private final class KomgaCatalogStub: KomgaProvider, @unchecked Sendable {
    override func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let media: String
        let number: Int
        switch url.lastPathComponent {
        case "archive":
            media = #"{"mediaType":"application/zip","mediaProfile":"DIVINA"}"#
            number = 5
        case "divina":
            media = #"{"mediaType":"application/epub+zip","mediaProfile":"EPUB","epubDivinaCompatible":true}"#
            number = 6
        case "pdf":
            media = #"{"mediaType":"application/pdf","mediaProfile":"PDF"}"#
            number = 7
        case "epub":
            media = #"{"mediaType":"application/epub+zip","mediaProfile":"EPUB","epubDivinaCompatible":false}"#
            number = 8
        default:
            throw ProviderError.invalidResponse
        }
        let json = """
            {"id":"\(url.lastPathComponent)","name":"Book","seriesId":"saga","seriesTitle":"Saga","libraryId":"comics",
             "media":\(media),"metadata":{"number":"\(number)","numberSort":\(number)}}
            """
        return (Data(json.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
}
