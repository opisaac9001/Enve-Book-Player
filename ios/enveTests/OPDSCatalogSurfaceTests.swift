import Foundation
import Testing

@testable import enve

@MainActor
struct OPDSCatalogSurfaceTests {
    private static let providerId = UUID(uuidString: "0F17E6A0-5555-4555-8555-555555555555")!
    private let root = URL(string: "https://catalog.example.invalid/opds/root.json")!

    private func parse(_ body: String, contentType: String = "application/opds+json") throws -> OPDSParsedFeed {
        try OPDSFeedParser.parse(
            document: OPDSFeedDocument(url: root, contentType: contentType, data: Data(body.utf8)),
            context: OPDSCatalogContext(
                providerId: Self.providerId,
                libraryId: OPDSProvider.rootLibraryId,
                credentialOrigin: root
            )
        )
    }

    // MARK: OPDS 2.0 structure

    private static let structured = """
        {
          "metadata": {
            "title": { "en": "Enve OPDS Lab", "fr": "Laboratoire" },
            "subtitle": "Deterministic fixture",
            "numberOfItems": 10,
            "itemsPerPage": 8,
            "currentPage": 1
          },
          "links": [
            { "rel": "self", "href": "/opds/v2/root.json", "type": "application/opds+json" },
            { "rel": "start", "href": "/opds/v2/root.json", "type": "application/opds+json" },
            { "rel": "search", "href": "/opds/v2/search.json{?query}", "type": "application/opds+json", "templated": true },
            { "rel": "next", "href": "/opds/v2/page2.json", "type": "application/opds+json" },
            { "rel": "first", "href": "/opds/v2/root.json", "type": "application/opds+json" },
            { "rel": "last", "href": "/opds/v2/page2.json", "type": "application/opds+json" }
          ],
          "navigation": [
            { "rel": "subsection", "href": "/opds/v2/nav/ebooks.json", "type": "application/opds+json", "title": "Ebooks",
              "properties": { "numberOfItems": 42 } },
            { "rel": "subsection", "href": "/opds/v2/nav/audiobooks.json", "type": "application/opds+json", "title": "Audiobooks" }
          ],
          "publications": [
            {
              "metadata": { "identifier": "urn:one", "title": "One", "modified": "2026-09-01T12:00:00Z" },
              "links": [{ "rel": "http://opds-spec.org/acquisition", "href": "/files/one.epub", "type": "application/epub+zip" }],
              "images": [
                { "href": "/images/cover.png", "type": "image/png", "width": 600, "height": 900 },
                { "rel": "http://opds-spec.org/image/thumbnail", "href": "/images/thumb.png", "type": "image/png", "width": 200, "height": 300 }
              ]
            }
          ],
          "groups": [
            {
              "metadata": { "title": "New releases" },
              "links": [{ "rel": "self", "href": "/opds/v2/group/new.json", "type": "application/opds+json" }],
              "publications": [
                {
                  "metadata": { "identifier": "urn:two", "title": "Two" },
                  "links": [{ "rel": "http://opds-spec.org/acquisition", "href": "/files/two.epub", "type": "application/epub+zip" }]
                }
              ]
            },
            {
              "metadata": { "title": "Browse" },
              "navigation": [
                { "rel": "subsection", "href": "/opds/v2/nav/edge.json", "type": "application/opds+json", "title": "Edge cases" }
              ]
            }
          ],
          "facets": [
            {
              "metadata": { "title": "Language" },
              "links": [
                { "rel": "http://opds-spec.org/facet", "href": "/opds/v2/facet/en.json", "type": "application/opds+json",
                  "title": "English", "properties": { "numberOfItems": 9 } }
              ]
            }
          ],
          "catalogs": [
            {
              "metadata": { "title": "Partner catalog", "subtitle": "A second catalog" },
              "links": [{ "rel": "http://opds-spec.org/catalog", "href": "/opds/v2/catalog/partner.json", "type": "application/opds+json" }],
              "images": [{ "href": "/images/partner.png", "type": "image/png" }]
            }
          ]
        }
        """

    @Test func theFeedsOwnTitleSurvives() throws {
        let page = try parse(Self.structured).page

        #expect(page.title == "Enve OPDS Lab")
        #expect(page.summary == "Deterministic fixture")
    }

    @Test func navigationKeepsItsTitlesAndCounts() throws {
        let navigation = try parse(Self.structured).page.navigation

        #expect(navigation.map(\.title) == ["Ebooks", "Audiobooks"])
        #expect(navigation.first?.count == 42)
        #expect(navigation.first?.url.absoluteString == "https://catalog.example.invalid/opds/v2/nav/ebooks.json")
    }

