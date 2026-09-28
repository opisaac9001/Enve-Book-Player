import Foundation
import Testing

@testable import enve

@MainActor
struct OPDSAcquisitionActionsTests {
    private static let providerId = UUID(uuidString: "0F17E6A0-7777-4777-8777-777777777777")!
    private let root = URL(string: "https://catalog.example.invalid/opds/root.json")!

    private func entries(_ body: String, contentType: String = "application/opds+json") throws -> [OPDSPublicationEntry] {
        try OPDSFeedParser.parse(
            document: OPDSFeedDocument(url: root, contentType: contentType, data: Data(body.utf8)),
            context: OPDSCatalogContext(providerId: Self.providerId, libraryId: OPDSProvider.rootLibraryId)
        ).page.allPublications
    }

    private func entry(_ publicationJSON: String) throws -> OPDSPublicationEntry {
        try #require(entries(#"{"metadata":{"title":"T"},"publications":[\#(publicationJSON)]}"#).first)
    }

    // MARK: Every acquisition is kept

    @Test func aPublicationKeepsEveryAcquisitionItOffers() throws {
        let entry = try entry(
            """
            {
              "metadata": { "identifier": "urn:many", "title": "Many ways in" },
              "links": [
                { "rel": "http://opds-spec.org/acquisition/buy", "href": "/buy", "type": "text/html",
                  "properties": { "price": { "currency": "USD", "value": 9.99 } } },
                { "rel": "http://opds-spec.org/acquisition/sample", "href": "/sample.epub", "type": "application/epub+zip" },
                { "rel": "http://opds-spec.org/acquisition", "href": "/full.epub", "type": "application/epub+zip" }
              ]
            }
            """
        )

        #expect(entry.acquisitions.count == 3)
        // Put the most permissive usable acquisition first.
        #expect(entry.acquisitions.map(\.kind) == [.direct, .preview, .buy])
        #expect(entry.fulfillable?.url.absoluteString == "https://catalog.example.invalid/full.epub")
        #expect(entry.sample?.url.absoluteString == "https://catalog.example.invalid/sample.epub")
        #expect(entry.transactions.map(\.kind) == [.buy])
        #expect(entry.unavailableReason == nil)
    }

    @Test func aBuyOnlyPublicationIsListedWithItsPrice() throws {
        let entry = try entry(
            """
            {
              "metadata": { "identifier": "urn:buy", "title": "A Commerce of Lanterns" },
              "links": [
                { "rel": "http://opds-spec.org/acquisition/buy", "href": "/buy", "type": "text/html",
                  "properties": { "price": { "currency": "USD", "value": 9.99 },
                                  "indirectAcquisition": [{ "type": "application/epub+zip" }] } }
              ]
            }
            """
        )

        let purchase = try #require(entry.transactions.first)

        #expect(entry.book == nil)
        #expect(entry.fulfillable == nil)
        #expect(purchase.kind == .buy)
        #expect(entry.unavailableReason?.contains("9.99 USD") == true)
        #expect(OPDSAcquisitionSelector.termsText(for: purchase)?.contains("9.99 USD") == true)
        #expect(entry.rejection?.itemIdentifier == "urn:buy")
    }

    @Test func aLoanShowsItsCopiesAndItsQueue() throws {
        let entry = try entry(
            """
            {
              "metadata": { "identifier": "urn:borrow", "title": "The Borrowed Atlas" },
              "links": [
                { "rel": "http://opds-spec.org/acquisition/borrow", "href": "/borrow", "type": "application/epub+zip",
                  "properties": {
                    "availability": { "state": "unavailable", "since": "2026-09-01", "until": "2026-10-01" },
                    "copies": { "total": 4, "available": 0 },
                    "holds": { "total": 3, "position": 2 }
                  } }
              ]
            }
            """
        )
        let loan = try #require(entry.transactions.first)
        let terms = try #require(OPDSAcquisitionSelector.termsText(for: loan))

        // Zero means no copies are available. It is not a missing value.
        #expect(terms.contains("0 of 4 copies available"))
        #expect(terms.contains("3 holds"))
        #expect(terms.contains("position 2 in the queue"))
        #expect(terms.contains("until 2026-10-01"))
    }

    @Test func aSubscriptionIsATransactionToo() throws {
        let entry = try entry(
            """
            {
              "metadata": { "identifier": "urn:sub", "title": "Serial Winter" },
              "links": [
                { "rel": "http://opds-spec.org/acquisition/subscribe", "href": "/subscribe", "type": "application/epub+zip",
                  "properties": { "availability": { "state": "unavailable", "detail": "Subscribers only" } } }
              ]
            }
            """
        )

        #expect(entry.transactions.map(\.kind) == [.subscribe])
        #expect(entry.transactions.first?.kind.actionName == "Subscribe")
        #expect(entry.unavailableReason == "Only offered through a subscription.")
    }

    /// Offer samples separately. Don't import one as the full book.
    @Test func aSampleOnlyPublicationIsNotImportedButIsStillOffered() throws {
        let entry = try entry(
            """
            {
              "metadata": { "identifier": "urn:sample", "title": "Sample only" },
              "links": [
                { "rel": "http://opds-spec.org/acquisition/sample", "href": "/sample.epub", "type": "application/epub+zip" }
              ]
            }
            """
        )

        #expect(entry.book == nil)
        #expect(entry.sample != nil)
        #expect(entry.sample?.kind.actionName == "Download sample")
        #expect(entry.unavailableReason == "Only a preview is offered for this publication.")
    }

    // MARK: Protected and unsupported packaging

