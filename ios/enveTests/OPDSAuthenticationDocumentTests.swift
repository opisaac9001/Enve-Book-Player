import Foundation
import Testing

@testable import enve

/// Authentication documents shaped like the ones the lab fixture serves at `/opds/auth/`.
enum OPDSAuthenticationFixtures {
    static let basic = """
        {
          "id": "urn:uuid:5b3f21d0-0001-4c8a-9f10-7d6e5c4b3a21",
          "title": "Enve OPDS Lab",
          "description": "Sign in with the lab test identity.",
          "links": [
            { "rel": "logo", "href": "/opds/images/thumb-blue.png", "type": "image/png" },
            { "rel": "help", "href": "/opds/auth/help.html", "type": "text/html" },
            { "rel": "start", "href": "/opds/v2/root.json", "type": "application/opds+json" }
          ],
          "authentication": [
            {
              "type": "http://opds-spec.org/auth/basic",
              "labels": { "login": "Barcode", "password": "PIN" }
            }
          ]
        }
        """

    static let oauthPassword = """
        {
          "id": "urn:uuid:5b3f21d0-0002-4c8a-9f10-7d6e5c4b3a22",
          "title": "Enve OPDS Lab (OAuth password grant)",
          "links": [
            { "rel": "register", "href": "/opds/auth/register.html", "type": "text/html" }
          ],
          "authentication": [
            {
              "type": "http://opds-spec.org/auth/oauth/password",
              "links": [
                { "rel": "authenticate", "href": "/opds/auth/oauth/token", "type": "application/json" },
                { "rel": "refresh", "href": "/opds/auth/oauth/token", "type": "application/json" }
              ]
            },
            { "type": "http://opds-spec.org/auth/basic" }
          ]
        }
        """

    static let oauthImplicit = """
        {
          "title": "Enve OPDS Lab (OAuth implicit grant)",
          "authentication": [
            {
              "type": "http://opds-spec.org/auth/oauth/implicit",
              "links": [
                { "rel": "authenticate", "href": "/opds/auth/oauth/authorize", "type": "text/html" },
                { "rel": "refresh", "href": "/opds/auth/oauth/token" }
              ]
            }
          ]
        }
        """
}

@MainActor
struct OPDSAuthenticationDocumentTests {
    private let base = URL(string: "https://catalog.example.invalid/opds/root.json")!

    private func decode(_ json: String) throws -> OPDSAuthenticationDocument {
        try #require(OPDSAuthenticationDocument.decode(Data(json.utf8), baseURL: base))
    }

    // MARK: Decoding

    @Test func basicCarriesItsOwnLabels() throws {
        let document = try decode(OPDSAuthenticationFixtures.basic)
        let flow = try #require(document.flows.first)

        #expect(flow.kind == .httpCredentials)
        #expect(flow.loginLabel == "Barcode")
        #expect(flow.passwordLabel == "PIN")
        #expect(flow.isSupported)
        #expect(flow.usesCredentialForm)
        #expect(document.helpURL?.absoluteString == "https://catalog.example.invalid/opds/auth/help.html")
        #expect(document.logoURL?.absoluteString == "https://catalog.example.invalid/opds/images/thumb-blue.png")
    }

    @Test func aPasswordGrantKeepsBothEndpoints() throws {
        let document = try decode(OPDSAuthenticationFixtures.oauthPassword)
        let flow = try #require(document.flows.first)

        #expect(flow.kind == .oauthPassword)
        #expect(flow.authenticateURL?.absoluteString == "https://catalog.example.invalid/opds/auth/oauth/token")
        #expect(flow.refreshURL?.absoluteString == "https://catalog.example.invalid/opds/auth/oauth/token")
        #expect(document.registerURL?.absoluteString == "https://catalog.example.invalid/opds/auth/register.html")
        // Both flows stay: a reader who cannot complete one can pick the other.
        #expect(document.supportedFlows.count == 2)
    }

    @Test func anImplicitGrantIsABrowserFlow() throws {
        let flow = try #require(decode(OPDSAuthenticationFixtures.oauthImplicit).flows.first)

        #expect(flow.kind == .oauthImplicit)
        #expect(!flow.usesCredentialForm)
        #expect(flow.isSupported)
    }

    /// A `401` body is just as often an HTML sign-in page, and reading that as "no way to sign in" would
    /// leave the reader with a dead connection and no explanation.
    @Test(arguments: [
        "<!DOCTYPE html><html><body>Sign in</body></html>",
        #"{"error":"unauthorized"}"#,
        #"{"title":"Library","authentication":[]}"#,
        "",
    ])
    func aPayloadThatIsNotAnAuthenticationDocumentDecodesToNothing(body: String) {
        #expect(OPDSAuthenticationDocument.decode(Data(body.utf8), baseURL: base) == nil)
    }

    @Test func aFlowThatNamesNoEndpointIsNotOffered() throws {
        let document = try decode(
            #"{"title":"T","authentication":[{"type":"http://opds-spec.org/auth/oauth/password"}]}"#
        )

        #expect(document.flows.count == 1)
        #expect(document.supportedFlows.isEmpty)
    }

