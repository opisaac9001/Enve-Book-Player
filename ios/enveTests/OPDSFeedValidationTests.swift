import Foundation
import Testing

@testable import enve

@MainActor
struct OPDSFeedValidationTests {
    private static let providerId = UUID(uuidString: "0F17E6A0-2222-4222-8333-444444444444")!
    private let root = URL(string: "https://catalog.example.invalid/opds/root.json")!

    private static let loginPage = """
        <!DOCTYPE html><html><head><title>Sign in</title></head>
        <body><form action="/login"><input name="password"/></form></body></html>
        """

    // MARK: Content type

    @Test(arguments: [
        "text/html", "text/html; charset=utf-8", "application/xhtml+xml",
        "text/plain", "application/octet-stream", "image/png",
    ])
    func aNonFeedContentTypeIsRefusedWhateverTheBodyLooksLike(contentType: String) {
        #expect(throws: (any Error).self) {
            try parse(#"{"metadata":{"title":"Root"},"publications":[]}"#, contentType: contentType)
        }
    }

    @Test(arguments: [
        "application/opds+json", "application/json", "application/atom+xml;profile=opds-catalog",
        "application/xml", "text/xml", "application/opds-publication+json",
    ])
    func everyFeedContentTypeStillReachesTheParser(contentType: String) throws {
        let body =
            contentType.contains("json")
            ? #"{"metadata":{"title":"Root"},"publications":[]}"#
            : #"<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><title>Root</title></feed>"#

        let parsed = try parse(body, contentType: contentType)

        #expect(parsed.books.isEmpty)
        #expect(parsed.isComplete)
    }

    // MARK: Atom bodies

