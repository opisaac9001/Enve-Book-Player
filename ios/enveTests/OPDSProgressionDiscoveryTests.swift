import Foundation
import Testing

@testable import enve

@MainActor
struct OPDSProgressionDiscoveryTests {
    private static let providerId = UUID(uuidString: "0F17E6A0-4444-4222-8333-444444444444")!
    private static let origin = URL(string: "https://catalog.example.invalid/opds/")!
    private let root = URL(string: "https://catalog.example.invalid/opds/root.json")!

    private static var bookStableId: String { "opds:\(providerId.uuidString):urn:book:1" }

    // MARK: OPDS 2.0

    @Test func anOPDS2PublicationAdvertisesItsProgressionServiceAgainstItsBook() throws {
        let parsed = try parse(
            """
            {"metadata":{"title":"Root"},
             "links":[{"rel":"self","href":"root.json","type":"application/opds+json"}],
             "publications":[
               {"metadata":{"identifier":"urn:book:1","title":"Book"},
                "links":[
                  {"rel":"http://opds-spec.org/acquisition/open-access","href":"b1.epub","type":"application/epub+zip"},
                  {"rel":"http://opds-spec.org/progression","href":"b1/progression",
                   "type":"application/opds-progression+json",
                   "properties":{"authenticate":{"href":"/authentication.json",
                                                 "type":"application/opds-authentication+json"}}}
                ]}
             ]}
            """
        )

        let book = try #require(parsed.books.first)
        let endpoint = try #require(parsed.progressionEndpoints[book.stableId])

        #expect(book.stableId == Self.bookStableId)
        #expect(endpoint.url.absoluteString == "https://catalog.example.invalid/opds/b1/progression")
        #expect(endpoint.authenticateURL?.absoluteString == "https://catalog.example.invalid/authentication.json")
    }

    @Test func aPublicationWithNoProgressionLinkStaysLocalOnly() throws {
        let parsed = try parse(
            """
            {"metadata":{"title":"Root"},
             "links":[{"rel":"self","href":"root.json","type":"application/opds+json"}],
             "publications":[
               {"metadata":{"identifier":"urn:book:1","title":"Book"},
                "links":[{"rel":"open-access","href":"b1.epub","type":"application/epub+zip"}]}
             ]}
            """
        )

        #expect(parsed.books.count == 1)
        #expect(parsed.progressionEndpoints.isEmpty)
    }

    /// A catalog is entitled to keep reading positions on another host. The service is adopted; the request
    /// that later reaches it carries no credentials, which `OPDSTransportScopingTests` pins.
    @Test func aProgressionServiceOnAnotherHostIsAdoptedFromAFeed() throws {
        let parsed = try parse(
            """
            {"metadata":{"title":"Root"},
             "links":[{"rel":"self","href":"root.json","type":"application/opds+json"}],
             "publications":[
               {"metadata":{"identifier":"urn:book:1","title":"Book"},
                "links":[
                  {"rel":"open-access","href":"b1.epub","type":"application/epub+zip"},
                  {"rel":"http://opds-spec.org/progression","href":"https://tracker.example.invalid/p",
                   "type":"application/opds-progression+json"}
                ]}
             ]}
            """
        )

        let book = try #require(parsed.books.first)

        #expect(parsed.progressionEndpoints[book.stableId]?.url.absoluteString == "https://tracker.example.invalid/p")
    }

    @Test func aProgressionServiceURLEnveCannotRequestSafelyIsNotAdoptedFromAFeed() throws {
        let parsed = try parse(
            """
            {"metadata":{"title":"Root"},
             "links":[{"rel":"self","href":"root.json","type":"application/opds+json"}],
             "publications":[
               {"metadata":{"identifier":"urn:book:1","title":"Book"},
                "links":[
                  {"rel":"open-access","href":"b1.epub","type":"application/epub+zip"},
                  {"rel":"http://opds-spec.org/progression","href":"https://reader:secret@tracker.example.invalid/p",
                   "type":"application/opds-progression+json"}
                ]}
             ]}
            """
        )

        #expect(parsed.books.count == 1)
        #expect(parsed.progressionEndpoints.isEmpty)
    }