    @Test func anUnknownFlowIsListedButNotOffered() throws {
        let document = try decode(
            #"{"title":"T","authentication":[{"type":"http://librarysimplified.org/authtype/SAML-2.0"}]}"#
        )

        #expect(document.flows.first?.kind == .unsupported)
        #expect(document.supportedFlows.isEmpty)
    }

    // MARK: Media type

    @Test(arguments: [
        "application/opds-authentication+json",
        "application/opds-authentication+json; charset=utf-8",
        "application/vnd.opds.authentication.v1.0+json",
    ])
    func everyRegisteredAuthenticationMediaTypeIsRecognized(value: String) {
        #expect(OPDSAuthenticationDocument.isAuthenticationMediaType(value))
    }

    @Test(arguments: ["application/json", "text/html", "application/opds+json", ""])
    func anythingElseIsNotAnAuthenticationDocument(value: String) {
        #expect(!OPDSAuthenticationDocument.isAuthenticationMediaType(value))
    }

    // MARK: WWW-Authenticate

    @Test func aChallengeNamingADocumentResolvesIt() {
        let url = OPDSAuthenticationDocument.documentURL(
            inChallenge: #"Bearer realm="Library", href="/opds/auth/basic.json""#,
            baseURL: base
        )

        #expect(url?.absoluteString == "https://catalog.example.invalid/opds/auth/basic.json")
    }

    @Test func aChallengeNamingNoDocumentResolvesNothing() {
        #expect(OPDSAuthenticationDocument.documentURL(inChallenge: #"Basic realm="Library""#, baseURL: base) == nil)
        #expect(OPDSAuthenticationDocument.documentURL(inChallenge: nil, baseURL: base) == nil)
    }

    /// A document URL carrying its own userinfo would hand the credentials to whatever host named it.
    @Test func aChallengeNamingAnUnrequestableDocumentIsRefused() {
        let url = OPDSAuthenticationDocument.documentURL(
            inChallenge: #"Bearer href="https://user:secret@elsewhere.invalid/auth.json""#,
            baseURL: base
        )

        #expect(url == nil)
    }

    /// A realm is free text and routinely contains a comma. Splitting the header on commas alone tears the
    /// realm in half and takes the rest of it for the document's address.
    @Test func aRealmContainingACommaDoesNotCorruptTheDocumentAddress() {
        let url = OPDSAuthenticationDocument.documentURL(
            inChallenge: #"Bearer realm="Lanterns, Ltd. Library", href="/opds/auth.json", error="invalid_token""#,
            baseURL: base
        )

        #expect(url?.absoluteString == "https://catalog.example.invalid/opds/auth.json")
    }

    /// A server may offer several ways in at once. The `href` belongs to whichever challenge carries it.
    @Test func severalChallengesInOneHeaderAreReadSeparately() {
        let url = OPDSAuthenticationDocument.documentURL(
            inChallenge: #"Basic realm="Library", Bearer realm="OAuth", href="/opds/auth.json""#,
            baseURL: base
        )

        #expect(url?.absoluteString == "https://catalog.example.invalid/opds/auth.json")
    }

    @Test func anEscapedQuoteInsideAParameterIsNotATerminator() {
        let parameters = OPDSAuthenticationDocument.challengeParameters(
            in: #"Bearer realm="The \"Quiet\" Room, Annexe", href="/opds/auth.json""#
        )

        #expect(parameters.first(where: { $0.name == "realm" })?.value == #"The "Quiet" Room, Annexe"#)
        #expect(parameters.first(where: { $0.name == "href" })?.value == "/opds/auth.json")
    }

    @Test func anAuthSchemeWithNoParametersContributesNothing() {
        #expect(OPDSAuthenticationDocument.challengeParameters(in: "Negotiate").isEmpty)
        #expect(OPDSAuthenticationDocument.challengeParameters(in: "Basic, Bearer").isEmpty)
    }

    // MARK: Where the document lives

    @Test func aDocumentThatNamesItselfCarriesItsOwnAddress() throws {
        let document = try #require(
            OPDSAuthenticationDocument.decode(
                Data(
                    """
                    {
                      "id": "urn:auth",
                      "title": "Sign in",
                      "links": [{ "rel": "self", "href": "/opds/auth.json",
                                  "type": "application/opds-authentication+json" }],
                      "authentication": [{ "type": "http://opds-spec.org/auth/basic" }]
                    }
                    """.utf8
                ),
                baseURL: base
            )
        )