    @Test func aGroupKeepsItsTitleItsPreviewAndItsOwnLink() throws {
        let groups = try parse(Self.structured).page.groups

        #expect(groups.map(\.title) == ["New releases", "Browse"])
        #expect(groups.first?.url?.absoluteString == "https://catalog.example.invalid/opds/v2/group/new.json")
        #expect(groups.first?.publications.map(\.title) == ["Two"])
        #expect(groups.last?.navigation.map(\.title) == ["Edge cases"])
    }

    @Test func facetsKeepTheirGroupTitle() throws {
        let facets = try parse(Self.structured).page.facetGroups

        #expect(facets.count == 1)
        #expect(facets.first?.title == "Language")
        #expect(facets.first?.facets.first?.title == "English")
        #expect(facets.first?.facets.first?.count == 9)
    }

    @Test func aCatalogEntryKeepsItsDescription() throws {
        let catalogs = try parse(Self.structured).page.catalogs

        #expect(catalogs.map(\.title) == ["Partner catalog"])
        #expect(catalogs.first?.summary == "A second catalog")
        #expect(catalogs.first?.url.absoluteString == "https://catalog.example.invalid/opds/v2/catalog/partner.json")
    }

    @Test func paginationIsSeparateFromNavigation() throws {
        let page = try parse(Self.structured).page

        #expect(page.pagination.next?.absoluteString == "https://catalog.example.invalid/opds/v2/page2.json")
        #expect(page.pagination.first?.absoluteString == "https://catalog.example.invalid/opds/v2/root.json")
        #expect(page.pagination.last?.absoluteString == "https://catalog.example.invalid/opds/v2/page2.json")
        #expect(page.pagination.numberOfItems == 10)
        #expect(page.pagination.itemsPerPage == 8)
        #expect(page.pagination.currentPage == 1)
        #expect(page.pagination.hasPages)
        // Keep pagination out of child collections so we don't import books twice.
        #expect(!parsed(Self.structured).navigationTargets.contains(page.pagination.next!))
    }

    /// Following facets would import the same books again.
    @Test func facetsAreNotFollowedByTheImport() throws {
        let targets = try parse(Self.structured).navigationTargets.map(\.absoluteString)

        #expect(!targets.contains { $0.contains("/facet/") })
        #expect(targets.contains("https://catalog.example.invalid/opds/v2/nav/ebooks.json"))
        #expect(targets.contains("https://catalog.example.invalid/opds/v2/group/new.json"))
        #expect(targets.contains("https://catalog.example.invalid/opds/v2/catalog/partner.json"))
        #expect(targets.contains("https://catalog.example.invalid/opds/v2/nav/edge.json"))
    }

    @Test func groupMembersAreImportedWithTheRest() throws {
        let parsed = try parse(Self.structured)

        #expect(parsed.books.map(\.id) == ["urn:one", "urn:two"])
        #expect(parsed.page.allPublications.count == 2)
    }

    @Test func aThumbnailIsKeptApartFromTheCover() throws {
        let entry = try #require(parse(Self.structured).page.publications.first)

        #expect(entry.coverURL?.absoluteString == "https://catalog.example.invalid/images/cover.png")
        #expect(entry.thumbnailURL?.absoluteString == "https://catalog.example.invalid/images/thumb.png")
        // Store the full cover. Use the thumbnail only in the browser.
        #expect(entry.book?.thumb == "https://catalog.example.invalid/images/cover.png")
    }

    @Test func theSmallestImageStandsInForAMissingThumbnail() throws {
        let entry = try #require(
            parse(
                """
                {"metadata":{"title":"T"},"publications":[{
                  "metadata":{"identifier":"urn:x","title":"X"},
                  "links":[{"rel":"http://opds-spec.org/acquisition","href":"/x.epub","type":"application/epub+zip"}],
                  "images":[
                    {"href":"/large.png","type":"image/png","width":1200,"height":1800},
                    {"href":"/small.png","type":"image/png","width":200,"height":300}
                  ]}]}
                """
            ).page.publications.first
        )

