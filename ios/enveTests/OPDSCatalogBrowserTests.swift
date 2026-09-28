import Foundation
import Testing

@testable import enve

@MainActor
struct OPDSCatalogBrowserTests {
    private static let connectionId = UUID(uuidString: "0F17E6A0-1111-4111-8111-111111111111")!
    private static let root = URL(string: "https://catalog.example.invalid/opds/")!
    private static let child = URL(string: "https://catalog.example.invalid/opds/fiction")!

    // MARK: Recovering from a refused root

    @Test func reloadingAfterASignInLoadsARootThatWasRefused() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.provider.refuse(Self.root)

        await fixture.browser.open(fixture.connection)
        #expect(fixture.browser.trail.isEmpty)
        #expect(fixture.browser.page == nil)

        fixture.provider.allow(Self.root, titled: "Catalogue")
        await fixture.browser.reload()

        #expect(fixture.browser.trail.map(\.url) == [Self.root])
        #expect(fixture.browser.page?.url == Self.root)
        #expect(fixture.browser.errorMessage == nil)
    }

    @Test func reloadingTheCurrentPageDoesNotDeepenTheTrail() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }

        await fixture.browser.open(fixture.connection)
        await fixture.browser.descend(to: Self.child, title: "Fiction")
        await fixture.browser.reload()

        #expect(fixture.browser.trail.map(\.url) == [Self.root, Self.child])
    }

    // MARK: Going back

    @Test func goingBackReturnsToTheParentPage() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }

        await fixture.browser.open(fixture.connection)
        await fixture.browser.descend(to: Self.child, title: "Fiction")
        await fixture.browser.goBack()

        #expect(fixture.browser.trail.map(\.url) == [Self.root])
        #expect(fixture.browser.page?.url == Self.root)
    }

    @Test func aRefusedBackStepLeavesTheTrailAndThePageAgreeing() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }

        await fixture.browser.open(fixture.connection)
        await fixture.browser.descend(to: Self.child, title: "Fiction")
        fixture.provider.refuse(Self.root)
        await fixture.browser.goBack()

        #expect(fixture.browser.trail.map(\.url) == [Self.root, Self.child])
        #expect(fixture.browser.page?.url == Self.child)
        #expect(fixture.browser.errorMessage != nil)
    }

    @Test func aRefusedDescentLeavesTheReaderWhereTheyWere() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }

        await fixture.browser.open(fixture.connection)
        fixture.provider.refuse(Self.child)
        await fixture.browser.descend(to: Self.child, title: "Fiction")

        #expect(fixture.browser.trail.map(\.url) == [Self.root])
        #expect(fixture.browser.page?.url == Self.root)
    }

    // MARK: Selection

    @Test func aSelectionDoesNotSurviveAPageChange() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.provider.allow(Self.root, titled: "Catalogue", bookIds: ["urn:a", "urn:b"])
        fixture.provider.allow(Self.child, titled: "Fiction", bookIds: ["urn:c"])

        await fixture.browser.open(fixture.connection)
        fixture.browser.selectEverything()
        #expect(fixture.browser.selectedBooks.count == 2)

        await fixture.browser.descend(to: Self.child, title: "Fiction")

        #expect(fixture.browser.selection.isEmpty)
        #expect(fixture.browser.selectedBooks.isEmpty)
    }

    @Test func aSelectionSurvivesAReloadOfTheSamePage() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.provider.allow(Self.root, titled: "Catalogue", bookIds: ["urn:a", "urn:b"])

        await fixture.browser.open(fixture.connection)
        fixture.browser.toggleSelection(of: "urn:a")
        await fixture.browser.reload()

        #expect(fixture.browser.selection == ["urn:a"])
        #expect(!fixture.browser.isEverythingSelected)
    }

    // MARK: Acquisitions Enve cannot deliver

    @Test func anAudioSampleIsNotOfferedAndSaysWhy() throws {
        let entry = try Self.entry(
            """
            {
              "metadata": { "identifier": "urn:audio-sample", "title": "A Listener's Preview" },
              "links": [
                { "rel": "http://opds-spec.org/acquisition/sample", "href": "/preview.mp3", "type": "audio/mpeg" }
              ]
            }
            """
        )

        #expect(entry.sample == nil)
        #expect(entry.unavailableSampleReason?.isEmpty == false)
    }

    @Test func anEbookSampleIsStillOffered() throws {
        let entry = try Self.entry(
            """
            {
              "metadata": { "identifier": "urn:ebook-sample", "title": "A Reader's Preview" },
              "links": [
                { "rel": "http://opds-spec.org/acquisition/sample", "href": "/preview.epub", "type": "application/epub+zip" }
              ]
            }
            """
        )

        #expect(entry.sample?.url.absoluteString == "https://catalog.example.invalid/preview.epub")
        #expect(entry.unavailableSampleReason == nil)
    }

    @Test func downloadingAnUndeliverableAcquisitionReportsWhyItStopped() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let entry = try Self.entry(
            """
            {
              "metadata": { "identifier": "urn:audio-sample", "title": "A Listener's Preview" },
              "links": [
                { "rel": "http://opds-spec.org/acquisition/sample", "href": "/preview.mp3", "type": "audio/mpeg" }
              ]
            }
            """
        )
        await fixture.browser.open(fixture.connection)

        await fixture.browser.download(entry, using: try #require(entry.acquisitions.first))

        guard case .failed(let message) = fixture.browser.state(of: entry) else {
            Issue.record("An acquisition Enve cannot deliver must leave a reason on the row")
            return
        }
        #expect(!message.isEmpty)
    }

    // MARK: Signing out

    @Test func signingOutForgetsTheTokenAndTheBasicCredentials() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let documentURL = URL(string: "https://catalog.example.invalid/opds/auth.json")!
        fixture.authentication.setSession(
            OPDSAuthenticationStore.Session(
                flowType: "http://opds-spec.org/auth/basic",
                documentURL: documentURL,
                accountLabel: "reader"
            ),
            for: Self.connectionId
        )
        fixture.authentication.setToken(
            OAuthToken(
                accessToken: "lab-access",
                refreshToken: nil,
                expiresIn: 3600,
                tokenType: "Bearer",
                scope: nil,
                issuedAt: Date()
            ),
            for: Self.connectionId
        )

        await fixture.browser.open(fixture.connection)
        #expect(fixture.browser.signedInAccount == "reader")

        await fixture.browser.signOut()

        #expect(fixture.browser.signedInAccount == nil)
        #expect(fixture.authentication.token(for: Self.connectionId) == nil)
        #expect(fixture.connections.connections.first?.username == nil)
        #expect(fixture.connections.connections.first?.password == nil)
        // Keep the sign-in document so the user can sign back in.
        #expect(fixture.authentication.session(for: Self.connectionId)?.documentURL == documentURL)
    }

    // MARK: Fixtures

    private static func entry(_ publicationJSON: String) throws -> OPDSPublicationEntry {
        try #require(
            try OPDSFeedParser.parse(
                document: OPDSFeedDocument(
                    url: URL(string: "https://catalog.example.invalid/opds/root.json")!,
                    contentType: "application/opds+json",
                    data: Data(#"{"metadata":{"title":"T"},"publications":[\#(publicationJSON)]}"#.utf8)
                ),
                context: OPDSCatalogContext(providerId: connectionId, libraryId: OPDSProvider.rootLibraryId)
            ).page.allPublications.first
        )
    }

    private struct Fixture {
        let suiteName: String
        let defaults: UserDefaults
        let connection: ServerConnection
        let provider: StubOPDSProvider
        let connections: StubConnectionEditor
        let authentication: OPDSAuthenticationStore
        let browser: OPDSCatalogBrowser

        init() {
            suiteName = "opds.browser.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            connection = ServerConnection(
                id: OPDSCatalogBrowserTests.connectionId,
                name: "Fixture",
                url: OPDSCatalogBrowserTests.root.absoluteString,
                type: .opds,
                username: "reader",
                password: "secret"
            )
            provider = StubOPDSProvider(connection: connection)
            provider.allow(OPDSCatalogBrowserTests.root, titled: "Catalogue")
            provider.allow(OPDSCatalogBrowserTests.child, titled: "Fiction")
            connections = StubConnectionEditor(connections: [connection])
            authentication = OPDSAuthenticationStore(
                defaults: defaults,
                tokens: InMemoryOPDSTokenStore()
            )
            browser = OPDSCatalogBrowser(
                providers: StubProviderMaker(provider: provider),
                authenticationStore: authentication,
                connections: connections,
                adoptSample: { _ in }
            )
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

/// Use saved pages and errors so these tests don't need a server.
@MainActor
final class StubOPDSProvider: OPDSProvider, @unchecked Sendable {
    private var pages: [URL: OPDSCatalogPage] = [:]

    func allow(_ url: URL, titled title: String, bookIds: [String] = []) {
        var page = OPDSCatalogPage(url: url)
        page.title = title
        page.publications = bookIds.map { identifier in
            OPDSPublicationEntry(
                identity: identifier,
                declaredIdentifier: identifier,
                title: identifier,
                authors: [],
                narrators: [],
                summary: nil,
                seriesInfo: nil,
                languages: [],
                publishedYear: nil,
                duration: nil,
                modified: nil,
                coverURL: nil,
                thumbnailURL: nil,
                detailURL: nil,
                acquisitions: [],
                progression: nil,
                book: Book(
                    id: identifier,
                    title: identifier,
                    partKey: "\(url.absoluteString)/\(identifier).epub",
                    mediaType: .ebook,
                    ebookFormat: "epub",
                    libraryId: OPDSProvider.rootLibraryId,
                    providerId: connection.id,
                    source: .opds
                ),
                unavailableReason: nil
            )
        }
        pages[url] = page
    }

    func refuse(_ url: URL) {
        pages[url] = nil
    }

    override func fetchCatalogPage(at url: URL? = nil) async throws -> OPDSCatalogPage {
        let target = url ?? feedURL()
        guard let page = pages[target] else { throw ProviderError.unauthorized }
        return page
    }

    /// Keep this test offline.
    override func fetchAuthenticationDocument(at url: URL) async -> OPDSAuthenticationDocument? { nil }
}

@MainActor
struct StubProviderMaker: OPDSProviderMaking {
    let provider: OPDSProvider

    func makeLibraryProvider(for connection: ServerConnection) -> LibraryProvider? { provider }
}

@MainActor
final class StubConnectionEditor: ProviderConnectionEditing {
    var connections: [ServerConnection]

    init(connections: [ServerConnection]) {
        self.connections = connections
    }
}