        #expect(document.documentURL?.absoluteString == "https://catalog.example.invalid/opds/auth.json")
        // Where it was fetched from does not override what it says about itself.
        #expect(
            document.resolvingDocumentURL(URL(string: "https://catalog.example.invalid/elsewhere")!)
                .documentURL?.absoluteString == "https://catalog.example.invalid/opds/auth.json"
        )
    }

    @Test func aDocumentThatNamesNoAddressTakesTheOneItWasFetchedFrom() throws {
        let document = try #require(
            OPDSAuthenticationDocument.decode(
                Data(#"{"title":"Sign in","authentication":[{"type":"http://opds-spec.org/auth/basic"}]}"#.utf8),
                baseURL: base
            )
        )
        let fetched = URL(string: "https://catalog.example.invalid/opds/auth.json")!

        #expect(document.documentURL == nil)
        #expect(document.resolvingDocumentURL(fetched).documentURL == fetched)
    }

    // MARK: Tokens

    @Test func aTokenResponseDecodesWithoutADeclaredType() throws {
        let token = try #require(
            OPDSAuthenticationService.decodeToken(
                Data(#"{"access_token":"abc","refresh_token":"def","expires_in":3600}"#.utf8)
            )
        )

        #expect(token.accessToken == "abc")
        #expect(token.refreshToken == "def")
        #expect(token.tokenType == "Bearer")
        #expect(token.expiresIn == 3600)
    }

    @Test func anEmptyTokenResponseIsNotAToken() {
        #expect(OPDSAuthenticationService.decodeToken(Data(#"{"access_token":""}"#.utf8)) == nil)
        #expect(OPDSAuthenticationService.decodeToken(Data(#"{"error":"invalid_grant"}"#.utf8)) == nil)
    }

    @Test func anOAuthErrorPayloadIsWhatTheReaderIsTold() {
        let message = OPDSAuthenticationService.failureMessage(
            status: 400,
            data: Data(#"{"error":"invalid_grant","error_description":"Wrong PIN."}"#.utf8)
        )

        #expect(message == "Wrong PIN.")
    }

    @Test func aFailureWithNoPayloadIsReportedByStatus() {
        #expect(OPDSAuthenticationService.failureMessage(status: 503, data: Data()).contains("503"))
    }

    // MARK: Implicit flow

    @Test func theAuthorizationURLCarriesEverythingTheSpecificationRequires() throws {
        let url = try #require(
            OPDSAuthenticationService.authorizationURL(
                endpoint: URL(string: "https://catalog.example.invalid/opds/auth/oauth/authorize")!,
                state: "nonce-1"
            )
        )
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }) { first, _ in first }

        #expect(values["response_type"] == "token")
        #expect(values["client_id"] == OPDSAuthenticationService.clientIdentifier)
        #expect(values["state"] == "nonce-1")
        #expect(values["redirect_uri"] == OPDSAuthenticationService.callbackURL.absoluteString)
        #expect(OPDSAuthenticationService.callbackURL.absoluteString.hasSuffix("/"))
    }

    /// The catalog picked the client identifier itself; a client that overwrote it would be signing in as
    /// somebody else.
    @Test func anEndpointThatAlreadyNamesAClientKeepsIt() throws {
        let url = try #require(
            OPDSAuthenticationService.authorizationURL(
                endpoint: URL(string: "https://catalog.example.invalid/authorize?client_id=library-app")!,
                state: "nonce-2"
            )
        )

        #expect(url.absoluteString.contains("client_id=library-app"))
        #expect(!url.absoluteString.contains(OPDSAuthenticationService.clientIdentifier))
    }

    @Test func aFragmentCallbackYieldsTheToken() throws {
        let token = try #require(
            OPDSAuthenticationService.token(
                inCallback: URL(string: "enve-book://opds-auth/#access_token=abc&token_type=Bearer&expires_in=3600&state=n")!,
                expectedState: "n"
            )
        )

        #expect(token.accessToken == "abc")
        #expect(token.expiresIn == 3600)
    }

    @Test func aQueryCallbackYieldsTheTokenToo() throws {
        let token = try #require(
            OPDSAuthenticationService.token(
                inCallback: URL(string: "enve-book://opds-auth/?access_token=abc&token_type=Bearer")!,
                expectedState: nil
            )
        )

        #expect(token.accessToken == "abc")
    }

    /// Accepting a callback whose state does not match the request is accepting a token from somebody who
    /// did not start the flow.
    @Test func aCallbackWithTheWrongStateIsRefused() {
        #expect(
            OPDSAuthenticationService.token(
                inCallback: URL(string: "enve-book://opds-auth/#access_token=abc&state=other")!,
                expectedState: "n"
            ) == nil
        )
    }

    @Test func aCallbackWithoutTheExpectedStateIsRefused() {
        #expect(
            OPDSAuthenticationService.token(
                inCallback: URL(string: "enve-book://opds-auth/#access_token=abc")!,
                expectedState: "n"
            ) == nil
        )
    }

    @Test func aCallbackWithNoTokenIsRefused() {
        #expect(
            OPDSAuthenticationService.token(
                inCallback: URL(string: "enve-book://opds-auth/#error=access_denied")!,
                expectedState: nil
            ) == nil
        )
    }

    @Test func onlyTheAppsOwnCallbackIsRecognized() {
        #expect(OPDSAuthenticationService.isCallback(URL(string: "enve-book://opds-auth/#access_token=a")!))
        #expect(!OPDSAuthenticationService.isCallback(URL(string: "enve-book://reader?bookID=1")!))
        #expect(!OPDSAuthenticationService.isCallback(URL(string: "https://catalog.invalid/opds-auth/")!))
    }
}
