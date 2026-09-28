import Foundation
import Testing

@testable import enve

@MainActor
struct OPDSProgressionRetentionTests {
    private static let connectionId = UUID(uuidString: "0F17E6A0-6666-4222-8333-444444444444")!

    // MARK: Holding

    @Test func whatAServiceSentAndEnveCouldNotResolveSurvivesARelaunch() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let references = ["#vendorSpecific=1", "spread.jxl#xywh=160,120,320,240"]

        fixture.store.retainReferences(references, forBookStableId: fixture.book.stableId)
        let reloaded = OPDSProgressionEndpointStore(defaults: fixture.defaults)

        #expect(reloaded.retainedReferences(forBookStableId: fixture.book.stableId) == references)
    }

    @Test func aServiceThatNoLongerReportsAPositionForgetsWhatWasHeld() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }

        fixture.store.retainReferences(["#vendorSpecific=1"], forBookStableId: fixture.book.stableId)
        fixture.store.retainReferences([], forBookStableId: fixture.book.stableId)

        #expect(fixture.store.retainedReferences(forBookStableId: fixture.book.stableId).isEmpty)
    }

    @Test func referencesAreRetiredWithTheServiceThatSentThem() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let stableId = fixture.book.stableId

        fixture.store.retainReferences(["#vendorSpecific=1"], forBookStableId: stableId)
        fixture.store.apply([:], connectionId: Self.connectionId, snapshotIsComplete: true)

        #expect(fixture.store.endpoint(forBookStableId: stableId) == nil)
        #expect(fixture.store.retainedReferences(forBookStableId: stableId).isEmpty)
    }

    @Test func aPartialSnapshotKeepsBothTheServiceAndItsReferences() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let stableId = fixture.book.stableId

        fixture.store.retainReferences(["#vendorSpecific=1"], forBookStableId: stableId)
        fixture.store.apply([:], connectionId: Self.connectionId, snapshotIsComplete: false)

        #expect(fixture.store.endpoint(forBookStableId: stableId) != nil)
        #expect(fixture.store.retainedReferences(forBookStableId: stableId) == ["#vendorSpecific=1"])
    }

    @Test func droppingAConnectionDropsItsReferencesToo() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let stableId = fixture.book.stableId

        fixture.store.retainReferences(["#vendorSpecific=1"], forBookStableId: stableId)
        fixture.store.retainConnections([])

        #expect(fixture.store.retainedReferences(forBookStableId: stableId).isEmpty)
        #expect(OPDSProgressionEndpointStore(defaults: fixture.defaults)
            .retainedReferences(forBookStableId: stableId).isEmpty)
    }

    @Test func clearingTheStoreForgetsTheReferencesToo() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let stableId = fixture.book.stableId

        fixture.store.retainReferences(["#vendorSpecific=1"], forBookStableId: stableId)
        fixture.store.clearAll()

        #expect(OPDSProgressionEndpointStore(defaults: fixture.defaults)
            .retainedReferences(forBookStableId: stableId).isEmpty)
    }

    // MARK: Pushing

    @Test func anEbookPushCarriesTheHeldReferencesAfterItsOwn() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.store.retainReferences(
            ["#vendorSpecific=1", "spread.jxl#xywh=160,120,320,240"],
            forBookStableId: fixture.book.stableId
        )

        let locator = #"""
            {"href":"chapter1.xhtml","locations":{"totalProgression":0.4,"fragments":["par36"]}}
            """#

        let document = fixture.provider.progressionDocument(
            for: fixture.book,
            title: "Chapter 1",
            point: OPDSProgressionMapping.point(forEbookLocator: locator),
            progression: 0.4
        )

        #expect(
            document.references == [
                "chapter1.xhtml#par36",
                "#vendorSpecific=1",
                "spread.jxl#xywh=160,120,320,240",
            ]
        )
    }

    @Test func anAudiobookPushCarriesThemToo() {
        let fixture = Fixture(mediaType: .audiobook)
        defer { fixture.cleanUp() }
        fixture.store.retainReferences(["#vendorSpecific=1"], forBookStableId: fixture.book.stableId)

        let document = fixture.provider.progressionDocument(
            for: fixture.book,
            title: nil,
            point: OPDSProgressionPoint(audioSeconds: 849.25),
            progression: 0.5
        )

        #expect(document.references == ["#t=849.25", "#vendorSpecific=1"])
    }

    @Test func aHeldReferenceIsNotPushedTwiceWhenTheNewPointRegeneratesItsKind() {
        let fixture = Fixture(mediaType: .audiobook)
        defer { fixture.cleanUp() }
        // The document the service last sent named two times; only the one Enve resolved was mapped.
        fixture.store.retainReferences(["#t=12"], forBookStableId: fixture.book.stableId)

        let document = fixture.provider.progressionDocument(
            for: fixture.book,
            title: nil,
            point: OPDSProgressionPoint(audioSeconds: 900),
            progression: 0.5
        )

        #expect(document.references == ["#t=900"])
    }

    @Test func aBookWithNothingHeldPushesOnlyItsOwnReferences() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }

        let document = fixture.provider.progressionDocument(
            for: fixture.book,
            title: nil,
            point: OPDSProgressionPoint(pdfPage: 6),
            progression: 0.5
        )

        #expect(document.references == ["#page=6"])
    }

    // MARK: Fixtures

    private struct Fixture {
        let suiteName: String
        let defaults: UserDefaults
        let store: OPDSProgressionEndpointStore
        let provider: OPDSProvider
        let book: Book

        init(mediaType: AppMediaType = .ebook) {
            suiteName = "opds.progression.retention.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            store = OPDSProgressionEndpointStore(defaults: defaults)
            let connection = ServerConnection(
                id: OPDSProgressionRetentionTests.connectionId,
                name: "Fixture",
                url: "https://catalog.example.invalid/opds/",
                type: .opds
            )
            provider = OPDSProvider(connection: connection, progressionEndpointStore: store)
            book = Book(
                id: "urn:book:1",
                title: "Fixture",
                duration: 1800,
                mediaType: mediaType,
                ebookFormat: mediaType == .ebook ? "epub" : nil,
                libraryId: OPDSProvider.rootLibraryId,
                providerId: OPDSProgressionRetentionTests.connectionId,
                source: .opds
            )
            store.apply(
                [book.stableId: OPDSProgressionEndpoint(
                    url: URL(string: "https://catalog.example.invalid/opds/b1/progression")!
                )],
                connectionId: OPDSProgressionRetentionTests.connectionId,
                snapshotIsComplete: true
            )
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}