    @Test func anHTMLLoginPageIsNotAnEmptyAtomFeed() {
        #expect(throws: (any Error).self) {
            try parse(Self.loginPage, contentType: "")
        }
    }

    @Test func anHTMLLoginPageMislabelledAsXMLIsStillRefused() {
        #expect(throws: (any Error).self) {
            try parse(Self.loginPage, contentType: "application/xml")
        }
    }

    @Test func aTruncatedFeedThrowsRatherThanReportingTheBooksItDidRead() {
        #expect(throws: (any Error).self) {
            try parse(
                """
                <?xml version="1.0" encoding="UTF-8"?>
                <feed xmlns="http://www.w3.org/2005/Atom">
                  <entry><title>Half a book</title><id>urn:half</id>
                """,
                contentType: "application/atom+xml"
            )
        }
    }

    @Test func anXMLDocumentThatIsNotAFeedIsRefusedByItsRootElement() {
        #expect(throws: (any Error).self) {
            try parse(
                #"<?xml version="1.0"?><error><code>401</code><message>Unauthorized</message></error>"#,
                contentType: "application/xml"
            )
        }
    }

    @Test func anEmptyBodyIsRefused() {
        #expect(throws: (any Error).self) {
            try parse("", contentType: "application/atom+xml")
        }
    }

    @Test func anOPDS1EntryDocumentIsAValidRoot() throws {
        let parsed = try parse(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <entry xmlns="http://www.w3.org/2005/Atom">
              <title>Standalone</title><id>urn:standalone</id>
              <link rel="http://opds-spec.org/acquisition/open-access" href="s.epub" type="application/epub+zip"/>
            </entry>
            """,
            contentType: "application/atom+xml;type=entry;profile=opds-catalog"
        )

        #expect(parsed.books.map(\.id) == ["urn:standalone"])
    }

    @Test func aGenuinelyEmptyAtomFeedIsAcceptedAsComplete() throws {
        let parsed = try parse(
            #"<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><title>Nothing here</title></feed>"#,
            contentType: "application/atom+xml"
        )

        #expect(parsed.books.isEmpty)
        #expect(parsed.isComplete)
    }

    // MARK: OPDS 2 bodies

    @Test(arguments: [
        #"{"error":"unauthorized","status":401}"#,
        #"{"message":"Please sign in"}"#,
        #"{"metadata":{"title":"Root"}}"#,
        #"{"publications":[]}"#,
        #"{}"#,
        "[]",
        #""just a string""#,
        "42",
    ])
    func arbitraryJSONIsNotAnOPDS2Feed(body: String) {
        #expect(throws: (any Error).self) {
            try parse(body, contentType: "application/opds+json")
        }
    }

    @Test func aGenuinelyEmptyOPDS2FeedIsAcceptedAsComplete() throws {
        let parsed = try parse(
            #"{"metadata":{"title":"Nothing here"},"links":[{"rel":"self","href":"root.json","type":"application/opds+json"}],"publications":[]}"#
        )

        #expect(parsed.books.isEmpty)
        #expect(parsed.isComplete)
    }

    // MARK: Traversal consequences

    @Test func aRootThatAnswersWithALoginPageFailsTheWholeImport() async {
        await #expect(throws: (any Error).self) {
            try await collect([Self.pageURL(0): Document(body: Self.loginPage, contentType: "text/html")])
        }
    }

    @Test func aRootThatAnswersWithArbitraryJSONFailsTheWholeImport() async {
        await #expect(throws: (any Error).self) {
            try await collect([Self.pageURL(0): Document(body: #"{"error":"unauthorized"}"#)])
        }
    }

    @Test func aBranchThatAnswersWithALoginPageOnlyMarksTheSnapshotPartial() async throws {
        let result = try await collect([
            Self.pageURL(0): Document(body: Self.navigationFeed(to: [1, 2])),
            Self.pageURL(1): Document(body: Self.publicationFeed(index: 1)),
            Self.pageURL(2): Document(body: Self.loginPage, contentType: "text/html"),
        ])

        #expect(result.books.map(\.id) == ["urn:book:1"])
        #expect(result.isComplete == false)
        #expect(result.notices.contains { $0.contains("could not be read") })
    }

    @Test func aBranchThatAnswersWithArbitraryJSONOnlyMarksTheSnapshotPartial() async throws {
        let result = try await collect([
            Self.pageURL(0): Document(body: Self.navigationFeed(to: [1, 2])),
            Self.pageURL(1): Document(body: Self.publicationFeed(index: 1)),
            Self.pageURL(2): Document(body: #"{"error":"gone"}"#),
        ])

        #expect(result.books.map(\.id) == ["urn:book:1"])
        #expect(result.isComplete == false)
    }

    @Test func aContinuationPageThatAnswersWithALoginPageOnlyMarksTheSnapshotPartial() async throws {
        let result = try await collect([
            Self.pageURL(0): Document(body: Self.publicationFeed(index: 0, nextIndex: 1)),
            Self.pageURL(1): Document(body: Self.loginPage, contentType: "text/html"),
        ])

        #expect(result.books.map(\.id) == ["urn:book:0"])
        #expect(result.isComplete == false)
        #expect(result.notices.contains { $0.contains("continuation page") })
    }

    // MARK: Fixtures

    private struct Document {
        var body: String
        var contentType = "application/opds+json"
    }

    private static func pageURL(_ index: Int) -> String {
        "https://catalog.example.invalid/opds/p\(index).json"
    }

    private static func navigationFeed(to indexes: [Int]) -> String {
        let links = indexes
            .map { #"{"href":"p\#($0).json","title":"Branch \#($0)","type":"application/opds+json"}"# }
            .joined(separator: ",")
        return """
            {"metadata":{"title":"Root"},
             "links":[{"rel":"self","href":"p0.json","type":"application/opds+json"}],
             "navigation":[\(links)]}
            """
    }

    private static func publicationFeed(index: Int, nextIndex: Int? = nil) -> String {
        let next =
            nextIndex.map { #",{"rel":"next","href":"\#(pageURL($0))","type":"application/opds+json"}"# } ?? ""
        return """
            {"metadata":{"title":"Page \(index)"},
             "links":[{"rel":"self","href":"p\(index).json","type":"application/opds+json"}\(next)],
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

    private func collect(_ pages: [String: Document]) async throws -> OPDSCatalogTraversal.Result {
        let traversal = OPDSCatalogTraversal(
            context: OPDSCatalogContext(providerId: Self.providerId, libraryId: "opds-root"),
            load: { url in
                guard let page = pages[url.absoluteString] else {
                    throw ProviderError.serverError("OPDS feed returned HTTP 404")
                }
                return OPDSFeedDocument(url: url, contentType: page.contentType, data: Data(page.body.utf8))
            }
        )
        return try await traversal.collect(from: URL(string: Self.pageURL(0))!)
    }
}