    @Test func aCatalogParsedWithoutAConnectionAdoptsNothing() throws {
        let parsed = try OPDSFeedParser.parse(
            document: OPDSFeedDocument(
                url: root,
                contentType: "application/opds+json",
                data: Data(
                    """
                    {"metadata":{"title":"Root"},
                     "links":[{"rel":"self","href":"root.json","type":"application/opds+json"}],
                     "publications":[
                       {"metadata":{"identifier":"urn:book:1","title":"Book"},
                        "links":[
                          {"rel":"open-access","href":"b1.epub","type":"application/epub+zip"},
                          {"rel":"http://opds-spec.org/progression","href":"b1/progression",
                           "type":"application/opds-progression+json"}
                        ]}
                     ]}
                    """.utf8
                )
            ),
            context: OPDSCatalogContext(providerId: Self.providerId, libraryId: OPDSProvider.rootLibraryId)
        )

        #expect(parsed.books.count == 1)
        #expect(parsed.progressionEndpoints.isEmpty)
    }

    // MARK: OPDS 1.x

    @Test func anAtomEntryAdvertisesItsProgressionServiceToo() throws {
        let parsed = try parse(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
              <title>Root</title>
              <entry>
                <id>urn:book:1</id>
                <title>Book</title>
                <link rel="http://opds-spec.org/acquisition/open-access" href="b1.epub" type="application/epub+zip"/>
                <link rel="http://opds-spec.org/progression" href="b1/progression"
                      type="application/opds-progression+json"/>
              </entry>
            </feed>
            """,
            contentType: "application/atom+xml;profile=opds-catalog"
        )

        let book = try #require(parsed.books.first)

        #expect(book.stableId == Self.bookStableId)
        #expect(
            parsed.progressionEndpoints[book.stableId]?.url.absoluteString
                == "https://catalog.example.invalid/opds/b1/progression"
        )
    }

    @Test func anAtomProgressionLinkWithTheWrongMediaTypeIsRefused() throws {
        let parsed = try parse(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
              <title>Root</title>
              <entry>
                <id>urn:book:1</id>
                <title>Book</title>
                <link rel="http://opds-spec.org/acquisition/open-access" href="b1.epub" type="application/epub+zip"/>
                <link rel="http://opds-spec.org/progression" href="b1/progression" type="application/json"/>
              </entry>
            </feed>
            """,
            contentType: "application/atom+xml;profile=opds-catalog"
        )

        #expect(parsed.books.count == 1)
        #expect(parsed.progressionEndpoints.isEmpty)
    }

    // MARK: Retention

    @Test func aCompleteSnapshotRetiresAServiceItNoLongerSees() {
        let fixture = StoreFixture()
        defer { fixture.cleanUp() }

        fixture.store.apply(
            ["a": Self.endpoint("a"), "b": Self.endpoint("b")],
            connectionId: Self.providerId,
            snapshotIsComplete: true
        )
        fixture.store.apply(["a": Self.endpoint("a")], connectionId: Self.providerId, snapshotIsComplete: true)

        #expect(fixture.store.endpoint(forBookStableId: "a") != nil)
        #expect(fixture.store.endpoint(forBookStableId: "b") == nil)
    }

    @Test func aPartialSnapshotMayOnlyAddBecauseItDidNotSeeTheWholeCatalog() {
        let fixture = StoreFixture()
        defer { fixture.cleanUp() }

        fixture.store.apply(
            ["a": Self.endpoint("a"), "b": Self.endpoint("b")],
            connectionId: Self.providerId,
            snapshotIsComplete: true
        )
        fixture.store.apply(["c": Self.endpoint("c")], connectionId: Self.providerId, snapshotIsComplete: false)

        #expect(fixture.store.endpoint(forBookStableId: "a") != nil)
        #expect(fixture.store.endpoint(forBookStableId: "b") != nil)
        #expect(fixture.store.endpoint(forBookStableId: "c") != nil)
    }

