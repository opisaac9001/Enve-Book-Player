import Foundation
import Testing

@testable import enve

@MainActor
struct CloudflareAccessDiagnosticsTests {
    @Test func redirectToAccessLoginIsDetectedForBothRedirectStatuses() {
        let hosted = Self.response(
            statusCode: 302,
            headers: ["Location": "https://team.cloudflareaccess.com/cdn-cgi/access/login"]
        )
        let selfHosted = Self.response(
            statusCode: 303,
            headers: ["Location": "https://books.example.invalid/CDN-CGI/ACCESS/login"]
        )

        #expect(CloudflareAccessHeaders.accessRedirectLocation(in: hosted) != nil)
        #expect(CloudflareAccessHeaders.accessRedirectLocation(in: selfHosted) != nil)
    }

    @Test func ordinaryRedirectsAndSuccessResponsesAreNotAccessDenials() {
        let ordinaryRedirect = Self.response(
            statusCode: 302,
            headers: ["Location": "https://books.example.invalid/api/v1/books"]
        )
        let success = Self.response(statusCode: 200, headers: ["Location": "https://team.cloudflareaccess.com/"])

        #expect(CloudflareAccessHeaders.accessRedirectLocation(in: ordinaryRedirect) == nil)
        #expect(CloudflareAccessHeaders.accessRedirectLocation(in: success) == nil)
    }

    @Test func redirectDetailsComeFromTheMetaTokenPayload() throws {
        let location = Self.accessRedirect(
            meta: #"{"redirect_url":"/api/v1/users/me","auth_status":"SERVICE_TOKEN_INVALID","service_token_status":false}"#
        )

        let details = try #require(CloudflareAccessHeaders.accessRedirectDetails(from: location))

        #expect(details.redirectURL == "/api/v1/users/me")
        #expect(details.authStatus == "SERVICE_TOKEN_INVALID")
        #expect(details.serviceTokenStatus == false)
    }

    @Test func redirectDetailsAreAbsentWithoutADecodableMetaToken() {
        #expect(CloudflareAccessHeaders.accessRedirectDetails(from: "https://team.cloudflareaccess.com/cdn-cgi/access/login") == nil)
        #expect(CloudflareAccessHeaders.accessRedirectDetails(from: Self.accessRedirect(meta: "not-json")) == nil)
    }

    @Test func rejectionMessageReportsEveryDecodedReason() {
        let location = Self.accessRedirect(
            meta: #"{"redirect_url":"/api/v1/users/me","auth_status":"SERVICE_TOKEN_INVALID","service_token_status":false}"#
        )

        let message = CloudflareAccessHeaders.accessRejectionMessage(location: location, endpoint: "/api/v1/users/me")

        #expect(message.contains("rejected the request to /api/v1/users/me"))
        #expect(message.contains("service_token_status=false"))
        #expect(message.contains("auth_status=SERVICE_TOKEN_INVALID"))
        #expect(message.contains("redirect_url=/api/v1/users/me"))
    }

    @Test func rejectionMessageOmitsPlaceholderAuthStatus() {
        let location = Self.accessRedirect(meta: #"{"auth_status":"NONE","service_token_status":true}"#)

        let message = CloudflareAccessHeaders.accessRejectionMessage(location: location, endpoint: "/api/v1/books")

        #expect(!message.contains("auth_status"))
        #expect(!message.contains("service_token_status"))
        #expect(message.contains("Service Auth rule"))
    }

    @Test func rejectionMessageFallsBackWhenNoReasonIsAvailable() {
        let message = CloudflareAccessHeaders.accessRejectionMessage(
            location: "https://team.cloudflareaccess.com/cdn-cgi/access/login",
            endpoint: "/api/v1/books"
        )

        #expect(message.hasPrefix("Cloudflare Access rejected the request. "))
        #expect(!message.contains("/api/v1/books"))
    }

    @Test func accessInterstitialIsRecognisedFromTheBodyPrefixOnly() {
        let interstitial = Data("<html><head><title>Cloudflare Access</title></head></html>".utf8)
        let ordinary = Data("<html><body>Not Found</body></html>".utf8)
        let late = Data(String(repeating: " ", count: 220).appending("cloudflare access").utf8)

        #expect(CloudflareAccessHeaders.htmlBodyIndicatesAccessBlock(interstitial))
        #expect(!CloudflareAccessHeaders.htmlBodyIndicatesAccessBlock(ordinary))
        #expect(!CloudflareAccessHeaders.htmlBodyIndicatesAccessBlock(late))
    }

    private static func accessRedirect(meta: String) -> String {
        let payload = Data(meta.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "https://team.cloudflareaccess.com/cdn-cgi/access/login?meta=header.\(payload).signature"
    }

    private static func response(statusCode: Int, headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://books.example.invalid/api/v1/users/me")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }
}