    @Test(arguments: [
        ("application/vnd.readium.lcp.license.v1.0+json", "Readium LCP"),
        ("application/vnd.adobe.adept+xml", "Adobe DRM"),
        ("audio/vnd.audible.aax", "Audible DRM"),
    ])
    func protectedPackagingSaysWhichSchemeRefusedIt(type: String, scheme: String) throws {
        let entry = try entry(
            """
            {
              "metadata": { "identifier": "urn:drm", "title": "The Sealed Archive" },
              "links": [{ "rel": "http://opds-spec.org/acquisition", "href": "/x", "type": "\(type)" }]
            }
            """
        )

        #expect(entry.book == nil)
        #expect(entry.unavailableReason == "\(scheme) protected content is not supported.")
    }

    @Test(arguments: [
        ("application/audiobook+zip", "A Readium audiobook package"),
        ("application/audiobook+json", "A Readium audiobook manifest"),
        ("application/webpub+zip", "A Readium Web Publication package"),
        ("application/divina+json", "A DiViNa manifest"),
    ])
    func readiumPackagingIsNamedRatherThanOpened(type: String, name: String) throws {
        let entry = try entry(
            """
            {
              "metadata": { "identifier": "urn:pkg", "title": "Field Notes from the Deep" },
              "links": [{ "rel": "http://opds-spec.org/acquisition", "href": "/x", "type": "\(type)" }]
            }
            """
        )

        #expect(entry.book == nil)
        #expect(entry.unavailableReason == "\(name) is not a format Enve can open.")
    }

    // MARK: Indirect acquisition

    @Test func theDeepestTypeOfAnIndirectChainIsTheFileDelivered() throws {
        let entry = try entry(
            """
            {
              "metadata": { "identifier": "urn:indirect", "title": "Indirect" },
              "links": [{
                "rel": "http://opds-spec.org/acquisition",
                "href": "/entry.xml",
                "type": "application/atom+xml;type=entry;profile=opds-catalog",
                "properties": { "indirectAcquisition": [{ "type": "application/epub+zip" }] }
              }]
            }
            """
        )

        #expect(entry.book?.ebookFormat == "epub")
        #expect(entry.fulfillable?.url.absoluteString == "https://catalog.example.invalid/entry.xml")
    }

    @Test(arguments: [
        "application/atom+xml",
        "application/atom+xml;type=entry;profile=opds-catalog",
        "application/opds+json",
        "application/opds-publication+json; charset=utf-8",
    ])
    func aCatalogDocumentAnsweredByAnAcquisitionIsAHopNotTheFile(contentType: String) throws {
        let response = try #require(
            HTTPURLResponse(
                url: URL(string: "https://catalog.example.invalid/entry.xml")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": contentType]
            )
        )

        #expect(OPDSAcquisitionFulfillment.isCatalogDocument(response))
    }

    @Test(arguments: ["application/epub+zip", "application/pdf", "audio/mpeg", "text/html"])
    func aPublicationBodyIsNotAHop(contentType: String) throws {
        let response = try #require(
            HTTPURLResponse(
                url: URL(string: "https://catalog.example.invalid/x")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": contentType]
            )
        )

        #expect(!OPDSAcquisitionFulfillment.isCatalogDocument(response))
    }

    @Test func anEntryDocumentNamesTheNextHop() throws {
        let requested = URL(string: "https://catalog.example.invalid/entry.xml")!
        let response = try #require(
            HTTPURLResponse(
                url: requested,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/atom+xml;type=entry;profile=opds-catalog"]
            )
        )
        let document = """
            <?xml version="1.0" encoding="UTF-8"?>
            <entry xmlns="http://www.w3.org/2005/Atom">
              <id>urn:uuid:lab-ebook-101</id>
              <title>Fulfilled</title>
              <link rel="http://opds-spec.org/acquisition" href="/opds/files/lab-ebook-101.epub" type="application/epub+zip"/>
            </entry>
            """

        let next = OPDSAcquisitionFulfillment.next(
            from: Data(document.utf8),
            response: response,
            requestedURL: requested,
            context: OPDSCatalogContext(providerId: Self.providerId, libraryId: OPDSProvider.rootLibraryId)
        )

        #expect(next?.absoluteString == "https://catalog.example.invalid/opds/files/lab-ebook-101.epub")
    }

    @Test func aChainThatNeverMovesStops() throws {
        let requested = URL(string: "https://catalog.example.invalid/entry.xml")!
        let response = try #require(
            HTTPURLResponse(
                url: requested,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/atom+xml"]
            )
        )
        let document = """
            <?xml version="1.0" encoding="UTF-8"?>
            <entry xmlns="http://www.w3.org/2005/Atom">
              <id>urn:loop</id><title>Loop</title>
              <link rel="http://opds-spec.org/acquisition" href="/entry.xml" type="application/epub+zip"/>
            </entry>
            """

        let next = OPDSAcquisitionFulfillment.next(
            from: Data(document.utf8),
            response: response,
            requestedURL: requested,
            context: OPDSCatalogContext(providerId: Self.providerId, libraryId: OPDSProvider.rootLibraryId)
        )

        #expect(next == nil)
    }

    @Test func aDocumentOfferingNothingUsableNamesNoHop() throws {
        let requested = URL(string: "https://catalog.example.invalid/entry.xml")!
        let response = try #require(
            HTTPURLResponse(
                url: requested,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/opds-publication+json"]
            )
        )

        let next = OPDSAcquisitionFulfillment.next(
            from: Data(#"{"metadata":{"title":"Nothing"},"links":[{"rel":"http://opds-spec.org/acquisition","href":"/x","type":"application/vnd.adobe.adept+xml"}]}"#.utf8),
            response: response,
            requestedURL: requested,
            context: OPDSCatalogContext(providerId: Self.providerId, libraryId: OPDSProvider.rootLibraryId)
        )

        #expect(next == nil)
    }
}