    @Test func aSnapshotOnlySpeaksForItsOwnConnection() {
        let fixture = StoreFixture()
        defer { fixture.cleanUp() }
        let other = UUID()

        fixture.store.apply(["a": Self.endpoint("a")], connectionId: Self.providerId, snapshotIsComplete: true)
        fixture.store.apply(["b": Self.endpoint("b")], connectionId: other, snapshotIsComplete: true)

        #expect(fixture.store.endpoint(forBookStableId: "a") != nil)
        #expect(fixture.store.endpoint(forBookStableId: "b") != nil)

        fixture.store.retainConnections([other])

        #expect(fixture.store.endpoint(forBookStableId: "a") == nil)
        #expect(fixture.store.endpoint(forBookStableId: "b") != nil)
    }

    @Test func adoptedServicesSurviveARelaunch() {
        let fixture = StoreFixture()
        defer { fixture.cleanUp() }

        fixture.store.apply(["a": Self.endpoint("a")], connectionId: Self.providerId, snapshotIsComplete: true)

        let reloaded = OPDSProgressionEndpointStore(defaults: fixture.defaults)

        #expect(reloaded.endpoint(forBookStableId: "a")?.url == Self.endpoint("a").url)
    }

    /// A connection whose catalog advertises no progression service at all is skipped before a sync pass
    /// queries the library for its books.
    @Test func aConnectionWithNoAdvertisedServiceIsRecognizedWithoutAskingForItsBooks() {
        let fixture = StoreFixture()
        defer { fixture.cleanUp() }
        let other = UUID(uuidString: "0F17E6A0-5555-4222-8333-444444444444")!

        #expect(!fixture.store.hasEndpoints(forConnectionId: Self.providerId))

        fixture.store.apply(["a": Self.endpoint("a")], connectionId: Self.providerId, snapshotIsComplete: true)

        #expect(fixture.store.hasEndpoints(forConnectionId: Self.providerId))
        #expect(!fixture.store.hasEndpoints(forConnectionId: other))
    }

    /// An audiobook whose duration the catalog never gave has no fraction to express, so nothing is sent —
    /// and the caller is told, because recording an outbound write for it would make the next pull look
    /// like Enve's own echo.
    @Test func anAudiobookWithNoDurationSendsNoProgressionAndSaysSo() async throws {
        let fixture = StoreFixture()
        defer { fixture.cleanUp() }
        let book = Book(
            id: "urn:book:1",
            title: "An Unmeasured Reading",
            mediaType: .audiobook,
            libraryId: OPDSProvider.rootLibraryId,
            providerId: Self.providerId,
            source: .opds
        )
        fixture.store.apply(
            [book.stableId: Self.endpoint("b1")],
            connectionId: Self.providerId,
            snapshotIsComplete: true
        )
        let provider = OPDSProvider(
            connection: ServerConnection(
                id: Self.providerId,
                name: "Fixture",
                url: Self.origin.absoluteString,
                type: .opds
            ),
            progressionEndpointStore: fixture.store
        )

        let pushed = try await provider.pushPlaybackProgression(
            for: book,
            currentTime: 900,
            isFinished: false
        )

        #expect(!pushed)
    }

    // MARK: Fixtures

    private struct StoreFixture {
        let suiteName: String
        let defaults: UserDefaults
        let store: OPDSProgressionEndpointStore

        init() {
            let suiteName = "opds.progression.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            self.suiteName = suiteName
            self.defaults = defaults
            store = OPDSProgressionEndpointStore(defaults: defaults)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private static func endpoint(_ path: String) -> OPDSProgressionEndpoint {
        OPDSProgressionEndpoint(url: URL(string: "https://catalog.example.invalid/opds/\(path)/progression")!)
    }

    private func parse(_ body: String, contentType: String = "application/opds+json") throws -> OPDSParsedFeed {
        try OPDSFeedParser.parse(
            document: OPDSFeedDocument(url: root, contentType: contentType, data: Data(body.utf8)),
            context: OPDSCatalogContext(
                providerId: Self.providerId,
                libraryId: OPDSProvider.rootLibraryId,
                credentialOrigin: Self.origin
            )
        )
    }
}
