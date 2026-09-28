import Foundation
import Testing

@testable import enve

struct HTTPRedirectPolicyTests {
    private let origin = HTTPOrigin(url: URL(string: "https://catalog.example.invalid/opds/root.json")!)
    private let secureSource = URL(string: "https://catalog.example.invalid/opds/book.epub")

    private func request(_ url: String, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    // MARK: Which redirects are followed at all

    @Test func aSameSchemeRedirectIsFollowed() {
        #expect(HTTPRedirectPolicy.isFollowable(URL(string: "https://cdn.example.invalid/a.epub")!, from: secureSource))
        #expect(
            HTTPRedirectPolicy.isFollowable(
                URL(string: "http://lan.invalid/a.epub")!,
                from: URL(string: "http://lan.invalid/opds")
            )
        )
    }

    /// Following `https` down to `http` puts the rest of the exchange on the wire in clear, whatever the
    /// headers say.
    @Test func aDowngradeIsNotFollowed() {
        #expect(!HTTPRedirectPolicy.isFollowable(URL(string: "http://cdn.example.invalid/a.epub")!, from: secureSource))
    }

    @Test(arguments: [
        "ftp://cdn.example.invalid/a.epub",
        "file:///etc/passwd",
        "data:text/plain,hello",
        "https://user:secret@cdn.example.invalid/a.epub",
        "https:///a.epub",
    ])
    func anUnsafeDestinationIsNotFollowed(target: String) {
        #expect(!HTTPRedirectPolicy.isFollowable(URL(string: target)!, from: secureSource))
    }

    // MARK: What travels with the redirect

    @Test func credentialsSurviveOnTheOriginTheyBelongTo() {
        let sanitized = HTTPRedirectPolicy.sanitized(
            request("https://catalog.example.invalid/opds/moved.epub", headers: ["Authorization": "Basic abc"]),
            keepingCredentialsFor: origin
        )

        #expect(sanitized.value(forHTTPHeaderField: "Authorization") == "Basic abc")
    }

    @Test func everyCredentialHeaderIsShedCrossOrigin() {
        let sanitized = HTTPRedirectPolicy.sanitized(
            request(
                "https://cdn.example.invalid/a.epub",
                headers: [
                    "Authorization": "Basic abc",
                    "Cookie": "session=1",
                    "Proxy-Authorization": "Basic def",
                    "X-Api-Key": "k",
                    "X-Auth-Token": "t",
                    "CF-Access-Client-Secret": "s",
                    "Accept": "application/epub+zip",
                ]
            ),
            keepingCredentialsFor: origin
        )

        for name in ["Authorization", "Cookie", "Proxy-Authorization", "X-Api-Key", "X-Auth-Token", "CF-Access-Client-Secret"] {
            #expect(sanitized.value(forHTTPHeaderField: name) == nil, "\(name) survived a cross-origin redirect")
        }
        #expect(sanitized.value(forHTTPHeaderField: "Accept") == "application/epub+zip")
    }

    @Test func aCallerSuppliedHeaderNameIsShedToo() {
        let sanitized = HTTPRedirectPolicy.sanitized(
            request("https://cdn.example.invalid/a.epub", headers: ["X-Enve-Custom": "value"]),
            keepingCredentialsFor: origin,
            alsoStripping: ["X-Enve-Custom"]
        )

        #expect(sanitized.value(forHTTPHeaderField: "X-Enve-Custom") == nil)
    }

    /// A caller that cannot name the origin its credentials belong to has no origin they may travel to.
    @Test func anUnknownOriginStripsUnconditionally() {
        let sanitized = HTTPRedirectPolicy.sanitized(
            request("https://catalog.example.invalid/opds/moved.epub", headers: ["Authorization": "Basic abc"]),
            keepingCredentialsFor: nil
        )

        #expect(sanitized.value(forHTTPHeaderField: "Authorization") == nil)
    }

    /// A different port is a different origin, however familiar the host looks.
    @Test func aDifferentPortIsADifferentOrigin() {
        let sanitized = HTTPRedirectPolicy.sanitized(
            request("https://catalog.example.invalid:8443/opds/a.epub", headers: ["Authorization": "Basic abc"]),
            keepingCredentialsFor: origin
        )

        #expect(sanitized.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func schemeHostAndPortDecideTheOrigin() {
        let https = HTTPOrigin(url: URL(string: "https://host.invalid/x")!)

        #expect(https.matches(URL(string: "https://HOST.invalid:443/y")!))
        #expect(!https.matches(URL(string: "http://host.invalid/y")!))
        #expect(!HTTPOrigin(url: URL(string: "/relative")!).isResolvable)
    }
}
