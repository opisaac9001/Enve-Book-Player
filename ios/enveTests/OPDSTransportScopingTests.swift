import Foundation
import Testing

@testable import enve

@MainActor
struct OPDSTransportScopingTests {
    @Test func feedRequestsCarryTheBearerTokenAndCustomHeaders() {
        let provider = OPDSProvider(connection: Self.tokenConnection())

        let request = provider.makeRequest(url: URL(string: "https://catalog.example.invalid/opds/root.json")!)

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer feed-token")
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "client-id")
        #expect(request.value(forHTTPHeaderField: "Accept")?.contains("application/opds+json") == true)
    }

    @Test func coversAndDownloadsOnTheFeedOriginKeepTheirCredentials() {
        let provider = OPDSProvider(connection: Self.tokenConnection())

        for path in ["/covers/1.jpg", "/files/1.epub"] {
            let request = provider.makeRequest(url: URL(string: "https://catalog.example.invalid\(path)")!)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer feed-token")
            #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "client-id")
        }
    }

    @Test(arguments: [
        "https://evil.example.invalid/opds/steal",
        "http://catalog.example.invalid/opds/steal",
        "https://catalog.example.invalid:8443/opds/steal",
        "https://catalog.example.invalid.evil.test/opds/steal",
    ])
    func aCrossOriginAcquisitionNeverReceivesCredentials(target: String) {
        let provider = OPDSProvider(connection: Self.tokenConnection())

        let request = provider.makeRequest(url: URL(string: target)!)

        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == nil)
    }

    /// A feed may nominate a progression service on another host. Enve adopts it, but the request that
    /// reaches it carries nothing the connection authenticates with.
    @Test(arguments: [
        "https://progress.example.invalid/p",
        "http://catalog.example.invalid/opds/p",
        "https://catalog.example.invalid:8443/opds/p",
    ])
    func aProgressionServiceOffTheFeedOriginIsCalledAnonymously(target: String) {
        let provider = OPDSProvider(connection: Self.tokenConnection())

        let request = provider.progressionRequest(
            "PUT",
            endpoint: OPDSProgressionEndpoint(url: URL(string: target)!)
        )

        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == nil)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/opds-progression+json")
    }

    @Test func aProgressionServiceOnTheFeedOriginStillAuthenticates() {
        let provider = OPDSProvider(connection: Self.tokenConnection())

        let request = provider.progressionRequest(
            "GET",
            endpoint: OPDSProgressionEndpoint(
                url: URL(string: "https://catalog.example.invalid/opds/1/progression")!
            )
        )

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer feed-token")
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "client-id")
    }

    // MARK: Redirects on the feed session

    @Test(arguments: [
        "http://catalog.example.invalid/opds/root.json",
        "ftp://catalog.example.invalid/opds/root.json",
        "https://reader:secret@mirror.example.invalid/opds/root.json",
    ])
    func anUnsafeRedirectIsNotFollowedAtAll(target: String) async {
        #expect(await Self.feedRedirect(to: target) == nil)
    }

    @Test func aSafeCrossOriginRedirectIsFollowedWithoutTheCredentials() async {
        let forwarded = await Self.feedRedirect(to: "https://mirror.example.invalid/opds/root.json")

        #expect(forwarded != nil)
        #expect(forwarded?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(forwarded?.value(forHTTPHeaderField: "CF-Access-Client-Id") == nil)
    }

    @Test func theDefaultPortMatchesAnExplicitOne() {
        let origin = URL(string: "https://catalog.example.invalid/opds/")!

        #expect(OPDSURL.sameOrigin(URL(string: "https://catalog.example.invalid:443/x")!, as: origin))
        #expect(OPDSURL.sameOrigin(URL(string: "https://CATALOG.example.invalid/x")!, as: origin))
        #expect(!OPDSURL.sameOrigin(URL(string: "https://catalog.example.invalid:8443/x")!, as: origin))
    }

    @Test func aFeedURLWithoutASchemeStillProducesAUsableOrigin() {
        var connection = Self.tokenConnection()
        connection.url = "catalog.example.invalid/opds/"
        let provider = OPDSProvider(connection: connection)

        let request = provider.makeRequest(url: URL(string: "http://catalog.example.invalid/opds/root.json")!)

        #expect(provider.feedURL().absoluteString == "http://catalog.example.invalid/opds/")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer feed-token")
    }

    /// `AVPlayer`, `AVURLAsset` and the background download session never see a challenge, so Basic is
    /// written out as a header — on the feed origin only, and never alongside a bearer token.
    @Test func aPasswordConnectionSendsBasicRatherThanABearerHeader() {
        var connection = Self.tokenConnection()
        connection.username = "reader"
        connection.password = "secret"
        let provider = OPDSProvider(connection: connection)

        let request = provider.makeRequest(url: URL(string: "https://catalog.example.invalid/opds/root.json")!)
        let expected = "Basic \(Data("reader:secret".utf8).base64EncodedString())"

        #expect(request.value(forHTTPHeaderField: "Authorization") == expected)
        #expect(provider.getStreamingHeaders()["Authorization"] == expected)
        #expect(provider.getStreamingHeaders()["CF-Access-Client-Id"] == "client-id")
        // `AVURLAsset` and the image cache supply their own `Accept`; the feed's would say the wrong thing.
        #expect(provider.getStreamingHeaders()["Accept"] == nil)
    }

    @Test func credentialHeadersStopAtTheFeedOrigin() {
        let provider = OPDSProvider(connection: Self.tokenConnection())

        #expect(provider.credentialHeaders(for: URL(string: "https://catalog.example.invalid/x.mp3")!).isEmpty == false)
        #expect(provider.credentialHeaders(for: URL(string: "https://cdn.example.invalid/x.mp3")!).isEmpty)
    }

    @Test func aPasswordConnectionSendsNothingOffTheFeedOrigin() {
        var connection = Self.tokenConnection()
        connection.username = "reader"
        connection.password = "secret"
        let provider = OPDSProvider(connection: connection)

        let request = provider.makeRequest(url: URL(string: "https://cdn.example.invalid/files/1.epub")!)

        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func aConnectionWithNoCredentialsSendsNoAuthorization() {
        var connection = Self.tokenConnection()
        connection.token = nil
        connection.customHeaders = nil
        let provider = OPDSProvider(connection: connection)

        let request = provider.makeRequest(url: URL(string: "https://catalog.example.invalid/opds/root.json")!)

        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func downloadPayloadsMustMatchTheFormatTheServerClaimed() {
        let html = Data("<!DOCTYPE html><html><body>Sign in</body></html>".utf8)
        let zip = Data([0x50, 0x4B, 0x03, 0x04, 0x00])
        let pdf = Data("%PDF-1.7\n".utf8)
        let rar = Data("Rar!\u{1A}\u{07}".utf8)

        #expect(!OPDSProvider.payload(html, matches: .epub))
        #expect(!OPDSProvider.payload(html, matches: .cbz))
        #expect(!OPDSProvider.payload(html, matches: .pdf))
        #expect(OPDSProvider.payload(zip, matches: .epub))
        #expect(OPDSProvider.payload(zip, matches: .cbz))
        #expect(OPDSProvider.payload(pdf, matches: .pdf))
        #expect(OPDSProvider.payload(rar, matches: .cbr))
        // MOBI-family and FictionBook files have no dependable signature, so the declared type decides.
        #expect(OPDSProvider.payload(html, matches: .mobi))
    }

    // MARK: URLSessionDownloadProgressDelegate scope

    @Test func aCrossOriginRedirectShedsEveryCredentialHeader() async {
        let forwarded = await Self.redirect(
            to: "https://evil.example.invalid/steal",
            through: Self.scopedDelegate()
        )

        #expect(forwarded?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(forwarded?.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(forwarded?.value(forHTTPHeaderField: "CF-Access-Client-Id") == nil)
        // Only the secrets go; the request itself still follows the redirect.
        #expect(forwarded?.value(forHTTPHeaderField: "Accept") == "application/epub+zip")
    }

    @Test(arguments: [
        "http://catalog.example.invalid/files/1.epub",
        "https://catalog.example.invalid:8443/files/1.epub",
        "https://catalog.example.invalid.evil.test/files/1.epub",
    ])
    func aRedirectToANearMissOriginAlsoShedsThem(target: String) async {
        let forwarded = await Self.redirect(to: target, through: Self.scopedDelegate())

        #expect(forwarded?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(forwarded?.value(forHTTPHeaderField: "CF-Access-Client-Id") == nil)
    }

    @Test func aSameOriginRedirectKeepsTheCredentials() async {
        let forwarded = await Self.redirect(
            to: "https://catalog.example.invalid/files/moved/1.epub",
            through: Self.scopedDelegate()
        )

        #expect(forwarded?.value(forHTTPHeaderField: "Authorization") == "Bearer feed-token")
        #expect(forwarded?.value(forHTTPHeaderField: "CF-Access-Client-Id") == "client-id")
    }

    /// A caller that names no origin still has one: the URL the task was aimed at. Falling back to it is
    /// the narrowest scope that can be derived, and it is what keeps a provider that has not been scoped
    /// yet from handing its credentials to whatever host a redirect names.
    @Test func anUnscopedDelegateFallsBackToTheTasksOwnOrigin() async {
        let delegate = URLSessionDownloadProgressDelegate(progressHandler: { _ in })

        let crossOrigin = await Self.redirect(to: "https://elsewhere.example.invalid/file", through: delegate)
        let sameOrigin = await Self.redirect(to: "https://catalog.example.invalid/files/moved.epub", through: delegate)

        #expect(crossOrigin?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(crossOrigin?.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(sameOrigin?.value(forHTTPHeaderField: "Authorization") == "Bearer feed-token")
        #expect(sameOrigin?.value(forHTTPHeaderField: "Cookie") == "session=1")
    }

    @Test(arguments: [
        "http://catalog.example.invalid/files/1.epub",
        "ftp://catalog.example.invalid/files/1.epub",
        "https://reader:secret@catalog.example.invalid/files/1.epub",
    ])
    func aDownloadIsNotFollowedToAnUnsafeDestination(target: String) async {
        #expect(await Self.redirect(to: target, through: Self.scopedDelegate()) == nil)
    }

    @Test func onlyTheAllowedOriginAnswersABasicOrDigestChallenge() {
        let origin = HTTPOrigin(url: URL(string: "https://catalog.example.invalid/opds/")!)

        #expect(origin.matches(Self.protectionSpace(host: "catalog.example.invalid", port: 443)))
        #expect(origin.matches(Self.protectionSpace(host: "CATALOG.example.invalid", port: 443)))
        #expect(!origin.matches(Self.protectionSpace(host: "evil.example.invalid", port: 443)))
        #expect(!origin.matches(Self.protectionSpace(host: "catalog.example.invalid", port: 8443)))
        #expect(!origin.matches(Self.protectionSpace(host: "catalog.example.invalid", port: 443, scheme: "http")))
    }

    @Test func anOriginWithoutAHostMatchesNothing() {
        let origin = HTTPOrigin(url: URL(string: "mailto:librarian@example.invalid")!)

        #expect(!origin.isResolvable)
        #expect(!origin.matches(URL(string: "https://catalog.example.invalid/opds/")!))
        #expect(!origin.matches(Self.protectionSpace(host: "catalog.example.invalid", port: 443)))
    }

    private static func scopedDelegate() -> URLSessionDownloadProgressDelegate {
        URLSessionDownloadProgressDelegate(
            progressHandler: { _ in },
            allowedOrigin: URL(string: "https://catalog.example.invalid/opds/")!,
            sensitiveHeaderNames: ["CF-Access-Client-Id"]
        )
    }

    private static func protectionSpace(
        host: String,
        port: Int,
        scheme: String = "https"
    ) -> URLProtectionSpace {
        URLProtectionSpace(
            host: host,
            port: port,
            protocol: scheme,
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
    }

    private static func redirect(
        to target: String,
        through delegate: URLSessionDownloadProgressDelegate
    ) async -> URLRequest? {
        var request = URLRequest(url: URL(string: target)!)
        request.setValue("Bearer feed-token", forHTTPHeaderField: "Authorization")
        request.setValue("client-id", forHTTPHeaderField: "CF-Access-Client-Id")
        request.setValue("session=1", forHTTPHeaderField: "Cookie")
        request.setValue("application/epub+zip", forHTTPHeaderField: "Accept")

        let source = URL(string: "https://catalog.example.invalid/files/1.epub")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        return await withCheckedContinuation { continuation in
            delegate.urlSession(
                session,
                task: session.downloadTask(with: source),
                willPerformHTTPRedirection: HTTPURLResponse(
                    url: source,
                    statusCode: 302,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": target]
                )!,
                newRequest: request,
                completionHandler: { continuation.resume(returning: $0) }
            )
        }
    }

    private static func feedRedirect(to target: String) async -> URLRequest? {
        let delegate = OPDSSessionDelegate(
            origin: URL(string: "https://catalog.example.invalid/opds/")!,
            username: nil,
            password: nil,
            credentialHeaderNames: ["Authorization", "CF-Access-Client-Id"]
        )
        var request = URLRequest(url: URL(string: target)!)
        request.setValue("Bearer feed-token", forHTTPHeaderField: "Authorization")
        request.setValue("client-id", forHTTPHeaderField: "CF-Access-Client-Id")

        let source = URL(string: "https://catalog.example.invalid/opds/root.json")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        return await withCheckedContinuation { continuation in
            delegate.urlSession(
                session,
                task: session.dataTask(with: source),
                willPerformHTTPRedirection: HTTPURLResponse(
                    url: source,
                    statusCode: 302,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": target]
                )!,
                newRequest: request,
                completionHandler: { continuation.resume(returning: $0) }
            )
        }
    }

    private static func tokenConnection() -> ServerConnection {
        ServerConnection(
            name: "Fixture",
            url: "https://catalog.example.invalid/opds/",
            type: .opds,
            token: "feed-token",
            customHeaders: ["CF-Access-Client-Id": "client-id"]
        )
    }
}
