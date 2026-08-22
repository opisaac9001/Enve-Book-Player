import Foundation
import Testing

@testable import enve

@MainActor
struct HTTPResponseInspectorTests {
    @Test func htmlContentTypeIsEnoughEvenWithoutABody() {
        let response = Self.response(headers: ["Content-Type": "text/html; charset=utf-8"])

        #expect(HTTPResponseInspector.looksLikeHTML(data: Data(), response: response))
    }

    @Test func markupIsSniffedWhenTheContentTypeLies() {
        let response = Self.response(headers: ["Content-Type": "application/json"])
        let body = Data("<!DOCTYPE html><html><body>Sign in</body></html>".utf8)

        #expect(HTTPResponseInspector.looksLikeHTML(data: body, response: response))
    }

    @Test func jsonBodiesAndVeryShortBodiesAreNotTreatedAsHTML() {
        let response = Self.response(headers: ["Content-Type": "application/json"])

        #expect(!HTTPResponseInspector.looksLikeHTML(data: Data(#"{"content":[]}"#.utf8), response: response))
        #expect(!HTTPResponseInspector.looksLikeHTML(data: Data("<a>".utf8), response: response))
    }

    @Test func responsesWithoutCookiesProduceNoHeader() {
        let response = Self.response(headers: ["Content-Type": "application/json"])

        #expect(HTTPResponseInspector.mergedCookieHeader(existing: "CF_Authorization=old", response: response) == nil)
    }

    @Test func newCookiesAreAppendedAndKnownOnesUpdatedInPlace() {
        let response = Self.response(headers: ["Set-Cookie": "CF_Authorization=fresh; Path=/, JSESSIONID=abc; Path=/"])

        let merged = HTTPResponseInspector.mergedCookieHeader(
            existing: "CF_Authorization=stale; KOMGA-SESSION=keep",
            response: response
        )

        #expect(merged == "CF_Authorization=fresh; KOMGA-SESSION=keep; JSESSIONID=abc")
    }

    @Test func mergingWithoutAnExistingHeaderYieldsOnlyTheResponseCookies() {
        let response = Self.response(headers: ["Set-Cookie": "JSESSIONID=abc; Path=/"])

        #expect(HTTPResponseInspector.mergedCookieHeader(existing: nil, response: response) == "JSESSIONID=abc")
    }

    @Test func malformedExistingPairsAreDroppedRatherThanCorruptingTheHeader() {
        let response = Self.response(headers: ["Set-Cookie": "JSESSIONID=abc; Path=/"])

        let merged = HTTPResponseInspector.mergedCookieHeader(existing: "garbage; CF_Authorization=keep", response: response)

        #expect(merged == "CF_Authorization=keep; JSESSIONID=abc")
    }

    private static func response(headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://books.example.invalid/api/v1/books")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }
}