        #expect(entry.coverURL?.absoluteString == "https://catalog.example.invalid/large.png")
        #expect(entry.thumbnailURL?.absoluteString == "https://catalog.example.invalid/small.png")
    }

    // MARK: Single publication documents

    private static let singlePublication = """
        {
          "metadata": {
            "identifier": "urn:uuid:lab-ebook-001",
            "title": "The Cartographer's Apprentice",
            "modified": "2026-09-01T12:00:00Z"
          },
          "links": [
            { "rel": "self", "href": "/opds/v2/publication/lab-ebook-001.json", "type": "application/opds-publication+json" },
            { "rel": "http://opds-spec.org/acquisition", "href": "/opds/files/lab-ebook-001.epub", "type": "application/epub+zip" }
          ],
          "images": [{ "href": "/opds/images/cover-blue.png", "type": "image/png" }]
        }
        """

    /// Treating this as an empty catalog would delete books during reconciliation.
    @Test func aSinglePublicationDocumentIsOnePublication() throws {
        let parsed = try parse(Self.singlePublication, contentType: "application/opds-publication+json")

        #expect(parsed.books.map(\.id) == ["urn:uuid:lab-ebook-001"])
        #expect(parsed.books.first?.partKey == "https://catalog.example.invalid/opds/files/lab-ebook-001.epub")
        #expect(parsed.isComplete)
    }

    @Test func aPublicationDocumentIsRecognizedWhateverItsDeclaredType() throws {
        let parsed = try parse(Self.singlePublication, contentType: "application/opds+json")

        #expect(parsed.books.count == 1)
    }

    /// An empty collection can have the same metadata and links fields as a publication.
    @Test func anEmptyCollectionIsStillEmpty() throws {
        let parsed = try parse(
            #"{"metadata":{"title":"Nothing here"},"links":[{"rel":"self","href":"/opds/root.json","type":"application/opds+json"}]}"#
        )

        #expect(parsed.books.isEmpty)
        #expect(parsed.rejected.isEmpty)
        #expect(parsed.isComplete)
    }

    // MARK: Modification dates

    /// Using the current time here could make a catalog refresh overwrite newer reading progress.
    @Test func aBookIsStampedWithTheCatalogsOwnDate() throws {
        let book = try #require(parse(Self.structured).books.first)

        #expect(book.lastUpdate == ISO8601Timestamp.parse("2026-09-01T12:00:00Z"))
    }

    @Test func anUndatedEntryNeverLooksNewerThanLocalProgress() throws {
        let book = try #require(
            parse(
                """
                {"metadata":{"title":"T"},"publications":[{
                  "metadata":{"identifier":"urn:undated","title":"Undated"},
                  "links":[{"rel":"http://opds-spec.org/acquisition","href":"/x.epub","type":"application/epub+zip"}]}]}
                """
            ).books.first
        )

        #expect(book.lastUpdate == .distantPast)
    }

    @Test func anAtomEntryIsStampedWithItsUpdatedElement() throws {
        let parsed = try parse(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom" xmlns:dcterms="http://purl.org/dc/terms/">
              <title>Lab</title>
              <entry>
                <id>urn:atom:1</id>
                <title>Harbour Lights</title>
                <updated>2026-09-18T20:15:00Z</updated>
                <dcterms:language>en</dcterms:language>
                <dcterms:issued>2018-04-01</dcterms:issued>
                <category term="FIC000000" label="Fiction"/>
                <link rel="http://opds-spec.org/acquisition" href="/x.epub" type="application/epub+zip"/>
              </entry>
            </feed>
            """,
            contentType: "application/atom+xml"
        )
        let book = try #require(parsed.books.first)

        #expect(book.lastUpdate == ISO8601Timestamp.parse("2026-09-18T20:15:00Z"))
        #expect(book.language == "en")
        #expect(book.publishedYear == 2018)
        #expect(book.genres == ["Fiction"])
    }

    // MARK: Authentication discovery

    @Test func aFeedLinkNamingAnAuthenticationDocumentIsAdopted() throws {
        let page = try parse(
            """
            {"metadata":{"title":"Gated"},"links":[
              {"rel":"self","href":"/opds/root.json","type":"application/opds+json"},
              {"rel":"http://opds-spec.org/auth/document","href":"/opds/auth/basic.json",
               "type":"application/opds-authentication+json"}
            ],"publications":[]}
            """
        ).page

        #expect(
            page.authenticationDocumentURL?.absoluteString
                == "https://catalog.example.invalid/opds/auth/basic.json"
        )
    }

    @Test func aProgressionHintOnTheFeedsOwnOriginNamesTheSignIn() throws {
        let page = try parse(
            """
            {"metadata":{"title":"Lab"},"publications":[{
              "metadata":{"identifier":"urn:hinted","title":"Hinted"},
              "links":[
                {"rel":"http://opds-spec.org/acquisition","href":"/x.epub","type":"application/epub+zip"},
                {"rel":"http://opds-spec.org/progression","href":"/opds/progression/1",
                 "type":"application/opds-progression+json",
                 "properties":{"authenticate":{"href":"/opds/auth/basic.json"}}}
              ]}]}
            """
        ).page

        #expect(
            page.authenticationDocumentURL?.absoluteString
                == "https://catalog.example.invalid/opds/auth/basic.json"
        )
    }

    /// Another host's sign-in document does not belong to this connection.
    @Test func aCrossOriginProgressionHintIsNotTheConnectionsSignIn() throws {
        let page = try parse(
            """
            {"metadata":{"title":"Lab"},"publications":[{
              "metadata":{"identifier":"urn:delegated","title":"Delegated"},
              "links":[
                {"rel":"http://opds-spec.org/acquisition","href":"/x.epub","type":"application/epub+zip"},
                {"rel":"http://opds-spec.org/progression","href":"https://tracker.example.invalid/p",
                 "type":"application/opds-progression+json",
                 "properties":{"authenticate":{"href":"https://tracker.example.invalid/auth.json"}}}
              ]}]}
            """
        ).page

        #expect(page.authenticationDocumentURL == nil)
    }

    @Test func anHTMLNavigationLinkIsAWebCatalogRatherThanAFeed() throws {
        let parsed = try parse(
            """
            {
              "metadata": { "title": "Hybrid catalogue" },
              "navigation": [
                { "rel": "subsection", "href": "/opds/new.json", "type": "application/opds+json", "title": "New" },
                { "rel": "subsection", "href": "/browse", "type": "text/html", "title": "Website" },
                { "rel": "subsection", "href": "javascript:alert(1)", "type": "text/html", "title": "Script" }
              ],
              "groups": [{
                "metadata": { "title": "Reading room" },
                "navigation": [
                  { "rel": "subsection", "href": "https://blog.example.invalid/", "type": "application/xhtml+xml", "title": "Blog" }
                ]
              }]
            }
            """
        )

        #expect(parsed.page.navigation.map(\.title) == ["New"])
        #expect(parsed.page.webCatalogs.map(\.title) == ["Website"])
        #expect(parsed.page.webCatalogs.first?.url.absoluteString == "https://catalog.example.invalid/browse")
        #expect(parsed.page.groups.first?.webCatalogs.map(\.title) == ["Blog"])
        #expect(!parsed.navigationTargets.contains { $0.path == "/browse" })
    }

    @Test func aCatalogEntryPrefersItsFeedOverItsWebsite() throws {
        let page = try parse(
            """
            {"metadata":{"title":"Root"},"catalogs":[
              {"metadata":{"title":"Partner"},"links":[
                {"rel":"http://opds-spec.org/catalog","href":"/partner.json","type":"application/opds+json"},
                {"rel":"http://opds-spec.org/catalog","href":"https://partner.example.invalid/","type":"text/html"}
              ]},
              {"metadata":{"title":"Website"},"links":[
                {"rel":"http://opds-spec.org/catalog","href":"https://website.example.invalid/books","type":"text/html"}
              ]}
            ]}
            """
        ).page

        #expect(page.catalogs.map(\.title) == ["Partner"])
        #expect(page.webCatalogs.map(\.title) == ["Website"])
    }

    // MARK: OPDS 1 structure

    @Test func anAtomNavigationEntryKeepsItsTitle() throws {
        let page = try parse(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog">
              <title>Lab (OPDS 1.2)</title>
              <link rel="search" href="/opds/v1/opensearch.xml" type="application/opensearchdescription+xml"/>
              <link rel="next" href="/opds/v1/page2.xml" type="application/atom+xml"/>
              <link rel="http://opds-spec.org/facet" href="/opds/v1/facet/en.xml"
                    type="application/atom+xml" title="English" opds:facetGroup="Language" opds:activeFacet="true"/>
              <entry>
                <id>urn:nav:all</id>
                <title>All publications</title>
                <content type="text">Every publication, paginated.</content>
                <link rel="subsection" href="/opds/v1/acquisition.xml" type="application/atom+xml"/>
              </entry>
            </feed>
            """,
            contentType: "application/atom+xml"
        ).page

        #expect(page.title == "Lab (OPDS 1.2)")
        #expect(page.navigation.map(\.title) == ["All publications"])
        #expect(page.navigation.first?.summary == "Every publication, paginated.")
        #expect(page.pagination.next?.absoluteString == "https://catalog.example.invalid/opds/v1/page2.xml")
        #expect(page.facetGroups.first?.title == "Language")
        #expect(page.facetGroups.first?.facets.first?.isActive == true)
        #expect(page.search != nil)
    }

    // MARK: Helpers

    private func parsed(_ body: String) -> OPDSParsedFeed {
        (try? parse(body)) ?? OPDSParsedFeed(page: OPDSCatalogPage(url: root))
    }
}
