import Foundation
import Testing

@testable import enve

@MainActor
struct OPDSCatalogTraversalTests {
    private static let providerId = UUID(uuidString: "0F17E6A0-1111-4222-8333-444444444444")!
    private let root = URL(string: "https://catalog.example.invalid/opds/root.json")!

    // MARK: OPDS 2 shapes

    @Test func navigationIsDecodedAsLinkObjectsAndNotAsPublications() throws {
        let parsed = try parse(
            """
            {"metadata":{"title":"Root"},
             "links":[{"rel":"self","href":"root.json","type":"application/opds+json"}],
             "navigation":[
               {"href":"fiction.json","title":"Fiction","type":"application/opds+json","rel":"subsection"},
               {"href":"search{?q}","title":"Search","type":"application/opds+json","rel":"search","templated":true},
               {"href":"site.html","title":"Web","type":"text/html"}
             ]}
            """
        )

        #expect(parsed.books.isEmpty)
        #expect(parsed.rejected.isEmpty)
        #expect(parsed.navigationTargets.map(\.absoluteString) == ["https://catalog.example.invalid/opds/fiction.json"])
    }

    @Test func facetsSortsAndSelfLinksAreNeverCrawled() throws {
        let parsed = try parse(
            """
            {"metadata":{"title":"Root"},
             "links":[
               {"rel":"self","href":"root.json","type":"application/opds+json"},
               {"rel":"start","href":"/opds/start.json","type":"application/opds+json"},
               {"rel":"search","href":"/opds/search.json","type":"application/opds+json"},
               {"rel":"http://opds-spec.org/sort/new","href":"/opds/new.json","type":"application/opds+json"},
               {"rel":"http://opds-spec.org/shelf","href":"/opds/shelf.json","type":"application/opds+json"}
             ],
             "facets":[{"metadata":{"title":"Language"},
               "links":[{"rel":"http://opds-spec.org/facet","href":"/opds/fr.json","type":"application/opds+json"}]}]}
            """
        )

        #expect(parsed.navigationTargets.isEmpty)
        #expect(parsed.nextPage == nil)
    }

