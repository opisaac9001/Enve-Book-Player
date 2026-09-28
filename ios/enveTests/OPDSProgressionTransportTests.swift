import Foundation
import Testing

@testable import enve

@MainActor
struct OPDSProgressionTransportTests {
    private let base = URL(string: "https://catalog.example.invalid/opds/root.json")!
    private let endpoint = OPDSProgressionEndpoint(
        url: URL(string: "https://catalog.example.invalid/opds/1/progression")!
    )

    private static let documentBody = ##"""
        {"modified":"2026-01-27T11:00:00Z","device":{"id":"urn:uuid:1","name":"R"},
         "progression":0.5,"references":["#t=10"]}
        """##

    // MARK: Auto-discovery

    @Test func aLinkWithBothTheRelationAndTheMediaTypeIsAdopted() throws {
        let discovered = try #require(
            OPDSProgressionTransport.endpoint(
                in: [
                    OPDSLink(href: "cover.jpg", type: "image/jpeg", rels: ["http://opds-spec.org/image"]),
                    OPDSLink(
                        href: "019c0435/progression",
                        type: "application/opds-progression+json",
                        rels: ["http://opds-spec.org/progression"]
                    ),
                ],
                baseURL: base
            )
        )

        #expect(discovered.url.absoluteString == "https://catalog.example.invalid/opds/019c0435/progression")
        #expect(discovered.authenticateURL == nil)
    }

    @Test func aMediaTypeWithParametersStillMatches() {
        #expect(
            adopted(
                href: "p",
                type: "application/opds-progression+json; charset=utf-8",
                rel: "http://opds-spec.org/progression"
            ) != nil
        )
    }

    @Test(arguments: [
        ("application/json", "http://opds-spec.org/progression"),
        ("application/opds-progression+json", "progression"),
        ("application/opds-progression+json", "http://opds-spec.org/shelf"),
        ("application/opds+json", "http://opds-spec.org/progression"),
    ])
    func discoveryNeedsBothTheExactRelationAndTheExactMediaType(sample: (type: String, rel: String)) {
        #expect(adopted(href: "p", type: sample.type, rel: sample.rel) == nil)
    }

    @Test func aLinkWithNoDeclaredMediaTypeIsNotAProgressionService() {
        #expect(adopted(href: "p", type: nil, rel: "http://opds-spec.org/progression") == nil)
    }

    @Test func aTemplatedServiceIsNotAdoptedBecauseEnveCannotExpandIt() {
        #expect(
            adopted(
                href: "p{?device}",
                type: "application/opds-progression+json",
                rel: "http://opds-spec.org/progression",
                templated: true
            ) == nil
        )
    }

    /// A catalog may delegate reading positions to another host. Credentials are scoped at request time, so
    /// such a service is adopted and then talked to anonymously.
    @Test(arguments: [
        "https://progress.example.invalid/p",
        "http://catalog.example.invalid/opds/progression",
        "https://catalog.example.invalid:8443/opds/progression",
    ])
    func aServiceOnAnotherOriginIsStillAdopted(href: String) throws {
        let discovered = try #require(
            adopted(href: href, type: "application/opds-progression+json", rel: "http://opds-spec.org/progression")
        )

        #expect(discovered.url.absoluteString == href)
    }

    @Test(arguments: [
        "ftp://catalog.example.invalid/progression",
        "file:///etc/passwd",
        "javascript:alert(1)",
        "data:application/opds-progression+json,{}",
        "https://reader:secret@catalog.example.invalid/progression",
        "https://:@/progression",
    ])
    func aServiceURLEnveCannotRequestSafelyIsRefused(href: String) {
        #expect(
            adopted(href: href, type: "application/opds-progression+json", rel: "http://opds-spec.org/progression")
                == nil
        )
    }

    @Test func theAuthenticateHintIsKeptAlongsideTheService() throws {
        let link = OPDSLink(
            href: "progression",
            type: "application/opds-progression+json",
            rels: ["http://opds-spec.org/progression"],
            properties: OPDSLinkProperties(
                authenticate: OPDSAuthenticationHint(
                    href: "/authentication.json",
                    type: "application/opds-authentication+json"
                )
            )
        )

        let discovered = try #require(OPDSProgressionTransport.endpoint(in: [link], baseURL: base))

        #expect(discovered.authenticateURL?.absoluteString == "https://catalog.example.invalid/authentication.json")
    }

    @Test func anUnsafeAuthenticateHintIsDroppedWithoutRefusingTheService() throws {
        let link = OPDSLink(
            href: "progression",
            type: "application/opds-progression+json",
            rels: ["http://opds-spec.org/progression"],
            properties: OPDSLinkProperties(
                authenticate: OPDSAuthenticationHint(href: "javascript:alert(1)")
            )
        )

        let discovered = try #require(OPDSProgressionTransport.endpoint(in: [link], baseURL: base))

        #expect(discovered.url.absoluteString == "https://catalog.example.invalid/opds/progression")
        #expect(discovered.authenticateURL == nil)
    }

    // MARK: Requests

    @Test func aProgressionRequestAsksForTheProgressionMediaType() {
        let request = OPDSProgressionTransport.request("PUT", endpoint: endpoint)

        #expect(request.httpMethod == "PUT")
        #expect(request.url == endpoint.url)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/opds-progression+json")
    }

    // MARK: Fetching

    @Test func aFetchedProgressionIsDecoded() throws {
        let expected = try decoded(Self.documentBody)

        let fetched = try OPDSProgressionTransport.readFetch(
            status: 200,
            contentType: declared("application/opds-progression+json"),
            data: Data(Self.documentBody.utf8),
            endpoint: endpoint
        )

        #expect(fetched == .progression(expected))
    }

    @Test(arguments: ["", " ", "\n\t"])
    func anEmptyTwoHundredMeansNoProgressionHasBeenRecorded(body: String) throws {
        let fetched = try OPDSProgressionTransport.readFetch(
            status: 200,
            contentType: declared("text/html; charset=utf-8"),
            data: Data(body.utf8),
            endpoint: endpoint
        )

        #expect(fetched == .notRecorded)
    }

    @Test func aTwoHundredCarryingSomethingElseIsAMalformedPayloadRatherThanNoProgression() {
        #expect(throws: OPDSProgressionError.malformedPayload) {
            try OPDSProgressionTransport.readFetch(
                status: 200,
                contentType: declared("text/html"),
                data: Data("<html><body>Sign in</body></html>".utf8),
                endpoint: endpoint
            )
        }
    }

    @Test func aStatusTheDraftDoesNotDefineAsSuccessIsNotTreatedAsSuccess() {
        #expect(throws: OPDSProgressionError.unexpectedStatus(204)) {
            try OPDSProgressionTransport.readFetch(
                status: 204,
                contentType: declared(nil),
                data: Data(),
                endpoint: endpoint
            )
        }
    }

    @Test func anUnauthorizedResponseNamesTheAuthenticationDocumentWhenTheFeedGaveOne() {
        let authenticateURL = URL(string: "https://catalog.example.invalid/authentication.json")!
        let hinted = OPDSProgressionEndpoint(url: endpoint.url, authenticateURL: authenticateURL)

        #expect(throws: OPDSProgressionError.unauthorized(authenticateURL: authenticateURL)) {
            try OPDSProgressionTransport.readFetch(
                status: 401,
                contentType: declared("application/opds-authentication+json"),
                data: Data(),
                endpoint: hinted
            )
        }
    }

    // MARK: Declared media type

    @Test(arguments: [
        "application/opds-progression+json",
        "application/opds-progression+json; charset=utf-8",
        "APPLICATION/OPDS-PROGRESSION+JSON",
    ])
    func aSuccessDeclaringTheProgressionMediaTypeIsRead(contentType: String) throws {
        let fetched = try OPDSProgressionTransport.readFetch(
            status: 200,
            contentType: declared(contentType),
            data: Data(Self.documentBody.utf8),
            endpoint: endpoint
        )

        #expect(fetched != .notRecorded)
        #expect(
            try OPDSProgressionTransport.readSubmit(
                status: 200,
                contentType: declared(contentType),
                data: Data(Self.documentBody.utf8),
                endpoint: endpoint
            ).progression == 0.5
        )
    }

    /// A payload that happens to parse is still not a progression when the service said it was something
    /// else: a generic JSON error object and a Progression Document are both valid JSON.
    @Test(arguments: ["application/json", "text/html", "application/problem+json", "application/opds+json"])
    func aSuccessDeclaringAConflictingMediaTypeIsRefused(contentType: String) {
        #expect(throws: OPDSProgressionError.malformedPayload) {
            try OPDSProgressionTransport.readFetch(
                status: 200,
                contentType: declared(contentType),
                data: Data(Self.documentBody.utf8),
                endpoint: endpoint
            )
        }
        #expect(throws: OPDSProgressionError.malformedPayload) {
            try OPDSProgressionTransport.readSubmit(
                status: 201,
                contentType: declared(contentType),
                data: Data(Self.documentBody.utf8),
                endpoint: endpoint
            )
        }
    }

    @Test func aSuccessThatDeclaresNothingIsJudgedByItsPayloadAlone() throws {
        #expect(
            try OPDSProgressionTransport.readSubmit(
                status: 200,
                contentType: declared(nil),
                data: Data(Self.documentBody.utf8),
                endpoint: endpoint
            ).progression == 0.5
        )
    }

    // MARK: Updating

    @Test(arguments: [200, 201])
    func bothSuccessCodesCarryTheProgressionTheServiceSettledOn(status: Int) throws {
        let document = try OPDSProgressionTransport.readSubmit(
            status: status,
            contentType: declared("application/opds-progression+json"),
            data: Data(Self.documentBody.utf8),
            endpoint: endpoint
        )

        #expect(document.progression == 0.5)
    }

    @Test(arguments: [200, 201])
    func aSuccessWithNoBodyIsAProtocolViolationOnUpdate(status: Int) {
        #expect(throws: OPDSProgressionError.malformedPayload) {
            try OPDSProgressionTransport.readSubmit(
                status: status,
                contentType: declared("application/opds-progression+json"),
                data: Data(),
                endpoint: endpoint
            )
        }
    }

    @Test func aConflictIsReportedAsAStaleProgressionWithItsProblemDetails() {
        let body = #"""
            {"type":"https://registry.opds.io/error#progression-date",
             "title":"A more recent progression point is already available."}
            """#

        #expect(
            throws: OPDSProgressionError.staleProgression(
                OPDSProblemDetails(
                    type: "https://registry.opds.io/error#progression-date",
                    title: "A more recent progression point is already available.",
                    detail: nil
                )
            )
        ) {
            try OPDSProgressionTransport.readSubmit(
                status: 409,
                contentType: declared("application/problem+json"),
                data: Data(body.utf8),
                endpoint: endpoint
            )
        }
    }

    @Test func aConflictWithoutAProblemDocumentIsStillAConflict() {
        #expect(throws: OPDSProgressionError.staleProgression(nil)) {
            try OPDSProgressionTransport.readSubmit(
                status: 409,
                contentType: declared(nil),
                data: Data(),
                endpoint: endpoint
            )
        }
    }

    @Test(arguments: [
        (400, "https://registry.opds.io/error#progression-invalid-payload"),
        (403, "https://registry.opds.io/error#progression-incorrect-user"),
        (403, "https://registry.opds.io/error#progression-locked"),
    ])
    func aRefusalCarriesTheRegistryIdentifierTheDraftNames(sample: (status: Int, type: String)) {
        let body = #"{"type":"\#(sample.type)","title":"Refused."}"#

        #expect(
            throws: OPDSProgressionError.refused(
                OPDSProblemDetails(type: sample.type, title: "Refused.", detail: nil)
            )
        ) {
            try OPDSProgressionTransport.readSubmit(
                status: sample.status,
                contentType: declared("application/problem+json"),
                data: Data(body.utf8),
                endpoint: endpoint
            )
        }
    }

    @Test func aFailureWithoutAProblemDocumentFallsBackToItsStatus() {
        #expect(throws: OPDSProgressionError.unexpectedStatus(503)) {
            try OPDSProgressionTransport.readSubmit(
                status: 503,
                contentType: declared("text/plain"),
                data: Data("upstream down".utf8),
                endpoint: endpoint
            )
        }
    }

    private func adopted(
        href: String,
        type: String?,
        rel: String,
        templated: Bool = false
    ) -> OPDSProgressionEndpoint? {
        OPDSProgressionTransport.endpoint(
            in: [OPDSLink(href: href, type: type, rels: [rel], templated: templated)],
            baseURL: base
        )
    }

    /// The header is threaded through a real `HTTPURLResponse` so the rule is exercised against what
    /// `URLSession` reports rather than a hand-written string.
    private func declared(_ contentType: String?) -> String? {
        HTTPURLResponse(
            url: endpoint.url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: contentType.map { ["Content-Type": $0] }
        )?.value(forHTTPHeaderField: "Content-Type")
    }

    private func decoded(_ body: String) throws -> OPDSProgressionDocument {
        try JSONDecoder().decode(OPDSProgressionDocument.self, from: Data(body.utf8))
    }
}
