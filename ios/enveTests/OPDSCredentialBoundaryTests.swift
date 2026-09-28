import Foundation
import Testing

@testable import enve

@MainActor
struct OPDSCredentialBoundaryTests {
    private static let feed = URL(string: "https://catalog.example.invalid/opds/")!

    // MARK: Where a credential may be posted

    @Test(arguments: [
        "https://login.example.invalid/token",
        "https://catalog.example.invalid/opds/token",
    ])
    func anHTTPSTokenEndpointIsPostable(target: String) {
        #expect(OPDSCredentialTransport.isPostable(URL(string: target)!, feedURL: Self.feed))
    }

    /// A catalog already reached over plain HTTP is one the reader configured that way, so its own token
    /// endpoint is no weaker than the connection they already have.
    @Test func aPlaintextEndpointOnAPlaintextFeedsOwnOriginIsPostable() {
        let feed = URL(string: "http://catalog.example.invalid/opds/")!

        #expect(
            OPDSCredentialTransport.isPostable(
                URL(string: "http://catalog.example.invalid/opds/token")!,
                feedURL: feed
            )
        )
        #expect(
            !OPDSCredentialTransport.isPostable(
                URL(string: "http://login.example.invalid/token")!,
                feedURL: feed
            )
        )
    }

    @Test(arguments: [
        "http://login.example.invalid/token",
        "ftp://catalog.example.invalid/token",
        "https://reader:secret@catalog.example.invalid/token",
        "https:///token",
    ])
    func aTokenEndpointEnveWillNotTrustIsRefused(target: String) {
        #expect(!OPDSCredentialTransport.isPostable(URL(string: target)!, feedURL: Self.feed))
    }

    /// A LAN catalog over plain HTTP is the case the app's arbitrary-loads exception exists for, and its
    /// identity provider is reachable the same way.
    @Test func aPlaintextEndpointOnTheLocalNetworkIsStillPostable() {
        #expect(
            OPDSCredentialTransport.isPostable(
                URL(string: "http://192.168.1.10:9000/application/o/token/")!,
                feedURL: URL(string: "http://192.168.1.10:13378/opds/")!
            )
        )
    }

    // MARK: The credential session's redirects

    /// The reader's password is the request body, so there is no header to strip: a redirect off the
    /// endpoint's own origin is not followed at all.
    @Test(arguments: [
        "https://elsewhere.example.invalid/token",
        "https://login.example.invalid:8443/token",
        "http://login.example.invalid/token",
        "https://reader:secret@login.example.invalid/token",
    ])
    func aCredentialPostIsNeverReplayedOffItsEndpoint(target: String) async {
        #expect(await Self.credentialRedirect(to: target) == nil)
    }

    @Test func aCredentialPostFollowsItsOwnOrigin() async {
        let forwarded = await Self.credentialRedirect(to: "https://login.example.invalid/oauth/token")

        #expect(forwarded?.url?.absoluteString == "https://login.example.invalid/oauth/token")
        #expect(forwarded?.httpBody != nil)
    }

    // MARK: Which document may describe this connection's sign-in

    @Test func aDocumentOffTheFeedOriginIsNotFetched() async {
        let provider = OPDSProvider(
            connection: ServerConnection(name: "Fixture", url: Self.feed.absoluteString, type: .opds)
        )

        let document = await provider.fetchAuthenticationDocument(
            at: URL(string: "https://evil.example.invalid/auth.json")!
        )

        #expect(document == nil)
    }

    // MARK: Feed-supplied URLs

    @Test(arguments: [
        "https://reader:secret@catalog.example.invalid/opds/page2",
        "mailto:librarian@example.invalid",
        "file:///etc/passwd",
        "javascript:alert(1)",
        "https:///opds/page2",
    ])
    func aFeedSuppliedURLEnveWillNotRequestIsDropped(href: String) {
        #expect(OPDSURL.resolve(href, baseURL: Self.feed) == nil)
    }

    @Test func aRelativeFeedURLStillResolves() {
        #expect(
            OPDSURL.resolve("page2", baseURL: Self.feed)?.absoluteString
                == "https://catalog.example.invalid/opds/page2"
        )
    }

    /// Navigation, catalogs, facets, pagination, acquisitions and search all come out of the same feed, so
    /// none of them may name a URL carrying its own credentials.
    @Test func everyKindOfFeedLinkIsHeldToTheSameRule() throws {
        let body = """
            {
              "metadata": { "title": "Catalogue" },
              "links": [
                { "rel": "next", "href": "https://reader:secret@catalog.example.invalid/opds/page2",
                  "type": "application/opds+json" },
                { "rel": "search", "href": "https://reader:secret@catalog.example.invalid/search{?query}",
                  "type": "application/opds+json", "templated": true }
              ],
              "navigation": [
                { "title": "Fiction", "href": "https://reader:secret@catalog.example.invalid/opds/fiction",
                  "type": "application/opds+json" }
              ],
              "facets": [
                { "metadata": { "title": "Language" },
                  "links": [{ "title": "English",
                              "href": "https://reader:secret@catalog.example.invalid/opds/en",
                              "type": "application/opds+json" }] }
              ],
              "publications": [
                { "metadata": { "identifier": "urn:1", "title": "A Book" },
                  "links": [{ "rel": "http://opds-spec.org/acquisition",
                              "href": "https://reader:secret@catalog.example.invalid/1.epub",
                              "type": "application/epub+zip" }] }
              ]
            }
            """
        let parsed = try OPDSFeedParser.parse(
            document: OPDSFeedDocument(
                url: Self.feed,
                contentType: "application/opds+json",
                data: Data(body.utf8)
            ),
            context: OPDSCatalogContext(providerId: UUID(), libraryId: OPDSProvider.rootLibraryId)
        )

        #expect(parsed.page.pagination.next == nil)
        #expect(parsed.page.navigation.isEmpty)
        #expect(parsed.page.facetGroups.isEmpty)
        #expect(parsed.page.allPublications.first?.acquisitions.isEmpty == true)
        #expect(parsed.page.search == nil)
    }

    // MARK: Fixtures

    private static func credentialRedirect(to target: String) async -> URLRequest? {
        let endpoint = URL(string: "https://login.example.invalid/oauth/token")!
        let delegate = OPDSCredentialSessionDelegate(endpoint: endpoint)

        var request = URLRequest(url: URL(string: target)!)
        request.httpMethod = "POST"
        request.httpBody = Data("grant_type=password&username=reader&password=secret".utf8)

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        return await withCheckedContinuation { continuation in
            delegate.urlSession(
                session,
                task: session.dataTask(with: endpoint),
                willPerformHTTPRedirection: HTTPURLResponse(
                    url: endpoint,
                    statusCode: 307,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": target]
                )!,
                newRequest: request,
                completionHandler: { continuation.resume(returning: $0) }
            )
        }
    }
}