    @Test func catalogEntriesBecomeNavigationRatherThanGhostBooks() throws {
        let parsed = try parse(
            """
            {"metadata":{"title":"Libraries"},
             "links":[{"rel":"self","href":"root.json","type":"application/opds+json"}],
             "catalogs":[
               {"metadata":{"title":"City Library","description":"A library"},
                "links":[{"rel":"http://opds-spec.org/catalog","href":"city.json","type":"application/opds+json"}],
                "images":[{"href":"logo.png","type":"image/png"}]},
               {"metadata":{"title":"County Library"},
                "links":[{"href":"county.json","type":"application/opds+json"}]}
             ]}
            """
        )

        #expect(parsed.books.isEmpty)
        #expect(
            parsed.navigationTargets.map(\.absoluteString) == [
                "https://catalog.example.invalid/opds/city.json",
                "https://catalog.example.invalid/opds/county.json",
            ]
        )
    }

    @Test func groupPublicationsAreCollectedAndTheGroupSelfLinkIsFollowed() throws {
        let parsed = try parse(
            """
            {"metadata":{"title":"Root"},
             "links":[{"rel":"self","href":"root.json","type":"application/opds+json"}],
             "groups":[
               {"metadata":{"title":"New"},
                "links":[{"rel":"self","href":"new.json","type":"application/opds+json"}],
                "publications":[
                  {"metadata":{"identifier":"urn:isbn:1","title":"Grouped"},
                   "links":[{"rel":"http://opds-spec.org/acquisition/open-access","href":"g1.epub","type":"application/epub+zip"}]}
                ]},
               {"metadata":{"title":"Browse"},
                "navigation":[{"href":"browse.json","title":"Browse","type":"application/opds+json"}]}
             ]}
            """
        )

        #expect(parsed.books.map(\.id) == ["urn:isbn:1"])
        #expect(
            parsed.navigationTargets.map(\.absoluteString) == [
                "https://catalog.example.invalid/opds/new.json",
                "https://catalog.example.invalid/opds/browse.json",
            ]
        )
    }

    @Test func aPublicationKeepsItsIdentifierRatherThanAnExpiringAcquisitionURL() throws {
        let parsed = try parse(
            """
            {"metadata":{"title":"Root"},"links":[{"rel":"self","href":"root.json","type":"application/opds+json"}],
             "publications":[
               {"metadata":{"identifier":"urn:uuid:stable","title":"Identified","language":"fr",
                 "author":{"name":"A. Author"},"narrator":["N. Narrator"],"publisher":"House",
                 "subject":["Sci-Fi","Space"],"published":"1984-06-08T00:00:00Z",
                 "belongsTo":{"series":{"name":"Arc","position":3}}},
                "images":[{"href":"cover.jpg","type":"image/jpeg"}],
                "links":[{"rel":"self","href":"pub/1","type":"application/opds-publication+json"},
                         {"rel":"http://opds-spec.org/acquisition","href":"dl?token=expires-soon","type":"application/epub+zip"}]},
               {"metadata":{"title":"Anonymous"},
                "links":[{"rel":"self","href":"pub/2","type":"application/opds-publication+json"},
                         {"rel":"http://opds-spec.org/acquisition","href":"dl2?token=expires-soon","type":"application/epub+zip"}]}
             ]}
            """
        )

        let identified = try #require(parsed.books.first)
        #expect(identified.id == "urn:uuid:stable")
        #expect(identified.title == "Identified")
        #expect(identified.author == "A. Author")
        #expect(identified.narrator == "N. Narrator")
        #expect(identified.publisher == "House")
        #expect(identified.language == "fr")
        #expect(identified.genres == ["Sci-Fi", "Space"])
        #expect(identified.publishedYear == 1984)
        #expect(identified.series == "Arc")
        #expect(identified.seriesSequence == "3")
        #expect(identified.ebookFormat == "epub")
        #expect(identified.mediaType == .ebook)
        #expect(identified.thumb == "https://catalog.example.invalid/opds/cover.jpg")
        #expect(identified.partKey == "https://catalog.example.invalid/opds/dl?token=expires-soon")

        // Without an identifier the stable self link is preferred over the token-bearing acquisition URL.
        #expect(parsed.books.last?.id == "https://catalog.example.invalid/opds/pub/2")
    }

    @Test func aLocalizedTitleDoesNotCostThePublication() throws {
        let parsed = try parse(
            """
            {"metadata":{"title":"Root"},"links":[{"rel":"self","href":"root.json","type":"application/opds+json"}],
             "publications":[
               {"metadata":{"identifier":"loc-1","title":{"fr":"Le Livre","en":"The Book"}},
                "links":[{"rel":"http://opds-spec.org/acquisition/open-access","href":"b.epub","type":"application/epub+zip"}]}
             ]}
            """
        )

        #expect(parsed.books.map(\.title) == ["The Book"])
    }

    @Test func aTransactionalOnlyPublicationIsRejectedWithoutMakingThePageIncomplete() throws {
        let parsed = try parse(
            """
            {"metadata":{"title":"Root"},"links":[{"rel":"self","href":"root.json","type":"application/opds+json"}],
             "publications":[
               {"metadata":{"identifier":"buy-1","title":"For Sale"},
                "links":[{"rel":"buy","href":"buy/1","type":"application/epub+zip",
                          "properties":{"price":{"currency":"USD","value":9.99}}}]}
             ]}
            """
        )

        #expect(parsed.books.isEmpty)
        #expect(parsed.rejected.map(\.itemIdentifier) == ["buy-1"])
        #expect(parsed.rejected.first?.reason.contains("9.99 USD") == true)
        // A deliberate, repeatable skip is not data loss, so the snapshot stays trustworthy.
        #expect(parsed.isComplete)
    }

    @Test func anUndecodablePublicationMakesThePageIncomplete() throws {
        let parsed = try parse(
            """
            {"metadata":{"title":"Root"},"links":[{"rel":"self","href":"root.json","type":"application/opds+json"}],
             "publications":[
               {"metadata":{"identifier":"good","title":"Fine"},
                "links":[{"rel":"open-access","href":"g.epub","type":"application/epub+zip"}]},
               {"metadata":{"identifier":"bad"}}
             ]}
            """
        )

        #expect(parsed.books.map(\.id) == ["good"])
        #expect(parsed.rejected.count == 1)
        #expect(parsed.isComplete == false)
    }

    // MARK: OPDS 1 (Atom)

    @Test func atomNavigationEntriesAreFollowedWhileAlternatesAndFacetsAreNot() throws {
        let parsed = try parse(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog">
              <link rel="self" href="root.xml" type="application/atom+xml;profile=opds-catalog"/>
              <link rel="next" href="page2.xml" type="application/atom+xml;profile=opds-catalog"/>
              <link rel="http://opds-spec.org/facet" href="fr.xml" type="application/atom+xml;profile=opds-catalog"/>
              <entry>
                <title>Fiction</title><id>nav:fiction</id>
                <link rel="subsection" href="fiction.xml" type="application/atom+xml;profile=opds-catalog"/>
              </entry>
              <entry>
                <title>About</title><id>nav:about</id>
                <link rel="alternate" href="about.xml" type="application/atom+xml;profile=opds-catalog"/>
              </entry>
              <entry>
                <title>Sorted</title><id>nav:sorted</id>
                <link rel="http://opds-spec.org/sort/new" href="new.xml" type="application/atom+xml;profile=opds-catalog"/>
              </entry>
            </feed>
            """,
            contentType: "application/atom+xml;profile=opds-catalog"
        )

        #expect(parsed.navigationTargets.map(\.absoluteString) == ["https://catalog.example.invalid/opds/fiction.xml"])
        #expect(parsed.nextPage?.absoluteString == "https://catalog.example.invalid/opds/page2.xml")
    }

    @Test func atomAcquisitionEntriesShareTheSameSafeSelection() throws {
        let parsed = try parse(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog">
              <entry>
                <title>Free Book</title><id>urn:free</id>
                <author><name>Writer</name></author>
                <summary>A summary</summary>
                <link rel="http://opds-spec.org/image" href="cover.png" type="image/png"/>
                <link rel="http://opds-spec.org/acquisition/open-access" href="free.epub" type="application/epub+zip"/>
              </entry>
              <entry>
                <title>Adobe Book</title><id>urn:adobe</id>
                <link rel="http://opds-spec.org/acquisition/borrow" href="loan" type="application/atom+xml">
                  <opds:indirectAcquisition type="application/vnd.adobe.adept+xml">
                    <opds:indirectAcquisition type="application/epub+zip"/>
                  </opds:indirectAcquisition>
                </link>
              </entry>
            </feed>
            """,
            contentType: "application/atom+xml;profile=opds-catalog"
        )

        #expect(parsed.books.map(\.id) == ["urn:free"])
        #expect(parsed.books.first?.author == "Writer")
        #expect(parsed.books.first?.ebookFormat == "epub")
        #expect(parsed.books.first?.thumb == "https://catalog.example.invalid/opds/cover.png")
        #expect(parsed.rejected.map(\.itemIdentifier) == ["urn:adobe"])
        #expect(parsed.rejected.first?.reason.contains("Adobe DRM") == true)
    }

    @Test func atomLinkPricesAvailabilityCopiesAndHoldsReachTheSameSafeRules() throws {
        let parsed = try parse(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog">
              <entry>
                <title>Free Of Charge</title><id>urn:free-buy</id>
                <link rel="http://opds-spec.org/acquisition/buy" href="buy.epub" type="application/epub+zip">
                  <opds:price currencycode="USD">0.00</opds:price>
                </link>
              </entry>
              <entry>
                <title>All Copies Out</title><id>urn:loan</id>
                <link rel="http://opds-spec.org/acquisition/borrow" href="loan.epub" type="application/epub+zip">
                  <opds:availability status="unavailable" since="2026-01-10T10:01:11Z" until="2026-01-20T10:01:11Z"/>
                  <opds:copies total="3" available="0"/>
                  <opds:holds total="0" position="0"/>
                </link>
              </entry>
              <entry>
                <title>Withdrawn</title><id>urn:withdrawn</id>
                <link rel="http://opds-spec.org/acquisition" href="gone.epub" type="application/epub+zip">
                  <opds:availability status="unavailable"/>
                </link>
              </entry>
            </feed>
            """,
            contentType: "application/atom+xml;profile=opds-catalog"
        )

        #expect(parsed.books.isEmpty)
        let reasons = Dictionary(
            uniqueKeysWithValues: parsed.rejected.map { ($0.itemIdentifier ?? "", $0.reason) }
        )
        // Zero survives: "free but only for purchase" is not the same as a missing price.
        #expect(reasons["urn:free-buy"]?.contains("0.00 USD") == true)
        #expect(reasons["urn:loan"]?.contains("0 of 3 copies available") == true)
        #expect(reasons["urn:loan"]?.contains("0 holds") == true)
        #expect(reasons["urn:loan"]?.contains("position 0 in the queue") == true)
        #expect(reasons["urn:loan"]?.contains("until 2026-01-20T10:01:11Z") == true)
        // An explicit refusal blocks a plain acquisition that would otherwise have downloaded.
        #expect(reasons["urn:withdrawn"]?.contains("unavailable") == true)
        #expect(parsed.isComplete)
    }

    @Test func anAtomAvailabilityThatPermitsAccessStillDownloads() throws {
        let parsed = try parse(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog">
              <entry>
                <title>Ready</title><id>urn:ready</id>
                <link rel="http://opds-spec.org/acquisition" href="ready.epub" type="application/epub+zip">
                  <opds:availability status="available" since="2026-01-10T10:01:11Z"/>
                  <opds:copies total="3" available="2"/>
                </link>
              </entry>
            </feed>
            """,
            contentType: "application/atom+xml;profile=opds-catalog"
        )

        #expect(parsed.books.map(\.id) == ["urn:ready"])
        #expect(parsed.rejected.isEmpty)
    }

    @Test(arguments: [
        #"<schema:Series schema:name="Arc" schema:position="3"/>"#,
        #"<schema:Series name="Arc" position="3"/>"#,
    ])
    func atomSchemaSeriesIsDetectedThroughItsQualifiedName(element: String) throws {
        let parsed = try parse(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom" xmlns:schema="http://schema.org">
              <entry>
                <title>Book Three</title><id>urn:series</id>
                \(element)
                <link rel="http://opds-spec.org/acquisition/open-access" href="three.epub" type="application/epub+zip"/>
              </entry>
            </feed>
            """,
            contentType: "application/atom+xml;profile=opds-catalog"
        )

        let book = try #require(parsed.books.first)
        #expect(book.series == "Arc")
        #expect(book.seriesSequence == "3")
    }

    @Test func anEntryWithoutASchemaSeriesKeepsNoSeries() throws {
        let parsed = try parse(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
              <entry>
                <title>Standalone</title><id>urn:standalone</id>
                <link rel="http://opds-spec.org/acquisition/open-access" href="one.epub" type="application/epub+zip"/>
              </entry>
            </feed>
            """,
            contentType: "application/atom+xml;profile=opds-catalog"
        )

        #expect(parsed.books.first?.series == nil)
    }

    // MARK: Traversal

    /// Twelve pages exceed the navigation-depth budget; pagination must not spend it.
    @Test func everyPageOfALongFeedIsImportedAndTheSnapshotStaysComplete() async throws {
        var pages: [String: String] = [:]
        for page in 0..<12 {
            pages[Self.pageURL(page)] = Self.page(index: page, lastIndex: 11)
        }

        let result = try await collect(pages, from: URL(string: Self.pageURL(0))!)

        #expect(result.books.count == 12)
        #expect(result.isComplete)
        #expect(result.notices.isEmpty)
    }

    @Test func aPaginationCycleStopsWithoutReimportingTheSamePage() async throws {
        let pages = [
            Self.pageURL(0): Self.page(index: 0, nextURL: Self.pageURL(1)),
            Self.pageURL(1): Self.page(index: 1, nextURL: Self.pageURL(0)),
        ]

        let result = try await collect(pages, from: URL(string: Self.pageURL(0))!)

        #expect(result.books.count == 2)
        #expect(result.isComplete)
    }

    @Test func truncatedPaginationMarksTheSnapshotIncomplete() async throws {
        var pages: [String: String] = [:]
        for page in 0..<10 {
            pages[Self.pageURL(page)] = Self.page(index: page, nextURL: Self.pageURL(page + 1))
        }

        var limits = OPDSCatalogTraversal.Limits()
        limits.pagesPerFeed = 3
        let result = try await collect(pages, from: URL(string: Self.pageURL(0))!, limits: limits)

        #expect(result.books.count == 3)
        #expect(result.isComplete == false)
        #expect(result.notices.contains { $0.contains("3 pages") })
    }

    @Test func navigationBeyondTheDepthLimitMarksTheSnapshotIncomplete() async throws {
        var pages: [String: String] = [:]
        for depth in 0...6 {
            pages[Self.pageURL(depth)] = """
                {"metadata":{"title":"Level \(depth)"},
                 "links":[{"rel":"self","href":"p\(depth).json","type":"application/opds+json"}],
                 "navigation":[{"href":"p\(depth + 1).json","title":"Deeper","type":"application/opds+json"}]}
                """
        }
        pages[Self.pageURL(7)] = Self.page(index: 7)

        var limits = OPDSCatalogTraversal.Limits()
        limits.navigationDepth = 2
        let result = try await collect(pages, from: URL(string: Self.pageURL(0))!, limits: limits)

        #expect(result.books.isEmpty)
        #expect(result.isComplete == false)
        #expect(result.notices.contains { $0.contains("Navigation depth 2") })
    }

    /// Library → language → genre → alphabet → author is already five levels before a real catalog starts.
    @Test func tenLevelsOfNavigationAreReachedByDefault() async throws {
        var pages: [String: String] = [:]
        for depth in 0..<10 {
            pages[Self.pageURL(depth)] = """
                {"metadata":{"title":"Level \(depth)"},
                 "links":[{"rel":"self","href":"p\(depth).json","type":"application/opds+json"}],
                 "navigation":[{"href":"p\(depth + 1).json","title":"Deeper","type":"application/opds+json"}]}
                """
        }
        pages[Self.pageURL(10)] = Self.page(index: 10)

        let result = try await collect(pages, from: URL(string: Self.pageURL(0))!)

        #expect(result.books.map(\.id) == ["urn:book:10"])
        #expect(result.isComplete)
        #expect(result.notices.isEmpty)
    }

    @Test func theEleventhLevelIsAGuardRailThatMarksTheSnapshotIncomplete() async throws {
        var pages: [String: String] = [:]
        for depth in 0...11 {
            pages[Self.pageURL(depth)] = """
                {"metadata":{"title":"Level \(depth)"},
                 "links":[{"rel":"self","href":"p\(depth).json","type":"application/opds+json"}],
                 "navigation":[{"href":"p\(depth + 1).json","title":"Deeper","type":"application/opds+json"}]}
                """
        }

        let result = try await collect(pages, from: URL(string: Self.pageURL(0))!)

        #expect(result.isComplete == false)
        #expect(result.notices.contains { $0.contains("Navigation depth 10") })
    }

    @Test func theDefaultLimitsKeepTheirRequestAndPageBudgets() {
        let limits = OPDSCatalogTraversal.Limits()

        #expect(limits.navigationDepth == 10)
        #expect(limits.navigationLinksPerFeed == 200)
        #expect(limits.pagesPerFeed == 2000)
        #expect(limits.feedRequests == 5000)
    }

    @Test func aDeadSubFeedIsSkippedAndMarksTheSnapshotIncomplete() async throws {
        let pages = [
            Self.pageURL(0): """
                {"metadata":{"title":"Root"},
                 "links":[{"rel":"self","href":"p0.json","type":"application/opds+json"}],
                 "navigation":[{"href":"p1.json","title":"Alive","type":"application/opds+json"},
                               {"href":"missing.json","title":"Dead","type":"application/opds+json"}]}
                """,
            Self.pageURL(1): Self.page(index: 1),
        ]

        let result = try await collect(pages, from: URL(string: Self.pageURL(0))!)

        #expect(result.books.map(\.id) == ["urn:book:1"])
        #expect(result.isComplete == false)
        #expect(result.notices.contains { $0.contains("could not be read") })
    }

    @Test func anUnreachableRootFeedStillFailsTheWholeImport() async throws {
        await #expect(throws: (any Error).self) {
            try await collect([:], from: URL(string: Self.pageURL(0))!)
        }
    }

    @Test func theGlobalRequestBudgetIsAFiniteGuardThatMarksTheSnapshotIncomplete() async throws {
        var pages: [String: String] = [:]
        for page in 0..<20 {
            pages[Self.pageURL(page)] = Self.page(index: page, nextURL: Self.pageURL(page + 1))
        }

        var limits = OPDSCatalogTraversal.Limits()
        limits.feedRequests = 4
        let result = try await collect(pages, from: URL(string: Self.pageURL(0))!, limits: limits)

        #expect(result.books.count == 4)
        #expect(result.isComplete == false)
        #expect(result.notices.contains { $0.contains("4 feed requests") })
    }

    @Test func booksSeenThroughSeveralGroupsAreCountedOnce() async throws {
        let pages = [
            Self.pageURL(0): """
                {"metadata":{"title":"Root"},
                 "links":[{"rel":"self","href":"p0.json","type":"application/opds+json"}],
                 "navigation":[{"href":"p1.json","title":"A","type":"application/opds+json"},
                               {"href":"p2.json","title":"B","type":"application/opds+json"}]}
                """,
            Self.pageURL(1): Self.page(index: 1),
            Self.pageURL(2): Self.page(index: 1),
        ]

        let result = try await collect(pages, from: URL(string: Self.pageURL(0))!)

        #expect(result.books.map(\.id) == ["urn:book:1"])
        #expect(result.isComplete)
    }

    // MARK: Fixtures

    private static func pageURL(_ index: Int) -> String {
        "https://catalog.example.invalid/opds/p\(index).json"
    }

    private static func page(index: Int, nextURL: String? = nil, lastIndex: Int? = nil) -> String {
        var next = nextURL
        if next == nil, let lastIndex, index < lastIndex { next = pageURL(index + 1) }
        let nextLink = next.map { #",{"rel":"next","href":"\#($0)","type":"application/opds+json"}"# } ?? ""
        return """
            {"metadata":{"title":"Page \(index)"},
             "links":[{"rel":"self","href":"p\(index).json","type":"application/opds+json"}\(nextLink)],
             "publications":[
               {"metadata":{"identifier":"urn:book:\(index)","title":"Book \(index)"},
                "links":[{"rel":"open-access","href":"b\(index).epub","type":"application/epub+zip"}]}
             ]}
            """
    }

    private func parse(_ body: String, contentType: String = "application/opds+json") throws -> OPDSParsedFeed {
        try OPDSFeedParser.parse(
            document: OPDSFeedDocument(url: root, contentType: contentType, data: Data(body.utf8)),
            context: OPDSCatalogContext(providerId: Self.providerId, libraryId: "opds-root")
        )
    }

    private func collect(
        _ pages: [String: String],
        from start: URL,
        limits: OPDSCatalogTraversal.Limits = OPDSCatalogTraversal.Limits()
    ) async throws -> OPDSCatalogTraversal.Result {
        let traversal = OPDSCatalogTraversal(
            context: OPDSCatalogContext(providerId: Self.providerId, libraryId: "opds-root"),
            limits: limits,
            load: { url in
                guard let body = pages[url.absoluteString] else {
                    throw ProviderError.serverError("OPDS feed returned HTTP 404")
                }
                return OPDSFeedDocument(url: url, contentType: "application/opds+json", data: Data(body.utf8))
            }
        )
        return try await traversal.collect(from: start)
    }
}
